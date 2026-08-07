# URL Pipeline (staged simplification)

A staged refactor toward one deterministic-first, composable pipeline run identically on every input surface (paste, typed URL, share/action extension, app intent, friend share). Master plan + audits: `claudedocs/audit/00-PLAN.md` and `01`–`07`.

Target stages: **1 Unwrap** → **2 Classify** → **3 Process** (per-kind) → **4 Surface** (one timeout, exhaustive presenter).

## Stage 1 — Foundation (DONE; additive)

Stage 1 builds the determination foundation as NEW pure `ReaderKit` files with comprehensive tests. It is **additive**: the live pipeline (`ReadingListIngestor` / `ArticleResolver` / `ShareViewController` / `ArticleIngestDecider`) is unchanged and still drives every save. Stages 3–4 repoint callers to these types and delete the old gating tangle. Everything below is pure (no UIKit/network), so the main app and every extension share one implementation.

### `ReaderKit/ContentKind.swift`

`enum ContentKind: Equatable` — the single exhaustive classification result for a saved URL. Carries only the MINIMAL evidence that named the kind (never extracted content / fetched price / bypass state):

```
.article
.paywalledArticle(hardHost: Bool)          // hardHost ⇒ archive-CAPTCHA-only
.product(ProductSignal)
.social(ContentPlatform, itemID: String?)  // x / bluesky / reddit / instagram
.document(type: String)                     // save-time flag, always wins
.undetermined                               // table miss + heuristics inconclusive
```

`enum ProductSignal: Equatable` = `.knownShopHost` (trusted table row) | `.structuredData` (JSON-LD/OG/microdata price) | `.heuristicScore(Int)` (fuzzy retail signals).

### `ReaderKit/KnownSite.swift`

`struct KnownSite` — one row of the deterministic, EXTENSIBLE site table. `hosts: [String]` (host-suffix match — covers `www.` + subdomains), optional `path: (([String]) -> Bool)?` predicate over path segments, and `kind: (URL) -> ContentKind` (closure so a row can read an itemID). `matches(_ url:)` = host-suffix hit AND (if present) path predicate. **Adding a site = appending one row.**

### `ReaderKit/Classifier.swift`

`enum Classifier` — THE classifier. `classify(url:html:documentType:) -> ContentKind`, two phases in strict order:

1. **Deterministic `[KnownSite]` table FIRST** (URL-only). `documentType` (save-time flag) wins outright. Then `knownSites = platformSites + shopSites + newsSites`:
   - **shopSites** — long lists → `.product(.knownShopHost)`: Amazon (all TLDs + `amzn.to`), target/walmart/bestbuy/ebay/etsy/wayfair/homedepot/lowes/costco/ikea/newegg/aliexpress/temu/macys/nordstrom/argos/currys/johnlewis/bunnings.com.au/jbhifi.com.au/… A deterministic shop hit skips the fuzzy heuristic scorer entirely (fewer false positives).
   - **newsSites** — `hardPaywallNewsSites` → `.paywalledArticle(hardHost: true)` (folds in `ArticleFetcher.hardPaywallHosts` + smh.com.au/theage.com.au/afr.com/…); `freeNewsSites` → `.article` fast-path (guardian/bbc/reuters/apnews/wikipedia/techcrunch/theverge/…).
2. **HTML heuristics** — run ONLY when the table is `.undetermined` AND `html` is supplied (a `nil` html caller stops at phase 1). `heuristicKind`: product → paywall → undetermined, reusing the pure detectors.
   - **Product false-positive guard** (audit P6): `productSignal(url:html:)` classifies a product ONLY with a real structured product/price signal — `ProductPageDetector.hasStructuredProductData` (Tier-1 JSON-LD/OG/microdata) → `.structuredData`, OR a Tier-2 `heuristicProductScore` ≥ `minimumHeuristicScore` that ALSO carries a recovered embedded price or `og:type=product`. A news page with a stray `addToCart`/rating substring (no price, no product OG type) is NOT a product.
   - **Paywall**: `PaywallDetector.htmlDeclaresLocked` (schema `isAccessibleForFree:false` / `article:content_tier`) or `textLooksPaywalled` on the body → `.paywalledArticle(hardHost: false)`.

### `ReaderKit/URLUnwrapper.swift`

`enum URLUnwrapper` — THE app-wide unwrapper, an extensible `[WrapperHandler]` registry over the well-tested pure parsers on `NewsAggregatorUnwrapper` (only the dispatch is new). Types:

- `struct UnwrapResult { url: URL; didUnwrap: Bool; wrapper: WrapperKind? }` — `url` is always the best URL to use (original on a miss), **tracking-param-stripped** (via `ArticleFetcher.canonicalForArchiving`) so dedupe/display/share all see one canonical URL.
- `enum UnwrapResolution { case immediate(URL?); case fetch((URLSession) async -> URL?) }` — offline vs network.
- `struct WrapperHandler { kind; matches(scheme,host); resolve(URL) -> UnwrapResolution }`.
- `enum WrapperKind { facebook, appleNews, googleNews, shortener }`.

Registry `handlers = [.facebook, .googleNews, .appleNews, .shorteners(redirectShortenerHosts)]` (facebook first — `fbrpc://` has no http host). **Adding a wrapper = appending a handler.** Each factory wraps an existing pure parser: `.facebook` → `facebookRedirectTarget` (immediate); `.googleNews` → `googleNewsArticleID` + offline `googleNewsURL` (immediate) else `googleNewsBatchExecute` (fetch); `.appleNews` → `fetchText` + `appleNewsPublisherURL` (fetch); `.shorteners` → `resolveFinalRedirect` (fetch). Entries:

- `unwrap(_:session:) async -> UnwrapResult` — THE entry every surface calls once. Offline inline, network only when a matched handler requires it.
- `unwrapOffline(_:) -> UnwrapResult` (+ `String` convenience) — input-gate fast path: resolves `.immediate` handlers (facebook + google-classic), leaves `.fetch` wrappers for the async choke point. Resolves google-classic offline, which the old FB-only normalize could not.

`NewsAggregatorUnwrapper` (`ReaderKit/NewsAggregatorUnwrapper.swift`) stays as a **thin shim** delegating to `URLUnwrapper` so existing callers + `NewsAggregatorUnwrapperTests` pass: its async `unwrap` maps `UnwrapResult.didUnwrap` back to the historical `URL?` (nil on a miss). `normalizedIncomingURL*` are kept on the legacy verbatim (un-stripped) parser path for now — Stages 3–4 repoint callers to `URLUnwrapper.unwrapOffline` (stripped). The pure parsers are unchanged; three helpers (`googleNewsBatchExecute`, `resolveFinalRedirect`, `fetchText`) were promoted private→internal so the registry reuses them; the dead `unwrapAppleNews`/`unwrapGoogleNews`/`redirectShorteners` were removed.

### `ReaderKit/PlatformRecognizer.swift`

`enum PlatformRecognizer` — the ONE place URL→platform rules live, a declarative `[PlatformRule]` table + pure `recognize(_:) -> RecognizedPlatform?`. Types:

- `struct RecognizedPlatform { platform: ContentPlatform; itemID: String?; var kind: PlatformKind }`.
- `struct PlatformURLParts { host; segments; query; url }` — the parsed pieces handed to a rule.
- `struct PlatformRule { platform; hosts: [String]; recognizes(parts) -> Bool; itemID(parts) -> String? }`. `hosts` match exact-or-subdomain. `recognizes` defaults true (host match is enough); a rule can decline a shared host (for example, Bluesky requires a `/post/`).


`PlatformClassifier` / `PlatformRegistry` / `NonTextualContent` are UNCHANGED in Stage 1 (still back the live pipeline); Stage 3 shims them to the recognizer and deletes the dead per-module `classify`.

### Tests (Stage 1: +30, suite 786 → 816, all green)

- `LunaTests/URLUnwrapperTests.swift` (14) — offline facebook (fbrpc + l.php shim, fb-target rejected) + google-classic; `.fetch` wrappers left offline; tracking-strip; apple.news fetch (+ News+ exclusive unchanged); google-new batchexecute (mock 2 round-trips); shortener cross-host vs same-host; ordinary URL does no network. Uses a `URLProtocol` mock session.
- Fixtures: `LunaTests/Fixtures/classifier-article-stray-addtocart.html`, `classifier-paywall-locked.html` (+ reuses `Fixtures/Products/*`). Fixtures load by file path (`BypassFixtures.html`), not bundled resources.

## Stage 2 — Processing components (DONE)

Stage 2 builds the per-kind **processing** components (each a pure core + bounded I/O,
independently tested), migrates `ArticleResolver` to consume them, and deletes the
duplicated/dead code. Surfaces (`ReadingListIngestor`/`ShareViewController`/
`ArticleIngestDecider`) keep their external decision shape; Stage 3 rewires them onto
the classifier. Suite 816 → 840, all green; Release (generic/iOS) compiles.

### `ReaderKit/ArticleExtraction.swift`

The ONE `HTML → ArticleContent` component + the ONE readable predicate.
- `struct ExtractedArticle { content; sourceHTML }` — replaces the `(ArticleContent, String)` tuple.
- `ArticleExtraction.extract` / `extractFromJSONLD` delegate to the pure `ArticleExtractor`.
- `fetchAndExtract(baseURL:fetch:) -> ExtractedArticle?` — the ONE fetch-then-extract helper (the byte-identical `ArticleResolver.extractedContent` + `BypassRunner.extracted` duplicates were DELETED).
- `static isReadableArticle(_:html:)` = `bodyTextLength >= ArticleContent.readableBodyThreshold && !PaywallDetector.looksPaywalled(content:html:)` — the single HTML-aware predicate that **consolidated the three duplicates**: `ArticleResolver.isReadable` (deleted), `BypassGate` step 3 (now routes here), and the implicit `!looksPaywalled` inside `ArticleContent.hasReadableBody` (now a thin `html: nil` call). The magic `600` in `ArticleExtractor` layer arbitration now references `ArticleContent.readableBodyThreshold`.

### Deterministic fetch (`ArticleFetcher`)

`fetchHTML(from:)` is single-UA (Safari), no fallback chain — reproducible, reader-served bytes. Googlebot is demoted to the explicit `.userAgent(.googlebotDesktop)` bypass strategy; the duplicate Googlebot UA string is gone. The legacy `fetchArchivedHTML`/`fetchArchiveTodayHTML` (the duplicate Wayback hit + near-always-failing archive.ph GET — the NYT/WSJ slowness) were removed from `HTMLFetching` and every conformer; `.waybackRaw` already covers Wayback and archive.today is the WKWebView terminal flow.

### `ReaderKit/ProductMetadataExtractor.swift`

`HTML(classified .product) → ProductMetadata` with a MANDATORY price from ONE source (no detect-then-refetch). Extensible `[ProductPriceRule]` table: `AmazonPriceRule` (buy-box `priceAmount`/`displayPrice`, then buy-box-scoped `.a-offscreen` — never the first list-price span; strict `isAmazonHost`; TLD→currency), `TargetPriceRule`/`WalmartPriceRule` (`__NEXT_DATA__`), generic JSON-LD/OG/microdata/embedded fallback. Currency per-rule (no silent USD). The WebView `render` tier runs ONLY when `render != nil`; `ArticleIngestDecider` defaults it to nil ⇒ **structurally unreachable in extensions** (the "spins forever" fix); the main app injects `WebViewPriceRenderer`. Detection stays in the classifier/`ProductPageDetector`; this only EXTRACTS once classified.

### `ReaderKit/BypassPlan.swift`

ONE typed plan `{ silent: [SilentStrategy], webPreStages: [WebStrategy], allowsArchiveToday: Bool }` from a single factory `BypassPlan.make(for:directHTML:directFailure:silentTierExhausted:)` that splits `BypassStrategySelector`'s ordered list. Both the resolver (silent leg, bounded by `silentChainDeadlineSeconds = 20`) and the archive reader (web leg via `webPreStageURLs`) consume it, so they can't diverge. The resolver runs the silent leg CONCURRENTLY and resolves by plan order rather than completion order (`ArticleResolver.firstQualifying`), so the wall clock is the slowest strategy rather than their sum while the outcome is unchanged — see `claudedocs/readers.md` for the measurements and for why the Wayback index race must use structured task-group children. Trailing-dot is the first silent strategy and `benefitsFromJSRetry == false`, so it's NEVER repeated as a ~9s WebView pre-stage (NYT speed). `BypassURLs` is the ONE strategy→URL mapper (killed the duplicated switch in `BypassRunner` + `webPreStageURLs`). `BypassGate.hardPaywallHosts` stays the host source consulted by the gate; the rule table is the routing source (folding remains a Stage-3 nicety).

### Tests (Stage 2: +24)

`ArticleExtractionTests` (12) — per-site readable + paywalled-stub table (nytimes/washingtonpost/wsj/smh.com.au) through `isReadableArticle`, the HTML-lock false-negative guard, the long-article-quoting-gate-phrase locked policy. `ProductMetadataExtractorTests` (12) — amazon buy-box vs list-price, lookalike-host rejection, target/walmart `__NEXT_DATA__`, generic, no-price→nil, render-unreachable-with-nil. `BypassPlanTests` (12) — NYT trailing-dot first silent + omitted from webPreStages, silent/web split, plan stability across consumers, bounded deadline, `BypassURLs`. (Net +24 after consolidating the moved decider/runner/extraction tests.) Fixtures: `Fixtures/Readable/*` + `Fixtures/Products/{amazon-listprice,target-nextdata,walmart-nextdata}.html`.

### Seams left for Stage 3 (surfaces)

- The classifier (`Classifier.classify`) is still NOT the determination stage — `ArticleIngestDecider` still uses `ProductPageDetector.detect` for the product gate and `BypassGate`/`BypassStrategySelector` for the paywall gate. Stage 3 makes `Classifier` the single determination stage feeding the per-kind processing components built here.
- `ArticleIngestDecider.decide` keeps its decision shape but now takes `metadataExtractor` + `render` (was `priceFetcher`). Stage 3 folds it into the unified `IngestPipeline.process(IngestInput) -> Outcome` with ONE overall timeout + exhaustive per-surface `OutcomePresenter`.
- `BypassGate.hardPaywallHosts` and `BypassRuleTable.rules` are still two parallel host lists (they line up; nothing enforces it). Stage 3 folds them into one source.
- `PriceFetcher`/`PriceFetching` now back only the background refresher; the save-time path uses `ProductMetadataExtractor`.

### Seams left from Stage 1 (still open)

- `URLUnwrapper.unwrapOffline` returns a tracking-stripped URL; `NewsAggregatorUnwrapper.normalizedIncomingURL*` still returns the verbatim target. Stage 3 repoints the 6 sprinkled fbrpc/normalize call-sites + the async `unwrap` choke point to `URLUnwrapper` directly (single shared entry on every surface, closing the `saveNewWithContent` / `handleFriendShare` unwrap gaps), then folds tracking-strip into one `URLCanonicalizer.strip` shared with `canonicalForArchiving`.
- `PlatformRecognizer` is standalone; `PlatformClassifier`/`PlatformRegistry`/`NonTextualContent` still run live. Stage 3 shims them to `recognize`, deletes the dead module `classify`, and gates recognition as the FIRST branch of the processing decision so no surface can bypass it.
- `ProductPageDetector.hasStructuredProductData` was added as the Tier-1-only seam the classifier's tightened product guard uses.

## Stage 3 — Pipeline + surfaces (DONE)

Stage 3 builds the SINGLE shared pipeline and makes every input surface a thin
presenter over it. `Classifier` becomes THE determination stage; `ArticleIngestDecider`
is deleted (folded in); all six surfaces call one entry. Suite 840 → 847; Release
(generic/iOS) compiles.

### `ReaderKit/IngestPipeline.swift`

The ONE shared entry: `IngestPipeline.process(_ input: IngestInput, timeout:…, …) async -> Outcome`.

- **`struct IngestInput`** — `url` + `source: CaptureSource` (paste / manual / appIntent
  / shareSheet / friendShare / email) + optional `documentType` + `prefetchedHTML` +
  `forceArticle`. The source travels with the input so presentation policy is data, not
  per-surface branching.
- **`enum Outcome: Equatable`** — the unified, EXHAUSTIVE result: `.article(ArticleContent, html:)`
  / `.product(ProductInfo, html:)` / `.social(ContentPlatform, itemID:)` /
  `.video(ContentPlatform, itemID:)` / `.audio(ContentPlatform, service:, itemID:)` /
  `.document(type:)` / `.needsArchive(title:)` / `.failed`. Absorbs the old
  `NonTextualContent` (video/social/audio) and the document gate, so the pipeline
  classifies EVERYTHING and no surface re-derives it.
- **Fixed order**: (1) `URLUnwrapper.unwrap` ONCE (offline-first, tracking-stripped —
  every surface unwraps now); (2) `Classifier.classify` (deterministic
  is decided before any fetch and can NEVER reach article extraction on any surface);
  (3) per-kind processing — product detect (→ `.product`, never paywall-bypassed) → article
  resolve via the gated silent `BypassPlan` → `.article` / `.needsArchive` / `.failed`.
- **ONE mandatory overall timeout** (`processTimeout = 28s`) via `withTaskGroup` + a sleeping
  deadline leg wrapping the WHOLE call ⇒ it can NEVER hang. On timeout: `.needsArchive` for a
  hard-paywall host (the archive reader is its only route), else `.failed`. This + the
  Stage-2 "WebView render unreachable in extensions" (`render == nil` default) is the
  action-extension "spinner forever" fix.
- `render` defaults nil (extension-safe); the main app injects `WebViewPriceRenderer`.

### `ReaderKit/OutcomePresenter.swift`

`protocol OutcomePresenter { func present(_ outcome: Outcome, for item: ReadingListItem) async }`
— a thin per-surface presenter whose body is an EXHAUSTIVE switch over `Outcome` (no
`default`, compiler-checked). Every case shows real UI; `.failed`/timeout shows an error,
NEVER an infinite spinner.

### The six surfaces (all thin presenters now)

Every surface builds an `IngestInput`, calls `IngestPipeline.process`, and presents via its
`OutcomePresenter`:
- **main app** `ReadingListIngestor.ingest` → `IngestorOutcomePresenter` (the headless
  store-writing presenter shared by paste/manual/appIntent/friendShare; the foreground list
  opens a saved item via `open(_:presenter:)` on tap). Unwrap is done ONCE up front to
  repoint the store, then the pipeline runs (idempotent re-unwrap). The paste happy-path
  `saveNewWithContent` now routes through the full pipeline when the URL unwraps (so the
  pre-fetched wrapper shell isn't persisted). In-app typed-URL (`addTapped`) uses
  `normalizedTypedURL` — validates the scheme (accepts http(s), bare-prefixes a host-shaped
  entry, rejects `mailto:`/`tel:`/junk) instead of the old blind `https://` prefix.
- **action extension** (`ShareViewController` `com.apple.ui-services`) + **share extension**
  (`com.apple.share-services`) → `ShareOutcomePresenter` (one presenter; `mode == nil` ⇒
  zero-UI share = save+checkmark, `mode != nil` ⇒ action = in-sheet reader / saved-non-textual
  screen). The ad-hoc `NonTextualContent.detect` gating in `routeSavedOrReader` is GONE — the
  pipeline decides. `.failed` no longer shows a misleading "Saved" checkmark (action ext shows
  an error; share ext completes quietly for the app to retry). The action-ext reader
  (`ShareReaderViewController`) takes the already-computed `Outcome` (no re-process).
- **app intents** (`IntentIngestHelper.handleSavePressWithTimeout` → `handleSavePress` →
  `ingest`) and **incoming friend share** (`SocialMessageCenter.process` → `startIngest` →
  `ingest`) inherit the pipeline transitively through the ingestor.

### Deleted / folded

- **`ArticleIngestDecider`** (+ `ArticleIngestDeciderTests`) — folded into `IngestPipeline`.
- **dead per-module `PlatformModule.classify`** (8 bodies + the protocol requirement) — modules
  keep rendering + `metadataFetcher`; `PlatformRecognizer` is the recognition authority.
- **`PlatformClassifier`** collapsed to a thin shim over `PlatformRecognizer` (one rule table,
  no duplicate host/path ladder). `PlatformRegistry.detect` / `NonTextualContent.detect` go
  through it transitively (kept as shims their call sites — PasteboardSuggester, MediaDownload,
  module rendering — still use).
- **`ArticleFetcher.hardPaywallHosts`** (the parallel Set) — `isHardPaywallHost` now derives
  from `BypassRuleTable.rule(for:) != nil` (single host source).
- Remaining `NewsAggregatorUnwrapper.normalizedIncomingURL*` call-sites (share VC, intents)
  repointed to `URLUnwrapper.unwrapOffline`; the pure parsers stay (backing `URLUnwrapper`),
  the async `unwrap`/`normalized*` remain as test-covered shims.

### How the six reported bugs are resolved

- **Action-ext spinner-forever** → the overall `process` timeout + the extension-safe
  `render == nil` (no WebView) + the exhaustive presenter (`.failed`/timeout shows an error).
  shared by all surfaces — a video returns `.video` before any fetch/extraction.
- **Amazon never a tracker** → Stage-2 buy-box price rule + single price source, reached via
  the pipeline's product branch (extension-safe static path).
- **NYT too slow** → Stage-2 `BypassPlan` (trailing-dot first silent, no 9s WebView repeat,
  dropped redundant Wayback/archive.ph) under the bounded pipeline.
- **Facebook fbrpc** → `URLUnwrapper.unwrap` runs ONCE at the single shared entry on every
  surface (offline Facebook handler first), closing the old `saveNewWithContent` /
  friend-share unwrap gaps.
- **"3 pastes, 3 results"** → one deterministic price source + classify-before-fetch + the
  single pipeline decision (no per-surface re-derivation, no WebView race in the decision).

### Tests (Stage 3)

- `IngestPipelineTests` (12) — classification through the pipeline (article/product/paywalled/
  fail), platform/video/social/audio recognized BEFORE extraction (never `.article`), document
  flag wins, PARITY (same `IngestInput` across all `CaptureSource`s → same `Outcome`), and the
  overall-timeout never-hangs (a `NeverReturningFetcher` resolves to `.failed` within the
  deadline; a hard-paywall host → `.needsArchive`).
- `OutcomePresenterTests` (5) — exhaustive `Outcome`→intent mapping, video/social/audio never
  route to the reader, `.failed` never "Saved", and typed-URL scheme validation.

## Stage 4 — Fixtures, parity, and the final cleanup (DONE)

Stage 4 pins the pipeline with a named-site fixture/parity matrix, removes the last
Stage-1/3 shims, and folds the remaining duplicate sources into one each. Suite is
green; Release (generic/iOS) compiles.

### Named-site fixtures + the parity table (`LunaTests/NamedSiteParityTests.swift`)

A single data-driven table drives the REAL `IngestPipeline.process` (so
`URLUnwrapper` → `Classifier` → per-kind processing all run) with a mock `HTMLFetching`
and a nil render tier — no live network. Each row is `fixture/URL → Expected Outcome`,
asserted identically across EVERY `CaptureSource` (the headline parity guarantee):

- **Shops → `.product` + price/currency:** amazon.com.au (buy-box `priceAmount`,
  AUD from the TLD), amazon.com (buy-box `$42.50` wins over the `$59.99` strikethrough
  list price, USD), target (`current_retail` 24.99 USD), walmart (`currentPrice.price`
  17.88 USD). Reuses the Stage-2 `Fixtures/Products/*`.
- **News → `.article` (readable) or `.needsArchive` (hard-paywall stub):** nytimes,
  washingtonpost, wsj, smh.com.au — both variants each. Reuses `Fixtures/Readable/*`.
  x/instagram/reddit/bluesky → `.social`; spotify/apple → `.audio`. URL-only, decided
  before any fetch. A second test attaches article-shaped HTML to every platform URL
  and asserts none become `.article`.

### Last shims removed

- **`PlatformClassifier` (+ `PlatformClassification` + `PlatformClassifierTests`)** —
  DELETED. Every caller (`PlatformRegistry.detect`, `PasteboardSuggester`,
  `SocialMediaResolver`, `NonTextualContent.detect`, `BypassGate`, `MediaDownload`,
  `MediaAutoDownloader`) now calls `PlatformRecognizer.recognize` directly. Host-variant
  coverage lives in `PlatformRecognizerTests` (the deleted tests were a strict subset).
- **`NewsAggregatorUnwrapper.unwrap` (async) / `normalizedIncomingURL` /
  `normalizedIncomingURLString`** — DELETED (no production callers left; tests covered by
  `URLUnwrapperTests`). The enum keeps ONLY the pure wrapper parsers that `URLUnwrapper`'s
  registry and `ShareViewController.facebookRedirectTarget` wrap.
- **Kept (genuine unique use, documented):** `NonTextualContent` is the share extension's
  longer a recognition shim. `PlatformRegistry` stays as the module registry (`module(for:)`
  drives rendering); its `detect` is a thin convenience over the recognizer.

### Single-source consolidations

- **`ReaderKit/URLCanonicalizer.strip(_:)`** — the ONE tracking-param list (utm_*, fbclid,
  …) + fragment drop. Both `URLUnwrapper` (unwrap leg) and
  `ArticleFetcher.canonicalForArchiving` (archive leg, which still unwraps an archive
  snapshot first, then strips) canonicalize through it — one list, no drift.
- **Hard-paywall determination = one source.** `Classifier.isHardPaywallHost` derives from
  `hardPaywallNewsSites` (the SAME table that returns `.paywalledArticle(hardHost: true)`),
  and `ArticleFetcher.isHardPaywallHost` now delegates to it. Previously the routing read
  `BypassRuleTable.rule(for:) != nil` (22 hosts) while classification read
  `hardPaywallNewsSites` (24 hosts) — so smh.com.au/theage.com.au/afr.com classified as
  hard-paywall but failed instead of parking for archive on timeout/unreadable.
  `BypassRuleTable` now ONLY refines per-host strategy ordering (generic plan, ending in
  `.archiveToday`, covers a hard-paywall host with no bespoke rule).
- **Product determination trusts the classifier.** When the classifier deterministically
  returns `.product(.knownShopHost)`, `IngestPipeline.processWeb` goes straight to
  `ProductMetadataExtractor.extract` — it no longer re-gates on `ProductPageDetector.detect`
  (which lacks the host-specific Target `current_retail` / Walmart `currentPrice` price
  shapes the per-host `ProductPriceRule` knows). The heuristic detector still confirms
  products on `.undetermined`/article-classified pages.
- **Dedup authority.** `ReadingListStore.addIfAbsent` is the single URL-existence dedup
  ("drop a duplicate incoming item without re-attributing"); `SocialMessageCenter`'s
  friend-share cases route through it instead of repeating `item(forURLString:) == nil`.
  The ingestor's separate guard (`priceTracker(containingStoreURL:)`) is an ORTHOGONAL
  condition (same URL inside a DIFFERENT item's tracker), kept and documented.

### Still green / extension-safe

- `ReaderKit` stays extension-safe: `URLCanonicalizer`, `Classifier.isHardPaywallHost`, and
  the pipeline change add no UIKit/CloudKit/main-app deps. Release (generic/iOS) compiles.

## Stage 5 — Surface unification (DONE)

Stage 4 made the PIPELINE source-invariant; Stage 5 makes every INPUT SURFACE feed and
present it identically (the surfaces still diverged in how they fed/presented the one
pipeline). Suite → 852, all green; Release (all extension targets) compiles.

### The extension surfaces become a testable shared driver

- **`ShareKit/ExtensionHost.swift`** — `protocol ExtensionHost` (extension-safe): the ONLY
  parts of the real `NSExtensionContext`/UIKit harness the ingest+present flow touches —
  `isActionExtension` / `readerMode` (the single per-surface data), `presentModally`,
  `confirmSavedThenComplete`, `autoDownloadThenComplete`, `failOrComplete`.
- **`ShareKit/ShareSurfaceDriver.swift`** — the HOST-AGNOSTIC ingest+present flow extracted
  out of `ShareViewController`/`ShareReaderViewController`. `ingestAndPresent(originalURL:)`
  runs the ONE `IngestPipeline` (injectable `process` for tests), repoints on unwrap, then
  `present(_:url:)` is an EXHAUSTIVE `Outcome` switch that PERSISTS the classified metadata
  for every kind and presents real UI via the host. `ShareViewController` is now a thin
  `ExtensionHost` adapter (attachment loading + live UIKit chrome only); the old divergent
  `ShareOutcomePresenter` + `presentReader`/`presentSavedNonTextual`/`presentArchiveReaderForCaptcha`
  are DELETED. `FakeExtensionHost` (in `ShareSurfaceDriverTests`) drives the whole flow
  with no `NSExtensionContext`.

### The four surface bugs this resolves (divergence collapsed, not special-cased)

- **Bug 2 — Facebook link auto-detected on the pasteboard FAILS but "+" succeeds.**
  `PasteboardSuggester.evaluate` rejected any non-http scheme before evaluating, so an
  `fbrpc://…&target_url=http…` never became a suggestion; the "+" path
  (`addTapped`) unwrapped offline first. FIX: `evaluate` now runs
  `URLUnwrapper.unwrapOffline` BEFORE the http-scheme gate, identical to `addTapped` — both
  build the same normalized URL and feed the same pipeline.
- **Bug 3 — action extension doesn't show the price-tracking UI for a `.product`.** Both
  extensions used to save the tracker silently + a checkmark. FIX: the driver's `.product`
  case PRESENTS the SAME `PriceTrackingViewController` the main app shows, hosted in the
  extension via `PriceTrackingHost.extension` (Done chrome). The editor + its small deps
  (`AlertThresholdSlider`, `PriceTrackingManager`, `InAppBrowser`) MOVED from `Luna/` into
  `ShareKit/` (compiled into all targets); the one main-app-only call ("Read instead" →
  `ReadingListIngestor.saveAsArticle`) is now an injected closure — a static
  `PriceTrackingViewController.defaultSaveAsArticle` the app installs at launch, a re-append
  in the extension.
  extension routed `.video` straight to auto-download and persisted only a bare URL (no
  platform/videoID), so the saved item was incomplete and the main app had to re-classify.
  `savePlatformMetadata` — an extension save is now shaped IDENTICALLY to a main-app save.
- **`.needsArchive` presentation unified.** The action extension used to wrap the
  archive-CAPTCHA reader in `ShareReaderViewController`; the main app showed
  `ArchiveWebReaderViewController` directly. The driver now opens
  `ArchiveWebReaderViewController` directly on EVERY surface (action ext swaps to the in-sheet
  native reader on extract). `SurfaceParityTests` caught this divergence and forced the
  collapse.

### Cross-surface parity tests (`LunaTests/SurfaceParityTests.swift`)

Drives the SAME nine example links — amazon, nytimes, wsj, an fbrpc Facebook link, an
both EXTENSION surfaces (via the real `ShareSurfaceDriver` + `FakeExtensionHost`), with a
mock fetcher + the Stage-1–4 fixtures, a nil render tier, and an offline-failing
`URLSession` for the network-unwrap legs (NO live network). Asserts: (1) identical `Outcome`
across `.manual`/`.shareSheet`/`.appIntent`; (2) identical PRESENTATION INTENT across the
main-app presenter and the extension driver; (3) the extension persists the classified item
any surface diverges again. (+`ShareSurfaceDriverTests` unit-drives each `Outcome` through
the fake host.)

## URL Rescue (LLM fallback)

When Stage 3 returns `.failed` (or a product page yields no price / a media link
resolves no assets), an optional LLM fallback re-runs the URL — see
`claudedocs/url-rescue.md`. Key contract for this pipeline: the rescue engine
(`LunaURLRescue`) re-enters `IngestPipeline.processResolved` **at most once, via an
injected raw-pipeline closure**, so a rescue can never trigger a second rescue.
`ReadingListIngestor.rescueTrigger` fires on a genuine `.failed` outcome;
`applyResult(...)` is the shared persistence tail both a first pass and a rescued
result flow through, so rescued items obey the same per-app surface gate (`claudedocs/surface-support.md`).

## Per-kind processing split (compile-time surfaces)

The pipeline's per-kind PROCESSING is no longer compiled into every app.
`LunaIngest` keeps unwrap → classify (incl. the single shared HTML fetch and
product DETECTION) plus the `IngestKindProcessors` registry; the processing
implementations live in link-optional modules:

- `LunaArticleIngest.ArticleIngestProcessor` — `ArticleResolver` + silent
  `BypassPlan` leg (Reader + central Luna only).
- `LunaPriceIngest.ProductIngestProcessor` — `ProductMetadataExtractor` + the
  per-host `ProductPriceRule` table (Price Tracker + central Luna only). The
  Amazon storefront host/currency registry stayed in `LunaURLClassification`
  (`AmazonStorefronts`) because the host list is classification data.

A classified kind with no registered processor returns
`Outcome.unsupported(owner:)`, dropped by every surface via `SurfaceSupport`
(see `claudedocs/surface-support.md`, incl. the per-target composition files
that do the registering — `#if canImport` is NOT target-reliable here).

## Pages that aren't content at all (`ListingPage`)

The pipeline used to have no way to say **"this URL is not a saveable thing"**.
`Classifier` names a KIND from the URL table and, failing that, hands everything
left to article extraction — so a Google search page, a publisher front page, and
a site homepage were all article candidates. Two consequences, both reported:

- **Every titled page parked for archive.today.** `ArticleResolver.resolution`
  returned `.paywalled(title:)` for any unreadable page carrying a non-placeholder
  `<title>` — which every page has — and `ArticleIngestProcessor` mapped
  `.paywalled` to `.needsArchive` with no paywall check. So saving `google.com`
  opened the archive.today CAPTCHA reader, and the Safari recents tray
  (`RecentURLMatcher`, which reads `.needsArchive` as an article preview) filled
  with pages Safari itself had declined to offer a pill for.
- **An index that extracted past 1200 characters became a real `.article`.**

`.paywalled` now requires `BypassPlan.allowsArchiveToday` — i.e. `BypassGate`
found actual paywall evidence (a declared lock, a gate marker, a hard-paywall
host, an archive URL, or a fetch that never returned). A `<title>` is not
evidence.

`LunaHTMLClassification/ListingPage.swift` is the **Swift twin of the Safari
extension's index veto** (`content.js`'s `looksLikeNonArticleIndex`, which is why
these pages never got a pill). Same signals, deliberately: `declaresArticle`
(og:type / JSON-LD Article) exempts a page from every structural test on every
host; otherwise 4+ sibling `<article>`s or whole-page link density > 0.5, or a
declared listing type (`CollectionPage`/`SearchResultsPage`/`ItemList`/`WebSite`,
`landing_homepage`) paired with ≥5 substantial non-chrome destination links. It
adds one thing the extension has no need for — a **URL-only search-results
shape** (a leading `search`/`results` path segment, or a search term on a bare
root), so a directly shared search page fails before any network round-trip.
`SafariIndexVetoParityTests` runs one fixture set through both implementations
(the real `content.js` in a bare `WKWebView`) and fails if they disagree.

**Where it's applied matters more than the signals**, because a false positive
silently drops a real save:

| Site | Check | Why there |
| --- | --- | --- |
| `IngestPipeline.processWeb`, before the fetch | search-results URL, plus `urlIsMultiProductListing` for a page the shop table already claimed | Fails fast, no round-trip. The commerce half is scoped to a `.product` classification because `.product(.knownShopHost)` SKIPS `ProductPageDetector.detect`, so `amazon.com/s?k=…` used to reach price extraction, find no price, and fall through to the article path. Scoping also keeps `medium.com/s/<publication>` out of it. |
| `IngestPipeline.processWeb`, before article resolution | the full `isNonContentPage` | The HTML is already in hand and the outcome is a save, not an unlock. |
| `BypassGate`, step 2b | the URL half ONLY | The HTML shapes describe a metered article cut back to headline links just as well as a real index; consulting them here would disable the unlock the Reader exists for. Nothing is lost at the archive reader's own entry point, which builds its plan with `directHTML: nil`. |

**A page showing paywall evidence is exempt** from the HTML half
(`PaywallDetector.htmlDeclaresLocked`, a gate marker, or a hard-paywall host).
That is the whole difference between "we can't read this yet" and "there is
nothing here to read". Likewise a page that never came back is never vetoed — a
bot-blocked article keeps its browser/archive tier.

The result is `Outcome.failed(.notContent)` — see `claudedocs/failed-saves.md`.

## Publisher subscribe interstitials (`WrapperHandler.interstitial`)

A paywalled article on several publishers does not serve a paywall stub at its own
URL — it **redirects to the publisher's own subscribe page**, carrying the real URL
in a query param:

```
https://www.theaustralian.com.au/subscribe/news/1/?sourceCode=TAWEB_MRE170_a_TWT
    &dest=https://www.theaustralian.com.au/wealth/…/news-story/<id>
    &memtype=anonymous&mode=premium&v21=GROUPA-Segment-1-NOSCORE
```

That interstitial is therefore what Safari's address bar shows and what a share, a
copy, or the Safari extension's `location.href` hands us — News Corp Australia
(`theaustralian.com.au`, `heraldsun.com.au`, `dailytelegraph.com.au`,
`couriermail.com.au`, `news.com.au`, …) is the live case, and the same sites serve a
second shape, the `/remote/check_cookie.html?url=…` bounce. Left wrapped it poisons
everything downstream: extraction reads the subscription pitch as the body, dedupe
keys every locked article on the same interstitial path, and the archive reader asks
archive.today for a URL it never snapshots (the article itself is snapshotted fine).

`NewsAggregatorUnwrapper.interstitialTarget` resolves it offline (`.immediate`), and
it is the one handler that **cannot key on host** — the interstitial lives on the
publisher's own host. So the gating moved into the parser:

- the **path** must prove it: a whole lowercased segment in
  `subscribe`/`subscription(s)`/`paywall`/`signin`/`login`/`register`/`checkout`, or
  the `check_cookie.html` leaf. Whole segments only, so an article whose *slug*
  contains "subscribe" is untouched;
- the target must be an **absolute http(s) URL on the SAME site** (`www.` ↔ bare and
  login-subdomain ↔ site both count). That same-site rule is what stops this from
  becoming a general open-redirect follower: an attacker-supplied `?dest=` can only
  ever point back into the publisher's own domain;
- a target that is itself an interstitial returns nil, so a self-referential `dest=`
  can't loop.

**`.interstitial` MUST stay LAST in `URLUnwrapper.handlers`.** Its matcher accepts
every http(s) URL, and the dispatch loop `break`s after the first matcher that fires
— anywhere earlier it would shadow every host-keyed handler below it
(`testInterstitialIsLastAndShadowsNoOtherHandler` guards this).

### The captured HTML must not follow an unwrapped URL

Two surfaces snapshot the page the user was looking at: the Safari "Read in Luna"
hand-off (`SafariContentStore`, consumed in `SceneDelegate.openReader`) and the
action extension's `ArticleText` snapshot (`ShareViewController`). When that URL
unwraps to a *different* page the capture is the wrapper's bytes — the subscription
pitch — and `trustsPrefetchedHTML` would have stored the pitch as the article body.
Both now drop the capture when `URLUnwrapper.unwrapsToDifferentPage` is true
(SceneDelegate still CONSUMES it, so a stale capture can't leak onto a later open).
Tracking-param stripping alone is NOT a different page, so a `?utm_…` article keeps
its capture. Covered by `URLUnwrapperTests` (+10).

### Unwrapping isn't enough — the FETCH lands on the interstitial too

Unwrapping only fixes the URL a surface hands us. Fetching the *article* URL on those
sites redirects into the same interstitial, so the bytes are the subscription pitch
either way — and that pitch reads as a perfectly good article: ~2.8k characters, no
gate marker in `PaywallDetector`'s list ("Unlock this story and more with your
subscription"), no `isAccessibleForFree`. It cleared the readable threshold,
`BypassGate` blocked with `.readableArticle`, and the pitch became the saved body with
no bypass attempted at all (the reported `theaustralian.com.au` regression).

So the fetch layer checks it: `ArticleFetcher` compares the response's final URL
against the requested one and throws `FetchError.subscribeRedirect(landedOn:)` when
the site substituted its own interstitial (`NewsAggregatorUnwrapper.isInterstitialURL`
— the same path test, now public). Pure policy in
`ArticleFetcher.subscribeRedirectLanding(requested:finalURL:)`, so it's unit-tested
without the network. It fires only on a genuine substitution: a canonicalizing
redirect between articles passes, and asking FOR a subscribe page (a deliberate save,
an archive replay) still fetches. Every `HTMLFetching` caller inherits it, so a bypass
strategy that lands on the wall now fails instead of "succeeding" with pitch copy, and
product detection never runs over subscription prices. `SaveFailureReason
.subscribeRedirect` gives the failed card an honest line; a hard-paywall host or a
host with browser recovery still parks for the archive/browser tier instead of
failing. The way IN on those sites is the `?amp` rendering — see the `.ampQuery`
strategy in `claudedocs/readers.md`.
