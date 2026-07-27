# URL Rescue — LLM fallback for failed ingestion

When Luna's primary URL handling fails — an article ends `.failed`, a Price
Tracker page yields no price, or a Downloader link resolves no media — the item
is otherwise a dead end. URL Rescue invokes Apple's **FoundationModels** LLM
(on-device iOS 26 baseline; **Private Cloud Compute** opportunistically on iOS 27
builds) with the URL, a token-budgeted digest of the fetched HTML, and a content
hint, and applies ONE validated directive to recover the save.

## The three directive kinds

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
- **`URLRescueEngine`** — orchestrates: cached rule → availability → digest →
  plan call (one digest-halving retry on context overflow) → optional PCC
  article-payload call (≤2 round-trips) → validate → apply → learn. 90s total
  budget, 30s per call. **Never throws** — every failure folds into a
  `RescueOutcome`. Logs to `SharedDiagnosticLog` category `"rescue"` (hosts only).

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
  more** — the central Luna app's segmented picker is gone
  (`claudedocs/failed-saves.md`). A concrete hint remains for the surfaces that
  genuinely know: the list row's rescue sheet, the extension hand-off, the price
  editor, the media card.
- **Progress** — `rescue(_:onProgress:)` reports a `RescueStage` (LunaModels) at
  each internal boundary, always opening `.queued` and closing `.finished`.
  `URLRescueCoordinator.reportProgress`/`rescueProgress` turn that into a
  fraction (interpolated within a stage) and post `.rescueProgressChanged`, which
  drives the failed card's `EclipseProgressBar`.
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
  `RescueFailureViewController` (hint segmented control + "Finish in Luna"), which
  writes a `PendingRescueRequest` and best-effort opens the containing app via
  `<scheme>://rescue` (`host.openURL`); the main app drains it on launch /
  foreground / the deep link. Extensions link NO rescue engine.
- **Price / media** — `PriceTrackingViewController.intelligentPriceResolver` powers
  an "Ask Apple Intelligence" action on the no-price alert;
  `DownloaderJobSnapshot.failureKind == .noMedia` gates a "Try Apple Intelligence"
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
