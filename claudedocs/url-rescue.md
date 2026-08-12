# URL Rescue — LLM fallback for failed ingestion

When Luna's primary URL handling fails — an article ends `.failed`, a Price
Tracker page yields no price, or a Downloader link resolves no media — the item
is otherwise a dead end. URL Rescue invokes Apple's **FoundationModels** LLM
(on-device iOS 26 baseline; **Private Cloud Compute** opportunistically on iOS 27
builds) with the URL, a token-budgeted digest of the fetched HTML, and a content
hint, and applies ONE validated directive to recover the save.

## The directive kinds

1. **Final payload** — article blocks (→ `ArticleContent`) or product info (→
   `ProductInfo`). The full-article payload is **PCC-only**: the on-device model's
   ~4096-token window can't reproduce a whole article. Product payloads work
   on-device.
2. **Reroute** — a rewritten https URL (same registrable domain, or the fixed
   `web.archive.org`/`r.jina.ai` mirrors) plus an allowlisted header subset
   (User-Agent token / Referer / Accept-Language / X-Forwarded-For — **never**
   Cookie/Authorization). Re-run once through `IngestPipeline`.
3. **WebJS** — JavaScript run in an off-screen, cookie-less `WKWebView` loading
   the (possibly rewritten) URL, returning HTML / JSON / a media URL fed back to
   extraction. Combines with (2).
4. **`search`** — an INTERMEDIATE kind. The model emits a query (`searchQuery`);
   the engine runs `DuckDuckGoSearch.entries`, filters the live results, and asks
   the model to SELECT one, which is then applied as a reroute (method
   `.search`). The model never supplies a URL at any point — see "Search host
   policy" below.
5. **`inspect_url`** — the other intermediate kind: one more page digested (at
   half budget) before the model commits. Same host policy as a reroute, because
   a free fetch of any host the model names is an exfiltration channel.
6. **`open_in_browser`** — terminal, and the one directive that recovers nothing:
   it converts the failure into the interactive archive-unlock tier
   (`.needsCaptcha`) instead of a dead card. See `claudedocs/failed-saves.md`.
7. **`give_up`**.

## Module layout (`LunaURLRescue`, main-app only)

New SwiftPM target, **never linked into the extensions** (WKWebView runner, long
budgets, FoundationModels). Same tier as `LunaPriceUI`.

- **Session seam** — `RescueModelSession` protocol + plain-DTO responses
  (`RescuePlanResponse` / `RescueArticleResponse`), so nothing above the seam
  names a FoundationModels type. Conformers: `OnDeviceRescueSession`
  (`@available(iOS 26)`), `PrivateCloudRescueSession` (`#if compiler(>=6.4)` +
  `@available(iOS 27)`, PCC-preferring with on-device fallback),
  `UnavailableRescueModelSession` stub, and `RescueModelSessionFactory.makeDefault()`
  as the single availability gate. Mirrors `AudioTrimIntelligence` /
  `FoundationModelsScreenCaptureSession` verbatim.
- **`RescueDigestBuilder`** — SwiftSoup; budgets `.onDevice` 9,000 chars /
  `.privateCloud` 80,000. Ordered sections (head metadata → JSON-LD →
  embedded app JSON → visible text → candidate URLs) with proportional,
  roll-forward budgets. Never throws.
- **`RescueGenerableSchemas`** — one umbrella `@Generable RescuePlanDraft` (`kind`
  via `@Guide(.anyOf(...))` + optional field groups) + a PCC-only
  `RescueArticleDraft`. Untrusted digest goes in the PROMPT; the task contract in
  static instructions (`RescuePrompts`) — the prompt-injection defense.
- **`RescueDirectiveValidator`** — every guardrail: reroute host policy, header
  allowlist + token→UA map, JS ≤8 KiB, article relaxed-threshold + anti-
  hallucination spot-check (≥50% of block prefixes must appear in the digest),
  product price verbatim-in-digest, media URL by extension or verbatim evidence.
  Which PAYLOAD kinds are legal comes from `ContentHint.allows` — `.auto` accepts
  all three, a concrete hint only its own. Widening the legal set does not relax
  any evidence rule.
- **`RescueDirectiveApplier`** — applies a directive; re-enters the pipeline via an
  injected `runPipeline` closure defaulting to the RAW
  `IngestPipeline.processResolved`. **This is the structural "no second LLM pass"
  guarantee** — a rescue-triggered re-run can never recurse into rescue.
- **`RescueWebScriptRunner`** — `WebViewPriceRenderer`-style off-screen runner;
  wraps the model JS in a try/catch IIFE, `.nonPersistent()` data store, 20s.
- **`RescueRuleStore`** — learned per-host rules (`url-rescue-rules.json`, App
  Group): a working reroute/JS is replayed deterministically BEFORE the next LLM
  call. 30-day expiry, 3-failure eviction, 200-entry LRU, `urlRescue.rulesEnabled`
  kill switch. Cached rules are re-validated through the same validator.
- **`RescueFailureEvidence`** — compresses the per-save diagnostic trace into the
  prompt's log excerpt. See "What the model is told" below.
- **`RescueSearch`** — `RescueSearchResult` + `RescueSearchProvider.duckDuckGo`
  (the injected default) + `RescueSearchCandidates`, which owns the search leg's
  host policy.
- **`RescueTraceStoring`** — the engine's seam onto `SaveDiagnosticsStore`
  (read evidence, append the rescue's own decisions). A protocol so both the
  populated and the nil case are testable; `NoRescueTraceStore` is the default
  for callers with no reading-list item.
- **`URLRescueEngine`** — orchestrates: cached rule → browser fast-path →
  availability → digest+evidence → plan call (one digest-halving retry on
  context overflow) → at most ONE intermediate round (search selection or an
  inspect look) → optional PCC article-payload call → validate → apply → learn.
  90s total budget, 30s per call. **Never throws** — every failure folds into a
  `RescueOutcome`. Logs to `SharedDiagnosticLog` category `"rescue"` (hosts only)
  and, when the request carries an item id, to that item's own trace.

## Bounds are structural, never asked for

Every limit lives in code, because a prompt cannot be relied on to keep a
promise:

- **One pipeline re-entry.** The applier's `runPipeline` closure defaults to the
  RAW `IngestPipeline.processResolved`, so a rescue-triggered re-run can never
  recurse into rescue. This is the invariant `KindCompositionRootTests`-adjacent
  suites pin; do not wrap it.
- **One intermediate round.** The follow-up call after a `search` or an
  `inspect_url` is validated with `allowsIntermediate: false`, so those kinds
  simply aren't available on the second round. A model that answers "search" to
  a search round is rejected, not looped.
- **90s / 30s.** `raceAgainstTimeout` is deliberately NOT a task group — a
  cancellation-deaf `respond` once wedged the failed card forever. Extend the
  loop inside it; don't restructure it.

## What the model is told

The plan prompt carries the URL, ONE sentence naming what already failed, a
fenced **log excerpt**, and a fenced **page digest**. All page-derived material
is in the PROMPT and labeled untrusted; the task contract is in the static
instructions only.

- **The failure sentence** is built from the recorded `SaveFailureReason` — the
  actual status code, the subscribe-redirect landing, the transport failure —
  rather than one of three canned sentences that told the model almost nothing.
- **The log excerpt** (`RescueFailureEvidence`) is the per-save trace
  (`SaveDiagnosticsStore.contents(for:)`, Plan A's writer) compressed to the LAST
  attempt's lines: `ISO8601 [category] message` parsed, timestamps dropped
  (order carries the only temporal fact that matters), identical lines collapsed
  with a `(×N)` count, and — when over budget — low-signal lines dropped first,
  then the OLDEST survivors, so what reaches the model is the newest and most
  diagnostic. The instructions add the rule that makes it worth its tokens:
  don't re-propose what the log already shows failing.
- **Budget.** Evidence takes 15% of the character budget, the digest the rest,
  and both derive from the same budget each round — so the digest-halving
  overflow retry halves the evidence too. With no trace (every failure recorded
  before Plan A shipped, and every extension-side failure not yet flushed) the
  section is absent and the prompt is exactly what it always was.
- **No HTML is no longer instant death.** A refetch that returns nothing used to
  end the rescue as `.unrescuable` before the model was ever asked — and a
  bot-walled or paywalled page, the kind most in need of rescue, is exactly the
  page whose refetch fails. The digest section becomes an explicit
  "PAGE DIGEST: unavailable (fetch failed: …)" marker naming which strategies are
  therefore impossible, and reroute / search / inspect / open_in_browser proceed.

## Search host policy

The model never invents a URL: it selects from a list the ENGINE built from live
results, and `RescueDirectiveValidator.validate(…, candidates:)` relaxes the
reroute-host rule for exactly those strings. Which results reach the list is
`RescueSearchCandidates`:

- **Same registrable domain** — always allowed.
- **Cross-domain** — only for an article rescue (nil or `.article` hint) whose
  result title strongly matches the title Luna recovered for the failed page
  (≥60% word overlap on the shorter title, stop words removed). A syndicated
  copy or a canonical home is the same article; a different seller's listing or
  a different creator's post is a different THING, so `product` and `media`
  never cross a domain however good the title looks.

Widening the ACTION space relaxes no EVIDENCE rule: a product price still has to
appear verbatim in the digest, an article payload still has to pass the
prefix spot-check, a media URL still needs an extension or verbatim evidence.

## Errors, and what they cost

`OnDeviceRescueSession.normalize` maps every `GenerationError`, each with its own
log line and its own verdict. Three cases are named directly (the ones the stable
SDK has always had); the rest are matched on the case NAME via
`String(describing:)`, because Luna compiles against two SDKs and naming a case
the archiving SDK lacks would fail the BUILD, not a rescue.

| Model error | Verdict | Spends the version attempt? |
| --- | --- | --- |
| guardrailViolation, refusal | permanent for this URL | no — the ledger blocks it forever instead |
| assetsUnavailable, concurrentRequests | transient | no |
| rateLimited, networkFailure, serviceUnavailable | transient | no |
| quotaLimitReached | `.quotaExhausted` | no |
| decodingFailure, unsupportedGuide/Locale | `.unrescuable` | no (distinct log line) |
| exceededContextWindowSize (after the halving retry) | failed | yes |

## Measurement

`RescueStatsStore` (`rescueStats.json`, LunaStorage) counts attempts, outcomes by
bucket, successes by method, and cached-rule hits. Counts only — nothing
identifies an item, a URL or a host — so the file outlives item deletion, which
the per-item ledger deliberately does not. Surfaced two ways: a line at the top of
the Diagnostics screen, and one `[rescue] sweep launched=… attempts=… …` line per
sweep that launched anything. Before this the feature had no telemetry of any
kind, so "I've yet to see it accomplish anything" was neither confirmable nor
refutable.

## Integration + UX

- **`URLRescueCoordinator`** (`LunaReadingList`, `AudioScriptPipeline`-style):
  inline rescue on an interactive foreground `.failed`; a debounced background
  sweep of `.failed` items (batch 3, serialized, ledger-budgeted); manual one-shot
  rescues (bypass toggle + budget); and the extension→app pending-request drain.
  The engine is injected as a closure by the app shell — the module never links
  `LunaURLRescue`.
- **Trigger** — `ReadingListIngestor.applyResult` is the shared persistence tail
  (surface gate + repoint + presenter) for both a first-pass save and a rescued
  result; a `.failed` outcome fires `ReadingListIngestor.rescueTrigger`.
- **Bookkeeping** — sidecars in `LunaStorage`, never new `ReadingListItem` fields
  (a sibling app's re-encode would drop unknown keys): `RescueLedgerStore`
  (`rescueLedger.json`, 2 auto-attempts / 24h + success provenance;
  `resetAttempts(for:)` reopens the budget once per app update) and
  `PendingRescueRequestStore` (App-Group queue, dedupe-by-URL, take-once, 3-day
  expiry).
- **The hint is usually `.auto`** — `RescueRequest.ContentHint` gained `.auto`,
  and it is what an ABSENT hint now means (it used to be filled in from the
  failure kind, which laundered a guess into an instruction). Under `.auto` the
  plan instructions offer every payload option and open by telling the model that
  classifying the page is ITS job; the prompt drops the hint line and states what
  already failed as a diagnostic fact instead. The failed-save card and every
  automatic path send nil, so **no surface asks the user for a content type any
  more**: the card's segmented picker, the failed row's three-way action sheet,
  its long-press submenu, and the extension card's segmented control are all gone
  (`claudedocs/failed-saves.md`). `RescueHint` is no longer user-facing at all —
  it has no `displayName` — and remains only for the two programmatic callers
  that know the kind from where the user pressed: the price editor and the media
  card.
- **Progress** — `rescue(_:onProgress:)` reports a `RescueStage` (LunaModels) at
  each internal boundary, always opening `.queued` and closing `.finished`.
  `URLRescueCoordinator.reportProgress`/`rescueProgress` turn that into a
  fraction (interpolated within a stage) and post `.rescueProgressChanged`, which
  drives the failed card's `MoonHorizonProgressBar`.
- **Consent** — automatic rescue is always on (there is no setting; the former
  Settings ▸ "Failed Saves" toggle and `RescueSettings` store are gone). Its real
  gates are an available engine, an interactive failure, and the 2-attempts/24h
  ledger budget. Every failed item also offers a one-shot rescue, which bypasses
  the budget — that tap IS its own consent.
- **In-app** — a failed reading-list row tap opens a hint-picker rescue sheet; the
  long-press menu gains a "Try with Apple Intelligence" submenu; the row subtitle
  reads "trying harder…" while a rescue is in flight. On the CARD roots the
  rescue button ("Retry with AI") lives on the failed-save error card, sends no
  hint, and is limited to ONE attempt per app version — see
  `claudedocs/failed-saves.md`.
- **Extension handoff** — the action extension's `.failed` presents
  `RescueFailureViewController`, now the same red-rimmed web-view card as the
  in-app failed save (no hint picker; "Retry with AI"), which
  writes a hint-less `PendingRescueRequest` and best-effort opens the containing app via
  `<scheme>://rescue` (`host.openURL`); the main app drains it on launch /
  foreground / the deep link. Extensions link NO rescue engine.
- **Price / media** — `PriceTrackingViewController.intelligentPriceResolver` powers
  a "Retry with AI" action on the no-price alert;
  `DownloaderJobSnapshot.failureKind == .noMedia` gates a "Retry with AI"
  button on a failed download card, applied via
  `LiveMediaDownloadManager.startWithResolvedAssets`.

## Toolchain / eligibility caveat

`PrivateCloudComputeLanguageModel` is iOS 27 / Xcode 27 SDK only. Luna archives
with **stable Xcode 26.2**, where `PrivateCloudRescueSession` compiles out entirely
(`#if compiler(>=6.4)`) — so **App Store builds are on-device-only** until archiving
moves to Xcode 27, exactly like `FoundationModelsScreenCaptureSession` today. PCC
also requires an Apple application (apps under 2M downloads) and has per-user daily
quotas (surfaced as `RescueOutcome.quotaExhausted`). On any device without Apple
Intelligence the engine returns `.unavailable` and every affordance degrades to a
no-op — the item just stays `.failed` ("pull to retry").
