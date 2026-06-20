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
.video(ContentPlatform, itemID: String?)   // youtube / tiktok / facebook video
.audio(ContentPlatform, MusicProvider?, itemID: String?)  // music / podcast
.document(type: String)                     // save-time flag, always wins
.undetermined                               // table miss + heuristics inconclusive
```

`enum ProductSignal: Equatable` = `.knownShopHost` (trusted table row) | `.structuredData` (JSON-LD/OG/microdata price) | `.heuristicScore(Int)` (fuzzy retail signals).

### `ReaderKit/KnownSite.swift`

`struct KnownSite` — one row of the deterministic, EXTENSIBLE site table. `hosts: [String]` (host-suffix match — covers `www.` + subdomains), optional `path: (([String]) -> Bool)?` predicate over path segments, and `kind: (URL) -> ContentKind` (closure so a row can read an itemID). `matches(_ url:)` = host-suffix hit AND (if present) path predicate. **Adding a site = appending one row.**

### `ReaderKit/Classifier.swift`

`enum Classifier` — THE classifier. `classify(url:html:documentType:) -> ContentKind`, two phases in strict order:

1. **Deterministic `[KnownSite]` table FIRST** (URL-only). `documentType` (save-time flag) wins outright. Then `knownSites = platformSites + shopSites + newsSites`:
   - **platformSites** — a single row gated on `platformHosts` (the union of every `PlatformRule.hosts`, so adding a platform rule extends the gate automatically); the closure defers to `PlatformRecognizer.recognize` and maps the `RecognizedPlatform.kind` to `.video`/`.social`/`.audio`. **Checked FIRST** ⇒ no surface can text-extract a video/post (kills the YouTube-text-extraction bug class). A platform host with no recognizable item (e.g. a YouTube channel page) returns `.undetermined`, never `.video`.
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

- `struct RecognizedPlatform { platform: ContentPlatform; itemID: String?; service: MusicProvider?; var kind: PlatformKind }`.
- `struct PlatformURLParts { host; segments; query; url }` — the parsed pieces handed to a rule.
- `struct PlatformRule { platform; service; hosts: [String]; recognizes(parts) -> Bool; itemID(parts) -> String? }`. `hosts` match exact-or-subdomain. `recognizes` defaults true (host match is enough); a rule can decline a shared host (Spotify splits music vs podcast by path; Bluesky requires a `/post/`).

`rules = [youTube, x, bluesky, reddit, tiktok, instagram, facebook, spotifyMusic, spotifyPodcast, appleMusic, applePodcasts]`; first rule that matches a host AND `recognizes` wins. **Adding a platform = appending one rule.** YouTube reuses `YouTubeURL.videoID` (and declines a host with no extractable id). The rules mirror the live `PlatformClassifier`'s host/path logic exactly. `ContentPlatform.kind: PlatformKind` (`.video`/`.social`/`.audio`) added (additive) for routing.

`PlatformClassifier` / `PlatformRegistry` / `NonTextualContent` are UNCHANGED in Stage 1 (still back the live pipeline); Stage 3 shims them to the recognizer and deletes the dead per-module `classify`.

### Tests (Stage 1: +30, suite 786 → 816, all green)

- `ClipTests/ClassifierTests.swift` (23) — KnownSite table over named shops/news/social (positives + negatives), platform-first ordering, YouTube channel page ≠ video, URL-only miss → undetermined, heuristic structured/OG product, the stray-`addToCart` article false-positive guard, paywall-locked HTML, no-signal article → undetermined, document-flag-wins, determinism/parity.
- `ClipTests/URLUnwrapperTests.swift` (14) — offline facebook (fbrpc + l.php shim, fb-target rejected) + google-classic; `.fetch` wrappers left offline; tracking-strip; apple.news fetch (+ News+ exclusive unchanged); google-new batchexecute (mock 2 round-trips); shortener cross-host vs same-host; ordinary URL does no network. Uses a `URLProtocol` mock session.
- `ClipTests/PlatformRecognizerTests.swift` (13) — data-driven sweep over real example URLs (youtube/x/instagram/tiktok/facebook/reddit/bluesky/spotify/apple) with expected platform + itemID + kind, plus negatives, plus the derived `platformHosts` gate.
- Fixtures: `ClipTests/Fixtures/classifier-article-stray-addtocart.html`, `classifier-paywall-locked.html` (+ reuses `Fixtures/Products/*`). Fixtures load by file path (`BypassFixtures.html`), not bundled resources.

### Seams left for Stage 2/3

- `URLUnwrapper.unwrapOffline` returns a tracking-stripped URL; `NewsAggregatorUnwrapper.normalizedIncomingURL*` still returns the verbatim target. Stage 3 repoints the 6 sprinkled fbrpc/normalize call-sites + the async `unwrap` choke point to `URLUnwrapper` directly (single shared entry on every surface, closing the `saveNewWithContent` / `handleFriendShare` unwrap gaps), then folds tracking-strip into one `URLCanonicalizer.strip` shared with `canonicalForArchiving`.
- `Classifier` is not yet wired into `ReadingListIngestor` / `ArticleIngestDecider`. Stage 3 makes the classifier the determination stage (table first, HTML heuristics only when undetermined), strips fetch/price/bypass out of `ArticleIngestDecider`, and folds the four scattered host sets (`hardPaywallHosts`, `archiveTodayHosts`, `youtubeHosts`, inlined platform `matches`) into `knownSites`.
- `PlatformRecognizer` is standalone; `PlatformClassifier`/`PlatformRegistry`/`NonTextualContent` still run live. Stage 3 shims them to `recognize`, deletes the dead module `classify`, and gates recognition as the FIRST branch of the processing decision so no surface can bypass it.
- `ProductPageDetector.hasStructuredProductData` was added as the Tier-1-only seam the classifier's tightened product guard uses.
