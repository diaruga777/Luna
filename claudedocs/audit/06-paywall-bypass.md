# Audit 06 — Paywall-Bypass Processing Component

Scope: the component that, once a URL is determined to be a paywalled article, gets
readable HTML past the wall and feeds it to the extractor. Files audited:
`ReaderKit/BypassStrategy.swift`, `BypassRuleTable.swift`, `BypassStrategySelector.swift`,
`BypassRunner.swift`, `BypassGate.swift`, `TrailingDotBypass.swift`,
`ArchiveWebReaderViewController.swift`, `ArticleFetcher.swift`, `ArticleResolver.swift`;
docs `claudedocs/readers.md`, `paywall-bypass-plan.md`, `archive-today-research.md`; and
the bypass test suite.

> **Naming note:** the prompt references `NYTPaywallBypass.swift`. That rename already
> landed — the file is `TrailingDotBypass.swift` (NYT host guard dropped, transform is
> publisher-agnostic; `isNYTHost` kept only as a classification helper). This audit uses
> the current names.

> **Status note:** §3's proposal has since shipped — the actual `BypassStrategy` no longer
> has a `runsSilently` field; it was replaced exactly as §3.1 describes, by the
> `SilentStrategy`/`WebStrategy` split inside `BypassPlan` (see `claudedocs/readers.md`'s
> Bypass-pipeline section and `BypassPlan.swift`/`BypassStrategySelector.swift`). Every
> `runsSilently`/`.thirdPartyWeb`/`BypassRuleTable` reference in §§1–2 below describes the
> PRE-refactor code and is kept as the historical record that motivated the change, not
> the current shape.

---

## 1. Current-state map

The component is **already strategy-shaped** and mostly matches the vision. There are
two execution paths sharing one ordered, per-host strategy list.

### Strategy vocabulary — `BypassStrategy.swift`
`enum BypassStrategy`: `.jsonLDBody`, `.userAgent(CrawlerAgent)`, `.referer(RefererOrigin)`,
`.trailingDotHost`, `.freshSession`, `.amp`, `.waybackRaw`, `.jinaReader`,
`.ladderProxy(LadderProxy)`, `.thirdPartyWeb(ThirdPartyWebService)`, `.archiveToday`.
`runsSilently` is the key discriminator — `false` only for `.thirdPartyWeb` and
`.archiveToday` (WKWebView-only). Associated enums carry the concrete UA/XFF/referer
strings and service URL builders (`LadderProxy.url(for:)`, `ThirdPartyWebService.url(for:)`).
`.replayName` for diagnostics.

### Rule table — `BypassRuleTable.swift`
`BypassRule { domain, strategies: [BypassStrategy] }`; `rule(for:)` does apex +
subdomain + trailing-dot-tolerant host match, first-match-wins. ~21 seeded publisher
rules; **every rule ends in `.archiveToday`**. This is the extensible per-host source of
truth the vision calls for. (Note: the plan's `BypassRule.allowCookies`/`ldJSONSelector`
fields were dropped — fine, they were unused.)

### Selector (pure routing) — `BypassStrategySelector.swift`
`strategies(for:directHTML:) -> [BypassStrategy]`. Order: (1) consult `BypassGate`; if it
blocks → `[]`. (2) per-host rule → its list. (3) else `genericStrategies(directHTML:)`.
Then `normalize(...)`: de-dup (first wins), drop `.jsonLDBody` when the HTML carries no
`articleBody`, and enforce invariants — **silent strategies first, then WKWebView-only,
`.archiveToday` always last**. This is the deterministic routing core and is well unit-tested.

### Silent runner — `BypassRunner.swift`
`protocol BypassRunning { run(_:url:directHTML:) async -> (ArticleContent, String)? }`.
The live `BypassRunner` maps each **silent** strategy to an `HTMLFetching` call + extract;
`.thirdPartyWeb`/`.archiveToday` return `nil` (handled by the web reader). `.jsonLDBody` is
zero-network (re-parses `directHTML`). Each fetch goes through `extracted(baseURL:fetch:)`
which swallows fetch/parse failures → `nil` (graceful fall-through). This is the
"bypass feeds the extractor candidate HTML" contract, cleanly realized.

### The gate — `BypassGate.swift`
`decision(for:html:extracted:) -> Decision (.attempt(Signal) / .block(Block))`. Pure.
Blocks first (platform/product/readable/not-paywalled), then signals (declaredLocked /
gateMarker / hardPaywallHostUnreadable / archiveSnapshot / unprovenFreeUnknownHost).
Single source of truth for "may any bypass run." Well-tested (`BypassGateTests`).

### Where silent strategies run — `ArticleResolver.resolve` (background, URLSession)
direct fetch (reuses `prefetchedHTML`) → if readable return → else
`for strategy in BypassStrategySelector.strategies(...) where strategy.runsSilently { run(...) }`,
first readable+non-locked wins → else `fetcher.fetchArchivedHTML` (legacy last silent
attempt) → `resolution(...)` → `.readable / .paywalled(title) / .unreadable`. Downstream,
`.paywalled` / hard-paywall-host `.unreadable` → `.needsCaptcha`.

### Where WKWebView pre-stages run — `ArchiveWebReaderViewController`
Opened for `.needsCaptcha` items. `webPreStageURLs(for:)` recomputes
`BypassStrategySelector.strategies(for:directHTML:nil)` and **filters to the JS-rendered
strategies** (`.trailingDotHost` → dotted URL, `.thirdPartyWeb` → service URL); silent ones
and archive.today excluded. It walks them as pre-stages (`checkDirectBypassStage`, poll
innerText length / detect JS-required gate, `bypassPollLimit ≈ 9s` each), then
`fallBackToArchiveFromBypass` → the archive.today flow.

### archive.today state machine (terminal)
Homepage warm-up (`archive.is/`) + parallel TimeMap resolve
(`ArticleFetcher.resolveNewestArchiveSnapshot`) → `pollTimer` (1.3s) runs `checkStage` →
JS probe returns `error` / `blocked` / `homepage:<len>` / `challenge` / `page:<len>` →
pure `decideStage(...)` → `.wait / .challenge / .submitHomepage / .loadResolvedSnapshot /
.cannotArchive / .attemptExtract`. Overlay covers everything except a live CAPTCHA. Bounded
by: `loopThreshold=3` (429s), `stallPollLimit≈30s`, `blockedPollLimit≈4s`; terminal
messages (`showTerminalMessage` latches `didShowTerminalMessage`, invalidates the timer);
`viewDidDisappear` invalidates the timer. Extraction off-main via `Task.detached`,
guarded by `isExtracting`/`didExtract`.

---

## 2. Problems

### 2.1 NYT is slow — trailing-dot IS first/silent, but the win is undermined three ways
The headline complaint. The **routing is correct** — `nytimes.com`'s rule leads with
`.trailingDotHost` and it `runsSilently`, so `ArticleResolver.resolve` *does* try a pure
URL-rewrite + one fetch first, silently, in the background. So why slow:

1. **The silent trailing-dot fetch competes/ordered behind a full direct fetch that is
   guaranteed to fail readability.** NYT is a `hardPaywallHost`; the direct
   `fetchHTML(from:)` runs Googlebot-then-Safari (two GETs on failure, line 52–63 of
   `ArticleFetcher`) before the strategy loop even starts. For a known client-meter host
   like NYT the direct pass is dead weight on the hot path.
2. **`.jsonLDBody` sits second in the NYT rule and is *not* free in practice.** The
   selector keeps `.jsonLDBody` only when the direct HTML contains `"articleBody":`
   (`htmlContainsJSONLDArticleBody`). That scan is `html.lowercased().filter { !isWhitespace }`
   — it **lowercases and rebuilds the entire (up-to-8 MB) page string** on the main
   resolve path, per call, just to decide whether to *offer* a strategy. For a large NYT
   page this is a real, avoidable cost between the trailing-dot attempt and the next.
3. **If the silent trailing-dot fetch fails (or the meter has moved), the user-visible
   path re-derives and re-runs trailing-dot *again* as a WKWebView pre-stage** (it is the
   former NYT-only pre-stage, now emitted by the selector). So a failed-silent NYT save
   parks as `.needsCaptcha`, then on open spends `bypassPollLimit ≈ 9s` re-loading the
   dotted host in a web view before reaching archive.today. The deterministic fast path
   ran once silently and lost; the user still pays the slow visible retry.

   Net: for NYT the *fast* path (silent trailing-dot) is correct, but it is (a) gated
   behind a redundant 1–2-GET direct fetch, (b) interleaved with an O(page-size) string
   rebuild, and (c) duplicated as a 9s web-view pre-stage on failure. "Way too slow" is
   the visible-retry tail, not the first attempt.

### 2.2 Duplication between the silent path and the WKWebView pre-stages
`BypassStrategySelector.strategies` is computed **twice** with different inputs:
- once in `ArticleResolver.resolve(directHTML: direct?.1)` for the silent loop,
- once in `ArchiveWebReaderViewController.webPreStageURLs(directHTML: nil)`.

Because the second call passes `directHTML: nil`, `htmlContainsJSONLDArticleBody` is false
and `htmlDeclaresLocked` is false, so the selector can produce a **different ordering**
than the silent path saw (e.g. `.jsonLDBody` re-appears, generic-branch `.freshSession`/
`.trailingDotHost` re-appear). The pre-stage filter then keeps only `.trailingDotHost`/
`.thirdPartyWeb`, so the leak is bounded — but the two paths are not provably consistent,
and the recomputation is invisible coupling. The mapping logic (`switch strategy` → URL)
also lives in **two** places: `BypassRunner.run` (silent URL building) and
`webPreStageURLs` (web URL building), each re-deriving dotted/service URLs.

### 2.3 The selector→runner contract leaks WKWebView strategies into a silent loop
`resolve` writes `for strategy in strategies where strategy.runsSilently`. The selector
already guarantees silent-before-webview ordering, so the `where` clause is belt-and-braces
— but it means the silent path *iterates over* `.thirdPartyWeb`/`.archiveToday` entries and
skips them, and `BypassRunner.run` *also* returns `nil` for them. Two layers both encode
"these aren't silent." A single typed split (a `[SilentStrategy]` vs `[WebStrategy]` pair
from the selector) would make the invalid combination unrepresentable instead of filtered
twice.

### 2.4 Things that can hang / unbounded-ish
Mostly bounded, with gaps:
- **Silent chain has no aggregate budget.** Each silent fetch is individually capped
  (`timeout: 12` for UA/referer/fresh/ladder/jina, `15–30` for wayback). But the NYT rule
  has up to ~5 silent strategies before the WKWebView ones; worst case is ~5 × (12–30s)
  ≈ a minute of serial silent fetches on the ingest path before parking as `.needsCaptcha`.
  There is no overall deadline and no early-exit on "this host is a known hard wall, skip
  straight to parking." (`fetchArchivedHTML` at the end adds Wayback 15s + archive.today
  12s on top.)
- **`legacy fetchArchivedHTML` runs even after the strategy list already tried Wayback.**
  `.waybackRaw` is in essentially every rule, yet `resolve` still calls
  `fetchArchivedHTML` (which itself tries `fetchWaybackHTML` then `archive.ph/newest`)
  as a final silent attempt. That's a **third** Wayback hit per resolve and a redundant
  archive.ph GET that "usually CAPTCHA-blocks" — pure latency for hard walls.
- **`coveredPollCount` stall guard depends on the overlay actually being up.** It resets
  whenever `loadingOverlay.isHidden` (i.e. while a CAPTCHA shows). A page that oscillates
  challenge↔homepage could in principle keep resetting the stall counter; the 429
  `loopThreshold` is the only backstop there. Real but narrow.

### 2.5 The gate's coupling
`BypassGate` is meant to be the pure, reusable "may a bypass run" decision, but it reaches
into concrete component statics: `ArticleFetcher.isHardPaywallHost`, `isArchiveTodayURL`,
`PaywallDetector.*`, `PlatformClassifier`, `ProductPageDetector`. That's acceptable for a
policy object, but two consequences:
- **The hard-paywall host list is duplicated in spirit across three places**:
  `ArticleFetcher.hardPaywallHosts` (Set of ~21), `BypassRuleTable.rules` (~21 domains),
  and the gate consults the first while routing uses the second. They are maintained
  independently and can drift (a host could be in `hardPaywallHosts` but have no rule, or
  vice-versa). They happen to line up today; nothing enforces it.
- The gate is consulted **inside** `BypassStrategySelector.strategies` (selector returns
  `[]` when blocked) **and** is documented as something the archive reader / extensions
  consult — but `ArchiveWebReaderViewController` does **not** call the gate directly; it
  trusts that an item only reaches `.needsCaptcha` through the gated resolver. That's true
  today but is an implicit invariant, not an enforced one.

### 2.6 Minor
- `ArticleResolver` imports `SwiftSoup` only for `ampURL(in:base:)`; that one helper could
  move next to the extractor so the resolver stays I/O+policy only.
- `BypassRunner.extracted` and `ArticleResolver.extractedContent` are the same
  fetch-then-extract-then-pair helper, duplicated.

---

## 3. Proposed simplified design

The bones are right. The fix is **consolidation + typed separation + a single bounded
pipeline**, not a rewrite. Goal: one ordered, per-host, extensible pipeline that yields
candidate HTML to the extractor; trailing-dot is a fast first *silent* strategy; one place
maps a strategy to a URL; archive.today is the bounded last resort.

### 3.1 Make the silent/web split a type, computed once
Have the selector return a single ordered, **typed** plan instead of a flat array both
callers re-derive and re-filter:

```swift
struct BypassPlan: Equatable {
    /// Ordered URLSession strategies for the background path. Never empty-checks
    /// for web strategies — these are provably silent.
    let silent: [SilentStrategy]
    /// Ordered WKWebView pre-stage strategies, archive.today excluded.
    let webPreStages: [WebStrategy]
    /// Whether the archive.today terminal flow is permitted at the end.
    let allowsArchiveToday: Bool
}
```

`SilentStrategy` / `WebStrategy` are the existing cases split by `runsSilently`, so the
"skip non-silent in the silent loop" filter and the `run` returning `nil` for web cases
**both disappear** — the invalid combinations are unrepresentable (addresses 2.3). The
resolver consumes `plan.silent`; the web reader consumes `plan.webPreStages` +
`plan.allowsArchiveToday`. Both call **one** factory, so they can't diverge (addresses 2.2).

### 3.2 One strategy→URL mapper
A single `BypassURLs` namespace builds the request for any strategy (dotted host, ladder
URL, service URL, jina URL, wayback inputs). `BypassRunner.run` and the web reader both call
it; the `switch` lives once (addresses 2.2's second half, 2.6's helper dup).

### 3.3 Bound the whole silent chain, and skip dead weight for known hard walls
- Add an **aggregate silent deadline** (e.g. 20s) to `resolve`'s silent loop so the ingest
  path fails fast to `.needsCaptcha` (non-blocking) instead of serially burning ~1 min.
- For a **server-side hard wall with `htmlDeclaresLocked`** (or a `hardPaywallHost` whose
  direct read is a stub), the selector should drop the silent client tricks it already
  knows can't win and let the resolver **park immediately** rather than walk silent
  proxies that mostly 4xx. The generic branch already does half of this
  (`if !declaresHardLock { client tricks }`); extend it to the rule branch and to the
  decision "is any silent strategy worth trying at all."
- **Drop the redundant trailing `fetchArchivedHTML`** from `resolve` (2.4): `.waybackRaw`
  is in every rule, and `archive.ph/newest` belongs to the WKWebView terminal flow, not a
  silent attempt. This removes a second/third Wayback hit and a near-always-failing GET
  from the hot path — directly speeds the "no silent strategy worked" tail for NYT/WSJ/FT.

### 3.4 Trailing-dot stays the fast first silent strategy — make it cheaper to reach
- Keep `.trailingDotHost` first for client-meter hosts (it already is).
- Replace the O(page-size) `htmlContainsJSONLDArticleBody` whole-string rebuild
  (2.1 #2) with a bounded scan (regex / `range(of:)` over the raw HTML, no full lowercase
  rebuild) so deciding whether to *offer* `.jsonLDBody` doesn't cost a multi-MB allocation
  between the trailing-dot attempt and the next.
- **Don't re-run trailing-dot as a 9s web-view pre-stage when the silent attempt already
  ran and failed** (2.1 #3). A client-meter rewrite that returns a wall over URLSession
  will return the same wall in WKWebView; the only reason to repeat it is client-side
  paywall JS that the silent fetch's served HTML didn't carry. Make that explicit: a
  strategy declares whether it "benefits from JS rendering on retry." `.trailingDotHost`
  → no (it's a pure origin trick); `.thirdPartyWeb` → yes (SPA). Then the web reader's
  `webPreStages` only repeats the JS-beneficial ones, and NYT goes silent-trailing-dot →
  (fail) → straight to archive.today, skipping the 9s redundant pre-stage.

### 3.5 Pin down the gate / host-list coupling
- Make `BypassRuleTable` the **single** host source: derive `isHardPaywallHost` from "has a
  rule whose terminal strategy is `.archiveToday`" (or an explicit `isHardWall` flag on
  `BypassRule`) instead of a parallel `hardPaywallHosts` Set (addresses 2.5). One list to
  maintain; a test asserts every `hardPaywallHosts` member has a rule (until the Set is
  removed).
- Keep the gate pure but have the **archive reader call it too** (or assert the
  `.needsCaptcha` precondition) so "only genuinely paywalled pages reach the web reader" is
  enforced, not assumed.

### 3.6 Sample rule entry (extensible per-host)
With an explicit hard-wall flag and JS-retry semantics folded in:

```swift
BypassRule(
    domain: "nytimes.com",
    isHardWall: false,                       // client-side meter → silent tricks can win
    strategies: [
        .trailingDotHost,                    // FAST: pure URL rewrite + 1 silent GET, tried first
        .jsonLDBody,                         // zero-network re-parse of the HTML we already have
        .waybackRaw,                         // silent CDX newest-200 → id_ raw replay
        .ladderProxy(.oneFt),                // silent server-render proxy
        .jinaReader,                         // silent reader proxy
        .thirdPartyWeb(.smry),               // WKWebView pre-stage (SPA — benefits from JS)
        .thirdPartyWeb(.removePaywalls),
        .archiveToday,                       // bounded last resort, terminal
    ])
```

---

## 4. Testability

Already strong and mostly pure; the suite to preserve/extend:

### Pure strategy selection / ordering per host
- `BypassStrategySelectorTests` — not-paywalled→`[]`; per-host rule verbatim order; generic
  metered vs non-locked branch; JSON-LD presence toggles `.jsonLDBody`; de-dup;
  silent-before-webview + archiveToday-last; subdomain match. **Add:** the proposed
  `BypassPlan` split — assert `plan.silent` contains no web cases and vice-versa (the
  type makes it free), and that the resolver-input and web-reader-input produce a
  *consistent* plan (the 2.2 divergence regression).
- `BypassRuleTableTests` — apex/subdomain/trailing-dot match, unknown→nil, lookalike
  rejected, **every rule ends with `.archiveToday`**. **Add:** every `hardPaywallHosts`
  member has a rule (until the Set is folded into the table, per 3.5).

### URL rewrites (trailing-dot / AMP)
- `TrailingDotBypassTests` — adds dot preserving path/query; apex; subdomain; non-NYT host
  transformed; already-dotted → nil; `isNYTHost` classification.
- AMP discovery (`ArticleResolver.ampURL`) is testable from an HTML fixture; ensure a
  fixture test exists for `rel=amphtml` present/absent/self-referential.

### Runner advance-on-failure with a mock fetcher
- `BypassRunnerTests` + `MockArticleFetcher` — each silent strategy calls the right fetch
  with the right UA/XFF/referer/URL; bingbot omits XFF; trailing-dot fetches the dotted
  host but keeps the **canonical base URL**; fresh-session uses no cookies; `.jsonLDBody`
  is zero-network; `.thirdPartyWeb`/`.archiveToday` return nil; fetch failure → nil
  (advance). **Add:** an `ArticleResolverTests` case asserting the silent loop **advances
  past failing/locked results and stops at the first readable** (doc says these exist:
  advance-past-failing, reject-unreadable-and-advance, fall-all-the-way-to-paywalled) —
  and a new case for the **aggregate silent deadline** (3.3): a mock fetcher that delays
  past the budget parks as `.paywalled`/`.needsCaptcha` rather than blocking.

### Web pre-stage ordering (nytimes/wapo/wsj/smh)
- `ArchiveWebPreStageTests` — NYT leads with trailing-dot then third-party pages; WSJ has
  no trailing-dot but has third-party pages; archive.today URL → no pre-stages; **no silent
  strategy leaks into pre-stages**. **Add:** under 3.4, assert NYT's pre-stages **omit
  trailing-dot** (since it already ran silently and doesn't benefit from JS retry) — this
  is the regression test for the "way too slow" tail. Add an `smh.com.au` rule + case if
  SMH is in scope (currently no rule → generic branch).

### archive.today decision core
- `decideStage(...)` and `newestMemento(fromTimeMap:)` / `newestSnapshotTimestamp(fromCDXJSON:)`
  are pure and tested (`ArchiveStageDecisionTests`/`WaybackCDXTests` per the docs). Keep
  green through any refactor — the archive.today core is the riskiest code and should not
  change.

---

## Recommended bypass-pipeline API + rule entry

```swift
// ── One typed, ordered plan, built ONCE; consumed by both paths. ──────────────
enum SilentStrategy: Equatable { case jsonLDBody, userAgent(CrawlerAgent),
    referer(RefererOrigin), trailingDotHost, freshSession, amp, waybackRaw,
    jinaReader, ladderProxy(LadderProxy) }

enum WebStrategy: Equatable { case trailingDotHost, thirdPartyWeb(ThirdPartyWebService)
    /// Whether repeating this in a WKWebView can succeed where the silent fetch failed
    /// (true only for SPA/JS-rendered services; a pure origin trick like trailing-dot
    /// returns the same wall, so it is NOT repeated as a pre-stage).
    var benefitsFromJSRetry: Bool { if case .thirdPartyWeb = self { return true }; return false } }

struct BypassPlan: Equatable {
    let silent: [SilentStrategy]          // background URLSession path, ordered, bounded
    let webPreStages: [WebStrategy]       // WKWebView pre-stages (benefitsFromJSRetry only)
    let allowsArchiveToday: Bool          // bounded terminal flow
}

enum BypassPipeline {
    /// PURE. Single factory both `ArticleResolver` (silent) and the archive reader
    /// (web) consume — they can no longer derive divergent orderings. `[]`/false when
    /// `BypassGate` blocks. Per-host rule first, else generic signal-based fallback;
    /// normalized (de-dup, drop `.jsonLDBody` w/o articleBody, hard-wall drops dead
    /// client tricks).
    static func plan(for url: URL, directHTML: String?) -> BypassPlan { fatalError() }
}

// ── One strategy→URL mapper (was split across BypassRunner + webPreStageURLs). ──
enum BypassURLs {
    static func requestURL(for s: SilentStrategy, article: URL) -> URL? { fatalError() }
    static func loadURL(for s: WebStrategy, article: URL) -> URL? { fatalError() }
}

// ── Resolver loop: bounded, no redundant trailing fetchArchivedHTML. ───────────
let plan = BypassPipeline.plan(for: url, directHTML: direct?.1)
for strategy in plan.silent {                     // already silent-only — no `where` filter
    if let pair = await runner.run(strategy, url: url, directHTML: direct?.1),
       Self.isReadable(pair) { return .readable(pair.0, html: pair.1) }
    if Date() > silentDeadline { break }          // aggregate budget → park fast
}
return resolution(direct: direct, archived: nil)  // parks .needsCaptcha for the web path

// ── Extensible per-host rule (single host source of truth). ────────────────────
BypassRule(
    domain: "nytimes.com",
    isHardWall: false,                             // client meter → silent tricks can win
    strategies: [
        .trailingDotHost,                          // FAST first silent: URL rewrite + 1 GET
        .jsonLDBody, .waybackRaw, .ladderProxy(.oneFt), .jinaReader,
        .thirdPartyWeb(.smry), .thirdPartyWeb(.removePaywalls),
        .archiveToday,                             // bounded last resort
    ])
```

**Headline fix for "NYT too slow":** routing already tries silent trailing-dot first, so
the first attempt is fast. The latency is (a) the redundant pre-direct-fetch + O(page-size)
JSON-LD scan around it, and (b) re-running trailing-dot as a ~9s WKWebView pre-stage after
the silent attempt failed. Stop repeating non-JS strategies in the web path
(`benefitsFromJSRetry`), bound the silent chain, and drop the trailing `fetchArchivedHTML`
— NYT then goes silent-trailing-dot → (fail) → archive.today with no 9s detour.
