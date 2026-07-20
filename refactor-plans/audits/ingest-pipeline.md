# Ingest-pipeline audit (LunaIngest, LunaURLClassification, LunaHTMLClassification, LunaFetch, LunaPaywallBypass, LunaPlatforms, LunaReadingList, LunaStorage, LunaModels, LunaAppConfig)

Read-only audit for a strictly behavior-preserving refactor. No code was changed. Scope
and rules per the audit brief; findings that duplicate items already fixed or
deliberately deferred by `CODE_REVIEW_PLAN.md` (2026-07-02) or `PERF_REVIEW_PLAN.md`
(2026-07-05) are excluded (both were read in full before this pass and are treated as
prior-art, not re-litigated).

**Method:** six parallel review passes, one per module cluster, each reading every file
in full (LunaPlatforms' 15 files were also read in full — they're individually small and
were not sampled). Every dead-code and duplication claim below was verified with a
repo-wide grep (across `LunaLibraries/Sources`, `LunaLibraries/Tests`, `Luna/`,
`LunaDownloader/`, `LunaPriceTracker/`, `LunaTests/`, and all extension targets) —
grep commands are quoted inline.

**Repo-hygiene aside (not a pipeline finding, flagging for awareness only):**
`.claude/worktrees/agent-a44f9578d823e01c8/` contains a stale, apparently abandoned git
worktree with divergent copies of several files in this scope (`ReadingListIngestor.swift`
at 784 lines vs. 759 on main, `AppDelegate.swift`, a divergent `LunaHTMLClassification`
tree with extra files not on `main`). It was excluded from every finding below; someone
should decide whether to clean it up.

---

## 1. Structure map

### Layering, as declared in `LunaLibraries/Package.swift`
```
LunaAppConfig ─┐
LunaModels ────┼─→ LunaURLClassification ─→ LunaHTMLClassification ─→ LunaFetch ─→ LunaPaywallBypass ─┐
               │                                                                                       ├─→ LunaIngest ─→ LunaReadingList
LunaStorage ───┴───────────────────────────────────────────────────────────────────────────────────────┘
LunaPlatforms (Models, URLClassification, HTMLClassification, Fetch, Storage, DesignSystem, AppConfig, PriceMetadata)
```
(`LunaPlatforms` and `LunaReadingList` also pull in several modules outside this audit's
scope — DesignSystem, Interop*, Send, Mail*, MediaDownload, PriceUI, ReaderUI,
ArchiveReader, Social — those edges are noted but not audited here.)

### Per-module responsibilities

| Module | Files | Responsibility | Public surface | Layering notes |
|---|---|---|---|---|
| **LunaAppConfig** | 1 (`AppConfig.swift`, 52L) | App-Group id resolution from Info.plist, compiled-in fallback. | `AppConfig` enum. | Clean, zero deps, no violations. |
| **LunaModels** | 14 (~1560L) | Pure value types: `ReadingListItem`, `PriceTracker`/`PriceHistory`/`PriceParsing`/`PriceFormatting`, `ArticleContent`, `MIMEHeaderEncoding`, `ZipArchiveWriter`, `ReaderResumePositionResolver`, `PriceTrackingExitContext`, `ContentModels`, `CaptureSource`, `AppEnvironment`, `ArticleBlockRendering`. | All-value-type surface, no mutable singletons. | No layering violations; nothing here imports upward. |
| **LunaURLClassification** | 15 (~1630L) | `URLCanonicalizer` (tracking-param stripping, single source of truth), `KnownSite` (declarative host+path→`ContentKind`), `PlatformRecognizer` (declarative platform-URL rules — "the ONE place URL→platform rules live" per its own doc comment), `ShoppingSites`/`NewsSites` (host-list data), `NewsAggregatorUnwrapper` (pure Apple News/Google News/Facebook-redirect/shortener parsers) + `URLUnwrapper` (the `[WrapperHandler]` dispatch registry wrapping them), `RegexCapture` (already-consolidated regex-capture helper), `LunaDeepLink`, `LunaAppClipInvocationURL`, `ProductSearchURL`, `ShareTextURL`, `NonTextualContent`, `WebFetchConstants`. | Declarative rule tables + pure parsers. | No violations; imports only `LunaModels`. |
| **LunaHTMLClassification** | 12 (~2990L) | `Classifier` (the `ContentKind` decision), `ArticleExtractor` (1014L — readability extraction), `ArticleExtraction` (façade), `ArticleContent+Readability` (bridge), `PaywallDetector`, `LeadImageExtractor`, `ProductPageDetector` (830L — product-page detection), `ProductMetadataExtractor` (528L — Stage-2 metadata + per-host price rules), `ProductMatcher`, `ProductInfo+TrackerStores`, `GoogleShoppingURL`, `HTMLClassification`. | See table above; all public types have small default-arg inits, no over-parameterized constructors. | Imports match Package.swift exactly; no violations. |
| **LunaFetch** | 2 (455L) | `ArticleFetcher` (`HTMLFetching` protocol + live impl: direct/crawler-UA/referer/cookieless/Wayback/Jina-reader fetch, archive.today + Wayback CDX/Memento parsing), `FaviconFetcher` (icon discovery/ranking). | `HTMLFetching`, `ArticleFetcher`, `FaviconFetcher`. | `FaviconFetcher.swift` doesn't import `LunaURLClassification`/`LunaHTMLClassification` despite the module declaring them — calls `ArticleFetcher` directly instead; not a violation, just an unused-at-file-level declared dependency. |
| **LunaPaywallBypass** | 11 (1063L) | Pipeline: `BypassGate` (pure gate decision) → `BypassStrategySelector` (gate + per-host rules → ordered strategies) → `BypassPlan.make` (splits into silent/web-preStage/archive-today) → `ArticleResolver.resolve` (orchestrates fetch → silent leg → `BypassRunner`) → `BypassRunner` (I/O, runs one silent strategy) → `BypassURLs` (strategy→URL mapper). Plus `BypassRuleTable` (now-vestigial per-host→archive mapping), `SiteUnlockRules`/`SiteUnlockSilent` (500+-site JSON-driven rule engine), `PaywallBypassRules`/`TrailingDotBypass` (trailing-dot URL transform). | See pipeline above. | **No file in the module references `LunaAppConfig` or `LunaPriceMetadata`** (grep: zero hits for either import/symbol) despite both being declared `Package.swift` target dependencies — vestigial declared deps. |
| **LunaPlatforms** | 15 (1085L) | `PlatformModule` protocol + `PlatformRegistry` (6 hardcoded modules, delegates detection to `PlatformRecognizer`); per-platform `XxxLink`/`XxxPlatform`/`XxxMetadataFetcher` for Instagram/Facebook/TikTok/X/Reddit/Bluesky; `OpenGraphScraper`; search clients (`RedditSearchClient`, `BlueskySearchClient`, `DuckDuckGoSearch`); `PlatformEmbedViewController` (UIKit/WKWebView embed player); `SocialPostFinder` (DuckDuckGo-backed, own `Platform` host table). | `PlatformModule`, `PlatformRegistry`, per-platform link/metadata types, `SocialPostFinder`. | `LunaStorage`+`LunaDesignSystem` are pulled in solely for `PlatformEmbedViewController.swift` (store write-back on video-ended JS bridge) — the one UIKit+persistence file in an otherwise pure classification/metadata module. Not a `Package.swift` violation, worth knowing if the module is ever split. |
| **LunaIngest** | 3 (384L) | `IngestPipeline` (the one shared classify-then-route pipeline: `IngestInput`/`Outcome`/`IngestResult`, `process`/`processResolved`/`runUnbounded`/`processWeb`, 28s timeout-guaranteed), `OutcomePresenter` (one-method protocol), `InteropOwnership` (`Outcome`→`InteropSurface?`). | `IngestPipeline`, `OutcomePresenter`, `Outcome`. | Clean; called from 6 production sites across 4 modules with genuinely varied parameter overrides — not over-parameterized. |
| **LunaReadingList** | 7 (1787L) | `ReadingListIngestor` (759L — the orchestrator: save-press entry, per-outcome store-writers, background sweep, cross-app-interop gate), `PriceRefreshCoordinator`, `ArticleExportService`, `PasteboardSuggester`, `EmailShareCenter`, `IncomingMailImporter`, `PreloadCoordinator`. | `ReadingListIngestor` public entry points (`ingest`, `handleSavePress`, `saveNewWithContent`, `ingestAllPending`), plus each coordinator's own small surface. | Imports match declared per-file responsibility; no over-fat imports. `IngestPipeline` vs. `ReadingListIngestor`: no overlap — pipeline is the pure classify/fetch/extract decision, ingestor is the sole production caller turning `Outcome` into store writes + notifications + interop policy. Clean split. |
| **LunaStorage** | 14 (2525L) | `ReadingListStore` (1020L — the shared `readingList.json`, file-coordinated + in-process-locked, in-memory cache added by the perf pass), `PreloadStore`, `ImageReferenceStore`, `CredentialKeychain`, `DiagnosticLog`/`SharedDiagnosticLog` (genuinely distinct — `DiagnosticLog` delegates its actual write/lock to `SharedDiagnosticLog.appendLine`/`withFileLock`, correct layering not duplication), six small App-Group `UserDefaults` stores, `BackupPolicy`, `NetworkReachability`. | `ReadingListStore` (~30 public mutation methods), each store's own small surface. | **`ReadingListStore.swift:7` imports `LunaURLClassification` and uses none of its API** — verified by grepping every public symbol LunaURLClassification exports against the file; only English-word false positives ("matches"/"previously") hit in comments. It's the only file in the module importing that dependency, so removing the import would make the whole `LunaStorage → LunaURLClassification` Package.swift edge removable. |

---

## 2. Findings

### 2.1 Stored-callback communication

This category is **sparse** in this slice — the two prior review passes already
consolidated the big cross-component closures (`SocialMessageCenter.ingestHandler`/
`shareRecorder`, `DiagnosticLog.export*`, `PriceTrackingViewController.defaultSaveAsArticle`)
and those live outside this module set anyway. Only one qualifying closure was found in
scope, and it doesn't need consolidation:

- **`ReadingListIngestor.interopPromptPresenter`** — declared
  `LunaLibraries/Sources/LunaReadingList/ReadingListIngestor.swift:43-44`
  (`public static var (@MainActor (InteropPromptKind, retry: (() -> Void)?) -> Void)?`).
  Set exactly once in production at `Luna/AppDelegate.swift:82`; reset to `nil` in test
  teardown (`LunaTests/ReadingListIngestorInteropTests.swift:39,45`). Invoked at 4 sites:
  `ReadingListIngestor.swift:139` (blocked, with retry), `:171` (needsInstall, no retry),
  `:696` (blocked, `saveNewWithContent`), `:710` (needsInstall, `saveNewWithContent`). It's
  the only stored cross-component closure in scope — no 3-or-more-closures-set-together
  pattern exists here, so there's no delegate/protocol consolidation opportunity *within*
  these files.
- **Cross-module consolidation candidate (flagged, not actionable within this scope):**
  `LunaReadingList`'s `OutcomePresenter`/`IngestorOutcomePresenter`
  (`ReadingListIngestor.swift:737`) and `LunaShareSurface`'s `ShareSurfaceDriver.present`
  are structurally parallel but `ShareSurfaceDriver` does not conform to `OutcomePresenter`
  — its own comment (`ShareSurfaceDriver.swift:223`, outside this audit's file list)
  acknowledges the "shared shape with the main app's `IngestorOutcomePresenter`." This is
  layering-driven (extensions can't pull in `LunaReadingList`'s `LunaSend`/`LunaMail*`/
  `LunaSocial` dependency chain), so it's likely a deliberate split rather than an
  oversight — noted for awareness, and because `ShareSurfaceDriverInteropTests.swift`
  (9 tests) asserts the *same* blocked/needsInstall contract as
  `ReadingListIngestorInteropTests.swift`, so both test files would need to move in
  lockstep if this were ever unified.
- `DiagnosticLog.exportIdentityProvider` (`DiagnosticLog.swift:115`) is a one-shot static
  injection point, not a stored cross-component handler — excluded per the audit's
  carve-out for one-shot config.
- Every other closure-typed property found across all six passes (`KnownSite.path`/`.kind`,
  `PlatformRule.recognizes`/`.itemID`, `WrapperHandler.matches`/`.resolve`,
  `ProductMetadataExtractor.extract(render:)`, `IngestPipeline`'s test-injection seams,
  `ReadingListIngestor.ingestAllPending(completion:)`) is either a declarative rule-table
  row evaluated per-call, or a one-shot completion/DI seam — out of scope by the audit's
  own rules.

### 2.2 Duplicated or disjoint-but-related logic

This is where the real weight of the audit sits. Grouped by theme, worst-first.

#### A. Host-suffix / domain-matching reimplemented independently, with **confirmed behavioral drift**
The idiom "does this host equal or have this domain as a suffix" is written from scratch
at least **6 times** just inside `LunaURLClassification`, plus more in the two modules one
tier up, using at least **3 different algorithms**, and in three cases the duplicates have
already drifted apart:

- `LunaURLClassification/KnownSite.swift:36` (`host == X || host.hasSuffix(".X")` / `Set.contains(where:)` form)
- `LunaURLClassification/PlatformRecognizer.swift:96`
- `LunaURLClassification/NewsAggregatorUnwrapper.swift:32` (`isAppleNews`)
- `LunaURLClassification/NewsAggregatorUnwrapper.swift:215` (`isFacebookHost`)
- `LunaURLClassification/URLUnwrapper.swift:266` (`WrapperHandler.googleShare` matcher)
- `LunaURLClassification/URLUnwrapper.swift:281` (`WrapperHandler.shorteners`)
- `LunaPlatforms/SocialPostFinder.swift` (same idiom, own `Platform` host table)
- `LunaPaywallBypass/BypassRuleTable.swift:19-23` — strips trailing dot, then rewrites the
  identical `host == $0.domain || host.hasSuffix(...)` predicate from scratch.
- `LunaPaywallBypass/SiteUnlockRules.swift:96-105` (`rule(for:)`) — a **different**
  algorithm: peels the leftmost label off `host` in a loop, checking `byDomain[...]` at each
  step, until 2 labels remain.
- **Intra-file duplication**: `LunaPaywallBypass/SiteUnlockRules.swift:113-121`
  (`isNoFix`) is a near-verbatim copy of the label-peeling loop at lines 99-103 in the same
  file, just checking `noFixSet` instead of `byDomain`.

**Confirmed drift** (three `XxxLink` types in `LunaPlatforms` disagree with
`PlatformRecognizer`, the module whose own doc comment calls it "the ONE place URL→platform
rules live"):
- **Instagram**: `PlatformRecognizer.instagram` hosts = `["instagram.com","instagr.am"]`
  (`PlatformRecognizer.swift:190`); `InstagramLink.isInstagram`
  (`InstagramPlatform.swift:14-16`) only matches `instagram.com`/subdomains — an
  `instagr.am` link classifies as Instagram at ingest but `InstagramLink` would reject it.
- **X/Twitter**: `PlatformRecognizer.x` suffix-matches `x.com`/`twitter.com` and any
  subdomain (`PlatformRecognizer.swift:96`); `XLink` (`XPlatform.swift:12-14`) hardcodes an
  exact 5-host set with no suffix fallback — an accepted-by-classification subdomain would
  silently blank the subtitle/deep-link.
- **Reddit**: `PlatformRecognizer.reddit` suffix-matches `redd.it` subdomains (e.g.
  `i.redd.it`); `RedditLink.isReddit` (`RedditPlatform.swift:12-15`) only matches
  `host == "redd.it"` exactly.

No evidence these edge hosts appear in real data today, but this is proven duplicated
logic with proven drift, not just parallel-but-equivalent code.

#### B. `www.`/trailing-slash host normalization reimplemented ≥6 times across 5 modules
`PasteboardSuggester.normalizedKey` (`LunaReadingList/PasteboardSuggester.swift:134-140`)
duplicates the same two rules (strip `www.`, strip trailing slash) independently
implemented in:
- `LunaHTMLClassification/ProductMetadataExtractor.swift:287`
- `LunaPlatforms/RedditPlatform.swift:41`
- `Luna/Reader/SourceIconCache.swift:102` (app shell, out of this audit's module scope)
- `LunaIntents/ArticleSourceName.swift:29` (out of scope)
- `LunaAudioPlayback/AudioPlaybackCenter.swift:535` (out of scope)

None call the module's one existing canonicalizer,
`LunaURLClassification/URLCanonicalizer.swift` — but that helper only strips
tracking-params/fragments, not `www.`/trailing-slash, so it's a related-but-narrower
utility, not a direct substitute today.

#### C. JSON-tree walkers in `LunaHTMLClassification` — real determinism inconsistency
`ProductPageDetector.firstPrice`/`price(inDictionary:)` (`ProductPageDetector.swift:512-548`)
and `firstProductNode` (`:601-613`), and `ProductMetadataExtractor.NextDataPrice
.numericValue`/`firstNumericLeaf` (`ProductMetadataExtractor.swift:481-517`) all explicitly
sort dictionary keys before recursing, with an explicit comment about hash-seed
non-determinism (`ProductPageDetector.swift:506-511,598-600`). But
`ArticleExtractor.findArticleBody` (`ArticleExtractor.swift:132-144`) and
`firstImageURL`/`imageURLString(inJSONLDValue:)` (`:767-796`) — the same "walk
`[String:Any]`/`[Any]` for a key" shape — iterate `dictionary.values` in **raw, unsorted**
order. Two files doing the same kind of JSON-LD graph walk, one launch-to-launch
deterministic, the other not, for hero-image/article-body recovery.

#### D. Embedded app-state JSON blob scanning duplicated
`ProductPageDetector.embeddedJSONBlobs` (`ProductPageDetector.swift:446-468`, private)
scans `__NEXT_DATA__` → `application/json` scripts → inline `window.__X__ = {…}`
assignments (via `firstJSONObjectLiteral`, `:473-500`).
`ProductMetadataExtractor.NextDataPrice.jsonBlobs` (`ProductMetadataExtractor.swift:459-474`,
private) reimplements the first two of those three sources from scratch — byte-for-byte
the same selector strings (`script#__NEXT_DATA__`, `script[type=application/json]`) —
missing only the `window.__` case. Two private near-identical blob scanners in two types.

#### E. URL-resolution-against-base reimplemented 3 ways
- `ArticleExtractor.resolvedImageURL` (`ArticleExtractor.swift:897-909`) — validates
  non-empty, rejects `data:`, requires `http`/`https` scheme.
- `ProductPageDetector.resolveURL` (`ProductPageDetector.swift:818-821`, public static) —
  no scheme/`data:` filtering at all.
- `ProductMetadataExtractor.GoogleShoppingProductParser.sellerURL`
  (`ProductMetadataExtractor.swift:169-183`) — a third variant with an explicit
  `hasPrefix("http://")` check plus its own Google-redirect unwrap.

None call each other.

#### F. Meta-tag content lookup (property-or-name) reimplemented independently
`ArticleExtractor.leadImageURL`'s inline meta loop (`ArticleExtractor.swift:727-741`) vs.
`ProductPageDetector.metaContent` (`ProductPageDetector.swift:783-793`) — same conceptual
"find first non-empty meta content by any of these keys" operation, different code. (This
is distinct from the already-deliberately-deferred `LeadImageExtractor` vs.
`ArticleExtractor.leadImageURL` regex-vs-DOM pair — do not conflate the two.)

#### G. Currency-from-symbol/host resolution scattered, with a **literal duplicate**
`PriceParsing.normalizeCurrency` (`LunaModels`, out of scope, the nominal single source) is
wrapped by `ProductPageDetector.normalizeCurrency` (`ProductPageDetector.swift:814-815`).
Separately:
- **`AmazonPriceRule`/`amazonCurrency(forHost:)` is duplicated verbatim in two files**:
  `ProductPageDetector.swift:271-292` and `ProductMetadataExtractor.swift:352-358` — the
  same TLD→currency table exists twice.
- `GoogleShoppingProductParser.currency(in:sellerURL:)`
  (`ProductMetadataExtractor.swift:236-248`) is a third, independent host/symbol
  disambiguation (`"A$"`/`"AU$"`/`"US$"` string checks, then `.au`-suffix host check, then
  falls back to the generic normalizer).

#### H. Coordinated "load → mutate → save" JSON-index wrapper implemented 3 times in `LunaStorage`
`ImageReferenceStore.mutate<T>` (`ImageReferenceStore.swift:81-95`) and
`PreloadStore.mutate<T>` (`PreloadStore.swift:177-192`) are structurally copy-pasted
(`NSLock` → `perform(url)` closure → `NSFileCoordinator.coordinate(writingItemAt:...)` →
fallback `perform(indexURL)` if the coordinator didn't run). `ReadingListStore
.coordinatedMutate`/`.coordinatedUpdate` (`ReadingListStore.swift:911-986`) does the same
core thing but is meaningfully more elaborate (adds the perf-pass cache token,
equality-based skip-write, and notification posting). The first two are close enough in
shape to unify directly; `ReadingListStore`'s version differs enough that folding it in too
would be a bigger, riskier lift.

#### I. `TrailingDotBypass` vs `PaywallBypassRules` — redundant wrapper with duplicated tests
`TrailingDotBypass.trailingDotURL`/`.isNYTHost` (`TrailingDotBypass.swift:22-31`) are pure
one-line forwarders to `PaywallBypassRules.trailingDotURL`/`.isNYTHost`
(`PaywallBypassRules.swift:4-15`). Two public types expose identical logic under different
names, each with its own dedicated test file (`TrailingDotBypassTests.swift`, 6 tests, and
`LunaLibraries/Tests/LunaPaywallBypassTests/PaywallBypassRulesTests.swift`, testing the same
behavior through the other name). Only `TrailingDotBypass` has production callers
(`BypassStrategySelector.swift:44`, `BypassPlan.swift:148,164`) — `PaywallBypassRules` is
reachable only through its own tests and through `TrailingDotBypass`.

#### J. Search-client / fetch-JSON boilerplate duplicated ~8× in `LunaPlatforms`
`RedditSearchClient` (`:20-43`), `BlueskySearchClient` (`:29-50`), and
`DuckDuckGoSearch.results` (`:17-28`) are three near-identical `URLComponents →
URLSession.shared.data → HTTPURLResponse status check → decode` bodies. The same shape
recurs in the 5 `PlatformMetadataFetching` implementations' fetch bodies
(`TikTokPlatform.swift:59-66`, `XPlatform.swift:81-88`, `RedditPlatform.swift:65-71`,
`BlueskyPlatform.swift:36-47`). A shared `getJSON<T: Decodable>(url:) async -> T?` helper
could collapse ~8 call sites — low-traffic, low-risk, moderate value.

#### K. Internal near-duplication inside `ReadingListIngestor`
The blocked/needsInstall interop-branch logic in `ReadingListIngestor.ingest`
(`ReadingListIngestor.swift:131-146,168-173`) is near-verbatim duplicated in
`ReadingListIngestor.saveNewWithContent` (`:691-703,707-712`) — same-file, same-author,
same shape, just gated on a synthetic `.article` outcome instead of a real pipeline result.
A bug fix to one interop branch's ordering (e.g. delete-before-prompt) would need to be
hand-replicated to the other.

#### L. Dedup logic across `EmailShareCenter`/`IncomingMailImporter`/`PasteboardSuggester` — disjoint by design, not a real dupe
Flagged only because it's easy to conflate at a glance: `IncomingMailImporter` dedupes via
`store.addIfAbsent` (exact URL); `PasteboardSuggester.isAlreadySaved` does three-tier
matching (exact / platform-post-id / normalized host+path) for a pre-save suggestion;
`ReadingListIngestor.ingestProductTracker`'s tracker-merge dedup (exact store-URL match,
post-resolution) serves a third distinct purpose. No two implement the same rule the same
way — this is **not** a consolidation candidate, listed here only to close the loop on the
brief's suggestion to check it.

#### M. `testDefaultsOverride`/`resolvedDefaults` copy-paste (self-acknowledged, low value)
`LunaStorage/SafariURLStore.swift:26-30` and `LunaStorage/ScreenshotDoublePressStore.swift:39-43`
copy-paste the identical test-injection pattern; both files' own comments say they mirror
each other.

### 2.3 Overly complex code

- **`ArticleExtractor.refinedBlocks`** (`ArticleExtractor.swift:151-197`) — 47 lines mixing
  six concerns: builds a 20-line/~50-selector inline CSS junk-removal string (`:158-178`),
  then orchestrates paywall-junk removal, hidden-element removal, container scoring,
  conditional cleaning, block extraction, and a length-fallback-to-body. The single largest
  concentration of responsibility in the file.
- **The "trailing junk" subsystem** (`ArticleExtractor.swift:271-466`, ~195 lines:
  `trimTrailingJunk`, `removeInlineJunkLines`, `applyTerminatorHardStop`, `reverseTrim`,
  `stripTrailingImageRun`, `isReverseTrimPoppable`, plus 4 phrase/word constant sets) — a
  full boilerpipe-style state machine spread across private methods on one struct rather
  than its own type. Individually readable, well-commented, but the aggregate (6 heuristic
  passes, thresholds 60 words / 15 words / 140 chars / 80 chars / 0.6 / 0.33 / 0.5
  link-density) is hard to reason about as a whole and impossible to unit-test in isolation.
- **`ArticleExtractor.extract`** tier-arbitration block (`:28-84`, specifically `:48-57`) —
  hardcodes three magic thresholds (`350`, `×3`, `1200`) with the reasoning living only in a
  prose comment (`:38-47`), not named constants.
- **`ArticleExtractor.bestContainer`** (`:524-575`) — three scoring strategies layered in
  one method: Readability-style ancestor-weighted scoring, a widen-until-60%-coverage loop,
  and an article-body-selector short-circuit.
- **Duplicated *complexity*, not just lines**: `ProductPageDetector` and
  `ProductMetadataExtractor` each independently implement a full recursive "find price node
  in arbitrary JSON" walker (§2.2 C/D/G) — a future edge-case fix (e.g. array-of-offers)
  must be hand-replicated in both.
- **`ReadingListIngestor.ingest(_:forceArticle:prefetchedHTML:trustsPrefetchedHTML:allowsInteractivePrompt:)`**
  (`ReadingListIngestor.swift:82-175`, 93 lines) — mixes in-flight concurrency dedup
  (lock/set), pipeline invocation, store URL repointing, cross-app-interop gate evaluation,
  store deletion on block, diagnostic logging, `@MainActor` prompt presentation with an
  inline retry closure, price-tracker re-save dedup + merge notification, presenter
  dispatch, and a second interop branch (needs-install) with its own MainActor hop. The
  single highest-complexity method found across all six passes.
- **`ReadingListIngestor.handleSavePress(...)`** (`:550-621`, 72 lines) — mixes double-save
  policy resolution, store add, an interop-gate-skip fast path for App Intents, ereader-send
  fan-out, friend-send with its own error swallowing, friend-prompt-store write, and
  diagnostics, across a 5-case switch each with a different side-effect shape.
- **`ReadingListIngestor.saveNewWithContent`** (`:682-728`, 47 lines) — see §2.2 K, also a
  complexity finding in its own right (duplicates the same 6-concern shape as `ingest`).
- **`ReadingListStore`'s send-state machine** (`:351-443`) — 5 parallel per-destination
  dictionaries (`sendStates`, `sendFailureCounts`, `sendNextAttemptDates`,
  `sendLastErrors`, `pendingSendFailureNotices`) spread across 5 methods
  (`setSendState`, `markSendAttemptStarted`, `scheduleSendRetry`,
  `markSendTerminalFailure`, `consumePendingSendFailureNotices`) with overlapping
  side-effect footprints. Not a bug; a consolidation candidate into one small
  state-transition type if this area is touched again.

**Explicitly checked and found clean (no god methods / no over-parameterization):**
`LunaModels`/`LunaAppConfig`/`LunaURLClassification` (all pure value types/declarative
tables); `LunaPlatforms` (`RedditMetadataFetcher.bestImageURL`,
`RedditPlatform.swift:95-137`, is the densest function — a justified 5-branch Reddit-JSON
fallback ladder, well-commented, not flagged); `LunaFetch`/`LunaPaywallBypass`
(`ArticleResolver.resolve`, 56 lines, is the biggest single function and is linear; its
6 parameters all serve either the one production call site or a distinct test-injection
seam — judged legitimate DI-for-testability, not accidental over-parameterization).

### 2.4 Dead/unused code

Every item below was verified with a repo-wide grep (production + tests + all three app
targets + extensions), quoted per-item by the originating pass.

1. **`NonTextualContent.embedURL`** (`LunaURLClassification/NonTextualContent.swift:26-31`)
   — `grep -rn '\.embedURL\b'` (whole repo, excluding the stray worktree) → zero call
   sites anywhere, not even a second definition reference. Dead.
2. **`NonTextualContent.embedReferer`** (`NonTextualContent.swift:33`) — same grep pattern
   → zero callers. Dead.
3. **`NonTextualContent.staticPreviewImageURL`** (`NonTextualContent.swift:35-40`) — *not*
   fully dead: one call site, `Luna/.../SavedNonTextualViewController.swift:142`
   (`if let posterURL = content.staticPreviewImageURL`), but the property's only enum case
   (`.platform`) unconditionally returns `nil`, so that call-site branch can never execute.
   Vestigial always-`nil` accessor, not a clean deletion candidate on its own (the call site
   lives in a module outside this audit's scope).
4. **`HTMLClassification.hasProductStructuredData(in:)`**
   (`LunaHTMLClassification/HTMLClassification.swift:18-24`) —
   `grep -rn "hasProductStructuredData" --include="*.swift" .` → only its own definition,
   no callers anywhere. Dead.
5. **`import UIKit` in `LunaPlatforms/PlatformModule.swift:7`** — `grep -n "UI[A-Z]"` on the
   file → no matches; nothing in the file uses UIKit. Likely leftover.
6. **`import LunaURLClassification` in `LunaStorage/ReadingListStore.swift:7`** — see §1;
   zero symbols used, only file in the module importing it.
7. **`ReadingListStore.priceTracker(containingStoreURL:)`**
   (`ReadingListStore.swift:610-619`) — `grep -rn "priceTracker(containingStoreURL"
   --include="*.swift" .` → only the definition. Dead.
8. **`ReadingListStore.setLastWordIndex(_:for:)`** (`ReadingListStore.swift:210-217`) —
   `grep -rn "setLastWordIndex" --include="*.swift" .` → only the definition + its own
   doc comment (which itself claims callers still use it standalone — they don't; RSVP now
   goes through the batched `saveReaderExitPosition(lastWordIndex:)` per PERF_REVIEW_PLAN
   item 5). Dead, and its own comment is now inaccurate (see §2.5).
9. **`ReadingListStore.restore(_:)`** (`ReadingListStore.swift:656-658`) — zero call sites
   including tests; its doc comment says "reserved for test seeding" but every test seeds
   via `seedForTesting`/`wipeForTesting` (both DEBUG-gated, both with real call sites in
   `Luna/UITestSeeder.swift` and 3 `LunaTests` files). Dead, and its own comment is
   inaccurate.
10. **`import LunaFetch` in `LunaFetch/ArticleFetcher.swift:6`** — self-import; this file
    *is* `LunaFetch`. Harmless but meaningless.
11. **`LunaPaywallBypass` target's declared `Package.swift` dependencies on
    `LunaAppConfig` and `LunaPriceMetadata`** — zero references to either in the module's
    11 source files. Vestigial declared dependency edges, not code, but "dead" at the
    build-graph level.
12. **9 decoded-but-never-consumed fields on `SiteUnlockRule`** — `headersCustom`,
    `randomIP`, `removeCookiesSelectHold`, `ampUnhide`, `ampRedirect`, `ldJson`,
    `ldJsonNext`, `ldJsonSource`, `ldJsonUrl`
    (`LunaPaywallBypass/SiteUnlockRules.swift:35,37,43,49-56,57-59`). Verified via
    `grep -rn "\.<field>\b" --include="*.swift" .` excluding the model file itself — zero
    production consumers for any of the nine, in contrast to `blockRegex`/`blockJsInline`
    (consumed in `LunaArchiveReader/PaywallUnlockRules.swift:173-174`) and
    `useragent`/`useragentCustom`/`referer`/`refererCustom`/`allowCookies`/`removeCookies`/
    `removeCookiesSelectDrop`/`clearLocalStorage` (consumed in `SiteUnlockSilent.swift`).
    Not classic dead code — they're decoded purely to be tested
    (`SiteUnlockRulesTests.swift:26`) but never acted on, apparently because the
    browser-tier DOM-reconstruction (`ldJson*` family) and header/IP-override features
    haven't been ported from the JS site-rule generator yet.

### 2.5 Comment hygiene

| file:line | Problem | Suggested rewrite (or "delete") |
|---|---|---|
| `LunaURLClassification/RegexCapture.swift:8-9` | Change-narration: "(was quadruplicated across the aggregator unwrapper, product detector/extractor, and lead-image extractor)" | "The one first-capture-group regex helper shared by URL/HTML classification and the paywall bypass layer." |
| `LunaURLClassification/NewsAggregatorUnwrapper.swift:16-23` | Narrates deleted code: "The old async `unwrap`/`normalizedIncomingURL*` shims were deleted once the last callers moved to…" | Delete that sentence; keep only: "This enum is the home of the pure, well-tested wrapper parsers… the app-wide unwrap dispatch lives in `URLUnwrapper`, whose `[WrapperHandler]` registry wraps these parsers." |
| `LunaURLClassification/URLUnwrapper.swift:193-197` | Change-narration: "The parsers are unchanged and stay fully unit-tested; only the registry dispatch is new." | "Each factory wraps the existing pure parsers on `NewsAggregatorUnwrapper`… into a `WrapperHandler` for the registry." |
| `LunaHTMLClassification/ArticleContent+Readability.swift:5-8` | Stale forward-reference: "...this extension lives alongside those detectors and migrates into LunaHTMLClassification when that module extracts" — the file already lives there; the described migration already happened. | "Readability judgments that depend on the HTML-classification layer (ArticleExtraction/PaywallDetector) — kept off the LunaModels value type so the base model stays pure." |
| `LunaHTMLClassification/ArticleExtractor.swift:38-47` | Narrates the history of a fix ("the old `refined*3 >= basic` guard wrongly fell back to that soup and dropped the article body") instead of stating the current rule. | "A SUBSTANTIAL refined result (≥1200 chars) is trusted outright even when `basic` is larger — comment-heavy pages inflate `basic` with content refined correctly strips. A MEDIUM refined result (350–600) additionally requires `refined*3 >= basic`, since a small refined result more likely means junk-class stripping ate real content." |
| `LunaHTMLClassification/ArticleExtractor.swift:723-726` | "…neither of which was covered by the old body-only extraction." | Drop the trailing clause: "Several publishers use `og:image:secure_url`; large images are often only in `twitter:image:src`." |
| `LunaHTMLClassification/ArticleExtraction.swift:23-30` | "...so the duplicate helpers in `ArticleResolver` and `BypassRunner` collapse into one." | "...so every fetch-then-extract call site shares one implementation." |
| `LunaHTMLClassification/ArticleExtraction.swift:52-54` | "Consolidates the three former duplicate checks (...) into one..." | "THE single readable-vs-paywall-stub predicate, shared by the resolver, `ArticleContent.hasReadableBody`, and `BypassGate`." |
| `LunaHTMLClassification/ProductMetadataExtractor.swift:56-60` | "There is no detect-then-refetch double parse (the former \"sometimes saves\" root)." | "One parse, one price source per extraction — no detect-then-refetch double parse." |
| `LunaPaywallBypass/BypassStrategySelector.swift:26-28` | Copy-paste artifact: the same 8-word clause about "no generic paywall evidence" is duplicated across the line break. | "A site rule may bypass even when the gate found no generic paywall evidence — but ONLY for the 'no evidence' block, never overriding a readable article / product page / platform link." |
| `LunaPaywallBypass/BypassStrategy.swift:44` and `LunaPaywallBypass/BypassPlan.swift:45` | Garbled text: "the the reference paywall rules" (doubled "the", odd noun phrase — reads like a mangled find-and-replace of a real tool name). Same artifact also appears at `LunaArchiveReader/ArchiveWebReaderViewController.swift:170,198`, outside this audit's file list but sharing the fix. | `BypassStrategy.swift:44-45`: "...the rendered DOM is extractable. WKWebView-only — the core technique." `BypassPlan.swift:45-46`: "...DOM-cleanup userscript (the core direct-unlock technique)." |
| `LunaPaywallBypass/BypassGate.swift:20` | Stale reference: "Tested by `BypassGateTests`" — that file was deleted in commit `97833a34` ("Clean up broken integrations", 2026-07-07; confirmed via `git show 97833a34 -- LunaTests/BypassGateTests.swift`, 133 lines removed). `BypassGate.decision` is now exercised only indirectly via `PaywallBypassRulesTests.swift:27,34`. | Delete the sentence, or replace with "Exercised via `PaywallBypassRulesTests` and transitively by every `BypassStrategySelector`/`BypassPlan` test." |
| `LunaPaywallBypass/SiteUnlockRules.swift:14-15` | Factually wrong: claims `ldJsonUrl` "is carried in the JSON but not decoded here yet" — it *is* decoded (`line 55: public let ldJsonUrl: String?`). | "`csCode` (a small nested cleanup DSL used by a few sites) is carried in the JSON but not decoded here; it belongs to the browser tier. `ldJsonUrl` is decoded but not yet consumed (needs a second network fetch to resolve)." |

**Explicitly checked and found clean:** `LunaModels`, `LunaAppConfig`, `LunaURLClassification`
(aside from the 3 items above), `LunaPlatforms` (swept for
`used to|no longer|previously|removed|deprecated|legacy` — the one hit,
`SocialPostFinder.swift:37`, is present-tense usage, not narration), `LunaStorage` (swept
for the same terms plus TODO/FIXME/"Phase N" — every hit documents current on-disk/
cross-process behavior, not history), `LunaIngest`/`LunaReadingList` (swept for
`used to / no longer / previously / legacy / old path / was broken / now correctly / fixed
/ bug / regression` — the two hits, `ReadingListIngestor.swift:408,476`, describe genuinely
still-existing dual code paths, not stale narration).

---

## 3. Test coverage note

### LunaModels / LunaAppConfig / LunaURLClassification
`LunaTests/URLUnwrapperTests.swift` (274L), `NewsAggregatorUnwrapperTests.swift` (194L),
`NewsSitesJSParityTests.swift` (83L), `LunaDeepLinkTests.swift` (111L),
`BlueskyLinkTests.swift` (42L), `PriceTrackerTests.swift` (295L), `PriceHistoryTests.swift`
(98L), `PriceFormattingTests.swift` (33L), `ZipArchiveWriterTests.swift` (69L),
`ReaderResumePositionResolverTests.swift` (117L); package-level
`LunaLibraries/Tests/LunaAppConfigTests/AppConfigTests.swift`,
`LunaModelsTests/ArticleBlockRenderingTests.swift`. **API-shape pins:** `URLUnwrapperTests`
pins `UnwrapResult.{url,didUnwrap,wrapper}`/`WrapperKind` cases; `NewsAggregatorUnwrapperTests`
pins the exact `public static` signatures of `appleNewsPublisherURL(inHTML:)`,
`googleNewsArticleID(from:)`, `googleNewsURL(fromArticleID:)`, `facebookRedirectTarget(_:)`
— don't fold these into `URLUnwrapper` without preserving the entry points.
`PriceTrackerTests`/`PriceHistoryTests` pin `PriceTracker.{setPrice,recordPriceSample,
upsertStore,markAlertViewed}` and `PriceHistory.{series,bucket(forSpanDays:)}` exactly.

### LunaHTMLClassification
Heavily and directly tested at the public-API boundary — `ArticleExtractorTests.swift`
(468L/21 tests), `ArticleExtractionTests.swift` (124L/6), `ArticleContentPaywallTests.swift`
(72L/5), `PaywallDetectorTests.swift` (92L/8),
`LunaLibraries/Tests/LunaHTMLClassificationTests/HTMLClassificationTests.swift` (32L),
`ProductPageDetectorTests.swift` (328L/29), `ProductMetadataExtractorTests.swift` (149L/13),
`ProductPageSuggestionTests.swift` (84L/6), `ProductMatcherTests.swift` (115L/8),
`LeadImageExtractorTests.swift` (162L/18), `JSONLDExtractorTests.swift` (49L/4),
`GoogleShoppingProductParsingTests.swift` (67L/2). **Nothing pins private-method shapes** —
`ArticleExtractorTests` only calls `.extract(html:baseURL:)`, so internal restructuring
(e.g. unifying the §2.2 C/D/E/F/G duplication) is safe as long as public outputs are
preserved. **The one hard constraint**: `ProductPageDetectorTests`
(`testBunningsDetectionIsDeterministicAcrossManyRuns`,
`testFirstPriceIsOrderStableWithMultiplePriceObjects`,
`testJSONLDProductSelectionIsOrderStable`) directly pins the sorted-key determinism
behavior — any consolidation of the JSON-tree walkers (§2.2 C) must preserve deterministic
ordering or these 3 tests will flake. `ProductMetadataExtractorTests
.testRenderTierUnreachableWhenRenderIsNil` pins that the `render:` seam stays
structurally unreachable when `nil`.

### LunaFetch / LunaPaywallBypass
Comprehensively covered 1:1: `ArticleFetcherTests.swift` (12, pins `originalURL
(fromArchiveURL:)`/`newestMemento(fromTimeMap:)`/`articleTitleGuess`/
`newestSnapshotTimestamp(fromCDXJSON:)` as pure static), `SourceBadgeTests.swift` (pins
`FaviconFetcher.iconLinkCandidates` as I/O-free), `BypassPlanTests.swift` (3, pins
`SilentStrategy`/`WebStrategy` cases + `silentChainDeadlineSeconds = 20`),
`BypassRuleTableTests.swift` (6), `BypassRunnerTests.swift` (13, pins every
`BypassStrategy` case's dispatch), `BypassStrategySelectorTests.swift` (5, pins ordering),
`SiteUnlockRulesTests.swift` (9, pins `ruleCount > 500`/`generalBlockers.count > 20`),
`SiteUnlockSilentTests.swift` (7, pins `FetchKind` precedence order),
`TrailingDotBypassTests.swift` (6, redundant with the package-level
`PaywallBypassRulesTests.swift` per §2.2 I — any consolidation must merge or keep both
green), `ArticleResolverTests.swift` (12, pins `ArticleResolution` equality +
`trustsPrefetchedHTML` short-circuit). `BypassGate.decision`'s `Decision`/`Signal`/`Block`
enum cases have **no dedicated test file** (see §2.5 — the doc comment referencing
`BypassGateTests` is stale); coverage is indirect via `PaywallBypassRulesTests.swift` only.

### LunaPlatforms
`PlatformParsersTests.swift` (pins the exact per-platform host lists shown to have drifted
in §2.2 A — e.g. `TikTokLink.isTikTok` on `vm.tiktok.com`, `RedditLink.jsonURL` string
shape), `BlueskyLinkTests.swift`, `SocialPostFinderTests.swift` (its own `Platform.hosts`/
`postMarkers` table), `OpenGraphScraperTests.swift`. `PlatformFieldSaveTests.swift`
(in `LunaIntents`, not this module) depends on `BlueskySearchClient`/`RedditSearchClient`/
`SocialPostFinder`'s public signatures — re-run it if those change.
`SocialMediaResolverTests.swift`/`RedditMediaParserTests.swift` actually test
`LunaMediaDownload`, not `LunaPlatforms`, despite the name overlap — don't double-count
them as coverage for this module.

### LunaIngest / LunaReadingList
`ReadingListIngestorInteropTests.swift` (9 tests) covers `ingest`/`handleSavePress`/
`saveNewWithContent`'s interop branches directly and pins
`interopPromptPresenter`'s exact closure signature — any consolidation of the §2.2 K
duplicated blocked/needsInstall logic must preserve this signature and the
delete-before-prompt ordering these tests assert. `IngestPipelineBrowserFallbackTests.swift`
(3) pins `IngestPipeline.process`'s signature with mock-fetcher injection.
`ArticleExportServiceTests.swift` (3) pins `writeEPUB`/`itemProvider`/
`ExportError.noContent` by name. `IncomingMailImporterTests.swift` (7) covers only the
static helpers (`isLunaShareSubject`/`titleStrippingLunaPrefix`) — the instance methods
(`importNewMail`/`autoImport`/`queuePending`) have **no direct unit test in this file**.
**No test in scope pins `ReadingListIngestor`'s internal method decomposition** — all
coverage goes through the public `ingest`/`handleSavePress`/`saveNewWithContent` entry
points, so the god-methods in §2.3 could be internally decomposed without breaking any
test, provided public signatures and the blocked/needsInstall/store-delete ordering are
preserved.

### LunaStorage
**No dedicated `ReadingListStoreTests.swift` exists** — it's exercised only indirectly via
`ArticleCoverThumbnailTests`, `ArticleExportServiceTests`, `PriceTrackerTests`,
`PriceRefresherTests`, `ReaderScreenTests`, `CatchUpAndPriceScreenTests`,
`ReadingListIngestorInteropTests`, `ShareSurfaceDriverInteropTests`, `UITestSupport`.
**Real gap found**: PERF_REVIEW_PLAN items 2 and 3 both specify tests that don't appear to
exist — no test (a) writes the store file externally and asserts the next `items()` call
picks it up, or (b) asserts a no-op `add`/`savePriceTracker` does **not** post
`.readingListChanged`. (Grepped for any assertion on `.readingListChanged` tied to
`ReadingListStore` mutations — the only hit, in `AudioScriptPipelineTests.swift`, is
unrelated.) The cache-coherence and skip-write behaviors the perf pass added are currently
covered only incidentally by whatever store usage the other suites happen to exercise — a
refactor of the cache/coordination logic has no direct regression net today.
`ImageReferenceStoreTests.swift`/`PreloadStoreTests.swift` cover their stores' pure index
logic directly and would catch a `mutate<T>` consolidation (§2.2 H) regression.
`SafariURLStoreFreshnessTests`/`ScreenshotDoublePressTests`/`SafariExtensionStatusStoreTests`/
`DoubleSaveActionStoreTests`/`ActionButtonOnboardingStateTests`/`CredentialKeychainTests`/
`DiagnosticLogTests` each map 1:1 to their production file with exact signature pins (e.g.
`ActionButtonOnboardingStateTests` pins the exact state-machine transition table).

**Verified: the PERF_REVIEW_PLAN's `ReadingListStore` changes landed as documented.** Cache
fields (`ReadingListStore.swift:52-69`), `items()`'s cache-token check (`:113-131`),
skip-write-via-`Equatable` in `coordinatedMutate` (`all != decoded`, `:920`), the batched
`saveReaderExitPosition(lastWordIndex:)` (`:244-284`), the updated class doc comment
describing the cache (`:16-22`, not the stale "reads fresh every call" line), and the
single (non-redundant) `public` modifier (`:11-14`) are all present and correct — none of
this is re-reported as a finding, per the audit's rules; it's confirmed-good, not a
regression.

---

## Top 10 highest-value changes

Ranked by (proven-bug-risk / maintenance-cost) × (mechanical simplicity). All are
consolidation/cleanup opportunities only — no functional-change proposals, per the audit's
rules.

1. **[M]** Consolidate host-suffix/domain matching across `LunaURLClassification`
   (`KnownSite`/`PlatformRecognizer`/`NewsAggregatorUnwrapper`/`URLUnwrapper`) and fix the
   **confirmed drift** between `PlatformRecognizer` and `LunaPlatforms`' `XLink`/
   `RedditLink`/`InstagramLink` (§2.2 A). Highest value: this is the only theme with proven
   latent behavioral bugs, not just style duplication.
2. **[S]** Deduplicate the literal `AmazonPriceRule`/`amazonCurrency(forHost:)` table that
   exists verbatim in both `ProductPageDetector.swift:271-292` and
   `ProductMetadataExtractor.swift:352-358` (§2.2 G). A byte-for-byte duplicate is the
   cheapest, highest-confidence fix in the whole audit.
3. **[M]** Consolidate the `LunaHTMLClassification` extraction-heuristic duplication
   bucket: JSON-tree walkers' determinism inconsistency (§2.2 C), embedded-blob scanners
   (§2.2 D), URL-resolution-against-base (§2.2 E), and meta-tag lookup (§2.2 F). Must
   preserve `ProductPageDetectorTests`' 3 determinism assertions (§3).
4. **[S/M]** Deduplicate `ReadingListIngestor`'s blocked/needsInstall interop-branch logic
   between `ingest` and `saveNewWithContent` (§2.2 K / §2.3). Must preserve
   `ReadingListIngestorInteropTests`' exact ordering assertions (§3).
5. **[S]** Repo-wide dead-code sweep for this pass's 12 confirmed-dead items (§2.4) —
   mechanical deletions, batched as one cleanup commit.
6. **[S]** Collapse `TrailingDotBypass`/`PaywallBypassRules` (§2.2 I) and merge or retire
   the duplicate test file.
7. **[S/M]** Close the test-coverage gap on `ReadingListStore`'s cache-coherence and
   skip-write-when-unchanged behavior (§3) — add the two tests PERF_REVIEW_PLAN items 2/3
   specified but that don't exist, *before* any further refactor touches this file.
8. **[M]** Unify `LunaStorage`'s copy-pasted `NSLock`+`NSFileCoordinator` "coordinated
   mutate" wrapper between `ImageReferenceStore.mutate<T>` and `PreloadStore.mutate<T>`
   (§2.2 H) — leave `ReadingListStore`'s more elaborate version alone for now.
9. **[M]** Consolidate the `www.`/trailing-slash host-normalization logic duplicated
   across ≥6 files in 5 modules (§2.2 B) into one shared helper (extend
   `URLCanonicalizer` or add a sibling) — mechanical but touches many call sites carefully.
10. **[S]** Fix the 13-item comment-hygiene batch (§2.5), including one factual error
    (`SiteUnlockRules.swift:14-15`'s wrong claim about `ldJsonUrl`) and one stale reference
    to a deleted test file (`BypassGate.swift:20`) — cheap, zero-risk, immediately improves
    accuracy for the next person reading this code.

**Lower-priority items not in the top 10** (still real, smaller payoff): the `LunaPlatforms`
search-client/fetch-JSON boilerplate duplicated ~8× (§2.2 J); the cross-module
`OutcomePresenter`/`ShareSurfaceDriver.present` parallel-shape consolidation, blocked by
layering (§2.1); `ReadingListStore`'s 5-dictionary send-state machine (§2.3); the
`testDefaultsOverride` copy-paste between two `LunaStorage` files (§2.2 M); dropping the
stray `import UIKit` (`PlatformModule.swift:7`), `import LunaFetch`
(`ArticleFetcher.swift:6`), and `import LunaURLClassification`
(`ReadingListStore.swift:7`) — each already listed in the dead-code sweep (item 5 above)
but worth calling out individually since each also cleans up a `Package.swift` edge.

**Overall assessment**: consistent with the two prior review passes' framing — this area
is **mostly clean**. `LunaModels`/`LunaAppConfig`/`LunaURLClassification`/`LunaPlatforms`
came back near-spotless (a handful of dead accessors and comment nits each). The real
concentration of findings is exactly where the module sizes predict it: the two largest
files (`ArticleExtractor.swift`, `ProductPageDetector.swift`/`ProductMetadataExtractor.swift`)
and the orchestration tier (`ReadingListIngestor.swift`), plus one genuine cross-cutting
theme (host-matching duplication with proven drift) that spans three modules.
