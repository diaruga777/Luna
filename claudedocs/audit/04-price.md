# Audit 04 — Price-Monitoring Metadata

Audit of the shop/product price-extraction component: once a URL is classified as a
product page, extract name + price + currency (+ image/id), support multi-store
tracking and background refresh. Focus: composability, surface parity, determinism,
and the reported "3 pastes, 3 results" / "Amazon never saves" / "spins forever" bugs.

Files audited (all paths absolute):
- `ReaderKit/ProductPageDetector.swift` — detection + static/embedded/JSON-LD/OG/microdata/Amazon price extraction
- `ReaderKit/PriceFetcher.swift` — static → embedded → WKWebView render, timeout
- `ReaderKit/ProductMatcher.swift` — same-product matching
- `ReaderKit/PriceRefresher.swift` — background re-fetch loop
- `ReaderKit/PriceTracker.swift` — the model
- `ReaderKit/ArticleIngestDecider.swift` — the shared save-time composition
- `Luna/ReadingList/ReadingListIngestor.swift`, `ShareKit/ShareViewController.swift`, `Luna/ReadingList/PriceTrackingManager.swift`, `Luna/ReadingList/PriceRefreshCoordinator.swift` — call sites
- `LunaTests/Fixtures/Products/*`, `LunaTests/*Tests.swift`

---

## 1. Current-state map

### Detection (`ProductPageDetector.detect`)
Pure, no I/O. `detect(urlString:html:)` → `detect(document:baseURL:)` returns a
`ProductCandidate?` (name, optional `staticPrice`, imageURL, brand, productID). Two
tiers, in trust order:

- **Tier 1 — structured price (single hit ⇒ product, always carries `staticPrice`):**
  1. JSON-LD `Product`/`Offer` — `candidateFromJSONLD`, recursing `@graph`/arrays/nested
     offers, AggregateOffer (`lowPrice`), `priceSpecification`. Product-node and price-node
     traversal is **sorted-key** to be hash-seed-stable.
  2. OG product meta (`product:price:amount` / `og:price:amount` + currency).
  3. schema.org microdata (`itemprop=price` + `priceCurrency`).
  4. bare `product:price`.
- **Tier 2 — heuristic (`heuristicProductScore`), needs ≥2 of:** `og:type=product`;
  add-to-cart affordance (button/`value` text OR raw-HTML `addToCart` substring);
  rating signal (`aggregateRating`/`ratingValue`/"out of 5"/"Star Rating");
  retail URL shape (`_p\d{4,}`, `/dp/`, `/gp/product/`, `/p/\d{4,}`, `/products/`, `/itm/`);
  a price recovered from embedded app-state JSON. A Tier-2 candidate's `staticPrice` is
  the embedded-JSON price (or nil).

### Price tiers (`PriceFetcher.fetchPrice` → `resolvePrice`)
A separate price resolver, distinct from detection's `staticPrice`. Order:
1. **Static markup** — `detector.staticPrice(urlString:html:)`. This re-parses the
   HTML (`SwiftSoup.parse`) and tries, in order: meta/microdata → JSON-LD → embedded
   JSON (`__NEXT_DATA__`, `script[type=application/json]`, balanced-brace `window.__…`
   literal) → **`amazonStaticPrice`** (`"priceAmount":`, `"displayPrice":`,
   `.a-offscreen`, currency from declared code else Amazon TLD map else USD).
   Uses `prefetchedHTML` if given, else `fetcher.fetchHTML`.
2. **WKWebView render** (`WebViewPriceRenderer.renderedHTML`) — last resort when static
   finds nothing: off-screen `WKWebView`, mobile-Safari UA, non-persistent store, JS on.
   **Deterministic poll** (0.5 s cadence) re-scrapes `outerHTML` and returns the first
   render where `staticPrice != nil`; one hard deadline (`renderTimeoutSeconds = 20`)
   bounds navigation + poll together.
3. **Overall timeout** — `fetchPrice` races `resolvePrice` against a
   `overallTimeoutSeconds = 30` sleep in a `withTaskGroup`; first wins, rest cancelled.
   So worst case is ~30 s, returning nil on timeout (→ falls back to article).

### Save-time composition (`ArticleIngestDecider.decide`)
The single shared routine for all surfaces. Order:
1. Fetch direct HTML (or reuse `prefetchedHTML`).
2. `productDetector.detect(...)` → candidate. **Then** `priceFetcher.fetchPrice(...)`
   on the same URL. If both succeed ⇒ `.priceTracker(ProductInfo(candidate, price))`.
3. Else `ArticleResolver.resolve` → `.article` / `.needsArchive` / `.failed`.

Call sites (verified):
- `ReadingListIngestor.ingest` (`Luna/ReadingList/ReadingListIngestor.swift:151`) — main app; passes its own `priceFetcher`. **All Shortcuts/App Intents funnel here** (`SaveLinkIntent`/`SaveFromAppIntent`/`LunaSafariPageIntent` → `ReadingListIngestor.handleSavePress`), so they inherit the main-app wiring.
- `ShareViewController` inline ingest (`ShareKit/ShareViewController.swift:459`) — share extension; **all-default `decide(url:fetcher:)`**, so default `PriceFetcher()`.
- `ShareReaderViewController.ingestAndPresent` (`ShareKit/ShareReaderViewController.swift:82`) — action/reader extension; **all-default `decide(url:)`**, so default `PriceFetcher()`.
- `SocialMessageCenter` (`Luna/Social/SocialMessageCenter.swift:367`) — incoming friend-shared tracker; reconstructs from `PriceTrackerShare`, no detection/fetch (not a save-time extraction path).

HTML is fetched once per save and threaded through as `prefetchedHTML`, so the *static* paths don't double-fetch — but `detect()` and `fetchPrice()` still re-parse it independently (see P1), and the WebView tier re-fetches over the network.

### Matching (`ProductMatcher.bestMatch`)
Pure, order-stable. (1) normalized `productID` equality (lowest UUID wins on ties);
(2) fuzzy: brand-compatible + token-Jaccard name similarity ≥ `0.6`, highest score,
ties broken by lowest UUID. Used by `ReadingListIngestor.ingestProductTracker` to merge
a new save into an existing tracker vs create a new one.

### Refresh (`PriceRefresher.refreshAll`)
Stalest-first (oldest `lastRefreshed`), persists each tracker as soon as it finishes
(resumable), re-fetches every store via the same `PriceFetching`. Failed fetch stamps
the attempt time (keeps it from monopolizing the queue) and leaves the price unchanged.
Computes `newlyAlerting` for one-shot notifications. Clock + fetcher injected.

### Model (`PriceTracker`)
`stores: [PriceTrackerStore]` (≥1 invariant, repaired in `init(from:)`), `initialPrice`
baseline, `alertThresholdFraction` (default 0.10, clamped 0.01–0.95), derived
`currentBestPrice`/`displayCurrency`/`discountFraction`/`isAlerting`/`hasUnviewedAlert`.
Price is **mandatory** — `init` requires a `Decimal`; there is no pending/unknown state.
`PriceTrackerShare` round-trips price as a string for friend-sharing.

---

## 2. Problems

### P1 — Detection and price-extraction are duplicated and run twice (the core tangle)
In `ArticleIngestDecider.decide` (lines 77–80):
```swift
let candidate = productDetector.detect(urlString:html:)      // parses HTML, computes candidate.staticPrice
let price = await priceFetcher.fetchPrice(prefetchedHTML: html)  // re-parses the SAME html via staticPrice()
```
`candidate.staticPrice` is **computed and then thrown away**; `fetchPrice` re-derives the
price from scratch. For a Tier-1 page that means `SwiftSoup.parse` + the full
JSON-LD/OG/microdata walk runs **twice** on the same bytes. This is wasted work on the
hot path and, worse, it means **detection's notion of the price and the fetcher's notion
of the price can disagree** (they use overlapping-but-not-identical code paths:
detection's JSON-LD walk vs `staticPrice`'s order meta→JSON-LD→embedded→amazon). Two
sources of truth for "the price of this page" is the structural root of the
"sometimes saves, sometimes not" class of bug.

### P2 — Amazon end-to-end can still fail even though the unit fixture passes
`testAmazonDPStaticPriceIsAUDViaTLD` passes because it feeds the trimmed fixture
directly. End-to-end, the price comes from `priceFetcher.fetchPrice(prefetchedHTML: html)`
where `html` is whatever `ArticleFetcher` (a plain HTTP GET, no JS, default UA) returned
for the live page. The real risks:
- **`amazonStaticPrice` only fires inside `staticPrice`, never inside `detect`.** A live
  Amazon page with no JSON-LD/OG/microdata relies on Tier-2 heuristics to be *detected*
  (`/dp/` + add-to-cart) AND on `amazonStaticPrice` to be *priced*. If the server-rendered
  HTML the bot receives omits `priceAmount`/`displayPrice`/`.a-offscreen` (Amazon serves
  different markup to non-browser UAs, robot-checks, or interstitials), `detect` may
  succeed but `fetchPrice` returns nil for the static path → it tries the **WebView**…
- …and the WebView is where "Amazon never saves / spins forever" lives (see P3).
- **`isAmazonHost` is loose:** `host.hasPrefix("amazon.")` matches `amazon.scam.com`,
  and `.contains(".amazon.")` matches `cdn.amazon.akamai.net`-style hosts — wrong TLD
  currency, or applying Amazon rules to a non-storefront.
- The `.a-offscreen` regex `a-offscreen"\s*>\s*([^<]*[0-9][^<]*)<` can match the FIRST
  offscreen span on the page, which on real Amazon is often a *strikethrough list price*
  or an unrelated widget, not the buy-box price — silently tracking the wrong number.

### P3 — WKWebView render runs inside BOTH extensions (unsafe + slow)
`ShareViewController.swift:459` (share extension) **and** `ShareReaderViewController.swift:82`
(action/reader extension) call `decide(...)` with **no `priceFetcher`**, so both get the
default `PriceFetcher()`, whose `renderHTML` defaults to `WebViewPriceRenderer.renderedHTML`.
So when a product page's price isn't in the static markup, **both extensions spin up a full
off-screen `WKWebView`**. Problems:
- App extensions have a tight memory budget (~tens of MB) and are jetsammed aggressively;
  a `WKWebView` rendering a 1 MB+ retail SPA is exactly the kind of thing that gets the
  extension killed mid-save → "Amazon never saves."
- Even when it survives, the bound is `renderTimeoutSeconds 20` then the overall `30 s`;
  a save in a share sheet that takes up to 30 s before falling back reads as
  "spins forever."
- The "main-app-only vs extension" distinction the docs imply is **not enforced** — the
  default wiring is identical, so the riskiest tier runs in the riskiest host.

### P4 — Determinism gaps remain despite the sorted-traversal work
The pure layer is genuinely deterministic (sorted JSON traversal, lowest-UUID
tie-breaks, deterministic WebView poll — all well-tested). But end-to-end determinism
across "3 pastes" still has leaks:
- **WebView render is only as deterministic as the live page.** The poll removes the
  JS-vs-sleep race, but if the price hydrates *after* the 20 s deadline on a slow network
  it returns nil; faster network → price. Same URL, different result. This is the residual
  "3 pastes, 3 results."
- **`detect` succeeds-with-no-price vs `fetchPrice` finds-a-price is non-atomic.** Because
  the price comes from a *second* network/parse path (P1), transient differences between
  the two HTML fetches (`decide` fetches once and passes it as `prefetchedHTML`, so this
  is mostly mitigated for the main path — but the WebView re-fetches independently) can
  flip the outcome.
- **`heuristicProductScore` calls `document.html()`** (serializes the entire DOM to a
  String) twice (add-to-cart fallback + rating fallback), then substring-searches it.
  Functionally deterministic but O(page size) and run on the ingest hot path.

### P5 — Complexity / duplication
- Two overlapping price extractors: detection's `candidateFromJSONLD` price path and
  `staticPrice`'s meta→JSON-LD→embedded→amazon chain. Overlap = drift risk.
- `priceFromMetaOrMicrodata`, `priceFromEmbeddedJSON`, `amazonStaticPrice`,
  `candidate(fromProductNode:)` each re-implement "amount + currency, default USD" with
  subtly different fallbacks (JSON-LD defaults currency to USD; embedded JSON *requires*
  a currency; amazon falls back TLD→USD). Inconsistent currency policy across tiers.
- `ProductPageDetector` mixes detection, static price, embedded JSON, Amazon-specific
  regex, and pure parsing primitives in one 790-line type. The Amazon block is the only
  per-site rule and it's hard-coded inline — not an extensible table.

### P6 — Currency defaulting to USD is silently wrong
`price(fromOffer:)`, `priceFromMetaOrMicrodata` default missing currency to `"USD"`. A
European/AU page that declares a price but not a currency code gets tracked as USD,
producing a meaningless "best price" and bogus alerts. Currency should be required or
host/TLD-inferred (as Amazon already does) — not blindly USD.

---

## 3. Proposed simplified design

Collapse detection-vs-pricing into **one** extractor with a single price source, an
**extensible per-host rule table**, and a clearly-bounded, host-gated WebView tier.

### `ProductMetadataExtractor` — one component, one price
```swift
/// Pure, deterministic. Given a classified product page (URL + HTML), produces the
/// complete metadata INCLUDING a mandatory price, or nil. No second price path.
struct ProductMetadataExtractor {
    /// Ordered, extensible per-host rules consulted before the generic fallback.
    /// First rule whose `matches(host:)` is true is tried; its price wins if found.
    private let hostRules: [ProductPriceRule]   // [AmazonRule(), TargetRule(), WalmartRule(), …]

    /// Extract once. `staticOnly` forbids the WebView tier (set TRUE in extensions).
    /// `render` is the injected WebView tier (nil in extensions / tests).
    func extract(
        url: URL, html: String,
        render: ((URL) async -> String?)? = nil
    ) async -> ProductMetadata?
}

/// The full result. Price is non-optional by construction — no ProductMetadata
/// without a real price (mandatory-price invariant lives in the type).
struct ProductMetadata: Equatable {
    let name: String
    let price: ProductPrice          // { amount: Decimal, currency: String } — always present
    let imageURL: URL?
    let brand: String?
    let productID: String?
}
```

### Per-host rule (the extensible table)
```swift
/// One site's price-extraction strategy. Pure + deterministic. Adding a retailer =
/// adding one conformer to the table; no edits to the extractor.
protocol ProductPriceRule {
    func matches(host: String) -> Bool
    /// Extract (amount, currency) from this site's markup. Currency MUST be resolved
    /// here (declared code, else a host/TLD map) — never a blind USD default.
    func price(html: String, document: Document, host: String) -> ProductPrice?
}

struct AmazonRule: ProductPriceRule {        // priceAmount/displayPrice/buy-box a-offscreen + TLD→currency
struct TargetRule:  ProductPriceRule {        // __NEXT_DATA__ price.current_retail
struct WalmartRule: ProductPriceRule {        // __NEXT_DATA__ priceInfo.currentPrice.price
// generic fallback (not in the table): JSON-LD Offer → OG product:price → microdata → embedded JSON
```

### Composition after the classifier says `.product`
```swift
// In ArticleIngestDecider.decide — ONE fetch, ONE parse, ONE price:
let doc = try SwiftSoup.parse(html, url.absoluteString)
guard classifier.isProductPage(document: doc, url: url) else { /* article path */ }

let render: ((URL) async -> String?)? = isExtension ? nil          // extensions: static only
                                                     : webViewRenderer
if let meta = await metadataExtractor.extract(url: url, html: html, render: render) {
    return .priceTracker(meta, html: html)        // meta.price is guaranteed real
}
// product-looking but no resolvable price → fall through to article (no half-tracker)
```
Key shifts vs today:
- **Detection no longer carries a price**; the classifier returns a boolean. Price is
  produced exactly once, by the extractor. Eliminates P1's two-sources-of-truth.
- **`staticOnly`/`render == nil` is the enforcement** that the WebView tier is main-app
  only (P3). Extensions pass nil and can only ever do static extraction; if static
  fails they save an article — never spin a WebView. The main app can opt into render.
- **Per-host rules are a table** (P5): Amazon stops being a special inline branch; Target/
  Walmart slot in next to it. Generic JSON-LD/OG/microdata is the final fallback.
- **Currency is resolved inside each rule** (P6) — declared code or host/TLD map, no USD
  default. Generic fallback infers from symbol/TLD or returns nil (no tracker).
- WebView tier keeps the deterministic poll + single hard deadline, but is **bounded
  shorter for save-time** than refresh, and is structurally unreachable in extensions.

Also tighten `isAmazonHost` to a real suffix check
(`host == "amazon.<tld>"` / `host.hasSuffix(".amazon.<tld>")` against the known TLD set),
not `hasPrefix("amazon.")`/`contains(".amazon.")` (P2).

---

## 4. Testability

### Existing coverage (good)
- Determinism: `testBunningsDetectionIsDeterministicAcrossManyRuns` (200×),
  `testFirstPriceIsOrderStableWithMultiplePriceObjects`, `testJSONLDProductSelectionIsOrderStable`.
- Fetcher tiers: static-wins-no-render, structured fetch, render fallback, no-price→nil,
  **hard-timeout** (`testOverallTimeoutTerminatesAHangingRender`), Amazon-static-no-render.
- Matching: id/fuzzy/brand/tie-break-by-lowest-UUID (both directions).
- Refresh: stalest-first order, newly-alerting, failing-fetch-unchanged, archived-skipped.
- Parsing: US/EU/thousands price, currency normalization, Amazon TLD map.

### Gaps to close
- **No test asserts the WebView tier is unreachable in an extension** — add a test that
  builds the extension-config extractor (render == nil) and verifies a JS-only-price page
  resolves to nil (→ article), proving P3 can't regress.
- **No end-to-end "detect succeeds but price disagrees" test** — once unified, add a test
  that a product page where the classifier says product but no rule finds a price yields
  `.article`, not a priceless tracker.
- **`amazonStaticPrice` wrong-offscreen-span risk untested** — add a fixture with a
  strikethrough list price BEFORE the buy-box price and assert the buy-box price wins.
- **No multi-store refresh test across two currencies** (display-currency selection on
  refresh) and **no merge-vs-create integration test** through `ingestProductTracker`.

### Real fixtures to capture (current ones are hand-trimmed)
- `amazon-dp.html` ✅ (known-good: 39.99 AUD via TLD) — but capture a SECOND real Amazon
  page that has a list price + sale price to lock the buy-box selection.
- **`target-nextdata.html`** — REAL capture needed (`__NEXT_DATA__` `current_retail`).
- **`walmart-nextdata.html`** — REAL capture needed (`__NEXT_DATA__` `priceInfo.currentPrice`).
- `bunnings-nextdata.html` ✅, `shopify-og.html` ✅, `bestbuy-microdata.html` ✅,
  `amazon-jsonld.html` ✅, `generic-jsonld-graph.html` ✅ (EU comma), `article-no-price.html` ✅.
- A **JS-only price** fixture pair (pre/post-render) already exists inline in
  `PriceFetcherTests`; promote it to a file so the extension-static-only test can use it.

---

## Recommended price-extraction API + per-site rule

```swift
/// A site's price-extraction strategy. Pure, deterministic, currency-complete.
/// Register a new retailer by adding one conformer — the extractor never changes.
protocol ProductPriceRule {
    func matches(host: String) -> Bool
    func price(html: String, document: Document, host: String) -> ProductPrice?
}

struct AmazonRule: ProductPriceRule {
    private static let tldCurrency: [(suffix: String, code: String)] = [
        (".com.au","AUD"), (".co.uk","GBP"), (".co.jp","JPY"), (".ca","CAD"),
        (".de","EUR"), (".fr","EUR"), (".it","EUR"), (".es","EUR"), (".in","INR"), (".com","USD"),
    ]
    func matches(host: String) -> Bool {            // strict: real storefront only
        host == "amazon.com" || host.hasSuffix(".amazon.com")
            || Self.tldCurrency.contains { host == "amazon\($0.suffix)" || host.hasSuffix(".amazon\($0.suffix)") }
    }
    func price(html: String, document: Document, host: String) -> ProductPrice? {
        let currency = declaredCurrency(html)                       // "currencyCode"/"priceCurrency"
            ?? Self.tldCurrency.first { host.hasSuffix($0.suffix) }?.code
            ?? "USD"
        // Buy-box first (Amazon's price model), then the buy-box offscreen span — NOT the
        // first .a-offscreen on the page (that's often the strikethrough list price).
        let amount = firstMatch(html, #""priceAmount"\s*:\s*([0-9]+(?:\.[0-9]+)?)"#)
            ?? firstMatch(html, #""displayPrice"\s*:\s*"([^"]+)""#)
            ?? buyBoxOffscreenPrice(document)                       // scoped to corePriceDisplay/buybox node
        return amount.flatMap(ProductPageDetector.parsePrice).map { ProductPrice(amount: $0, currency: currency) }
    }
}

/// extract() consults rules in order, then the generic JSON-LD/OG/microdata/embedded
/// fallback, then (only if `render != nil`, i.e. main app) the bounded WebView tier.
/// Returns ProductMetadata ONLY when a real price was found — mandatory-price invariant.
```

**Net:** the deterministic pure layer is strong and well-tested; the failures live in the
*composition* — detection and pricing as two divergent code paths run twice (P1), the
WebView last-resort running inside extensions (P3), live-page residual non-determinism in
that WebView (P4), and a too-loose Amazon host match + wrong-span selection (P2). A single
`ProductMetadataExtractor` with an extensible per-host rule table, one price source, a
hard mandatory-price invariant, and a `render == nil` switch that makes the WebView tier
structurally main-app-only resolves all four.
