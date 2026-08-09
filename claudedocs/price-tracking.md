# Price Tracking

When a saved/pasted URL is a **product page with a price**, Luna treats the save
as a **price tracker** instead of an article: it watches the product's price
across one or more store URLs and alerts the user (local notification + a red
top-of-list badge) when the price drops past a threshold.

**A tracker may have NO threshold**, and a brand-new one does whenever the
notification prompt has never been answered — see
[Alert threshold and notification permission](#alert-threshold-and-notification-permission).

**Finding OTHER retailers selling the same product** — the seller directory,
candidate ranking, fan-out engine, keyed `ProductIdentifiers`, and the median
alert baseline a save-time fan-out seeds — lives in
[`price-comparison.md`](price-comparison.md). Two things documented here are
extended there: `ProductMetadata`/`ProductInfo`/`PriceTracker` now carry KEYED
identifiers alongside the flattened `productID`, and `PriceTracker.initialPrice`
gains exactly one post-creation mutator (`seedComparisonBaseline`) for the
save-time fan-out.

## Key files

**The price is MANDATORY.** A tracker is only ever created from a real numeric
price + currency, fetched up front (and re-fetched on every background cycle).
There is no pending/unknown/nil price state. Detection identifies a product
*candidate*; the price is resolved; only a candidate with a real price becomes a
tracker — otherwise the page is saved as a plain article.

### Save-time price extraction (Stage 2 — `ReaderKit/ProductMetadataExtractor.swift`)

The save-time path now uses **`ProductMetadataExtractor`**: given a page already
classified `.product` (the classifier / `ProductPageDetector.detect` owns "is this a
product?"; this component never re-decides it), it produces `ProductMetadata { name,
price: ProductPrice, imageURL?, brand?, productID? }` from **ONE parse, ONE price
source** — no detect-then-refetch double parse (the former "sometimes saves" root). The
price is **non-optional in the type**; `extract` returns nil when no real price is
resolvable (→ article, never a price-less tracker).

- **Extensible `[ProductPriceRule]` table.** First rule whose `matches(host:)` is true
  wins; each resolves its OWN currency (declared code, else host/TLD map) — never a
  silent USD default. Adding a retailer = adding one conformer.
  - **`AmazonPriceRule`** — buy-box price from Amazon's price model
    (`"priceAmount"`/`"displayPrice"`), then the buy-box-SCOPED `.a-offscreen`
    (`#corePriceDisplay…`/`#buybox`/…) — NOT the first `.a-offscreen` on the page (often
    a strikethrough list price). Strict `matches` suffix check over the storefront TLDs
    (so `amazon.scam.com`/`cdn.amazon.akamai.net` can't match); TLD→currency
    (`.com.au`→AUD, `.com`→USD, …).
  - **`TargetPriceRule`** — `__NEXT_DATA__` `price.current_retail` (USD).
  - **`WalmartPriceRule`** — `__NEXT_DATA__` `priceInfo.currentPrice.price` (USD).
  - **Generic fallback** (`ProductPageDetector.genericStructuredPrice`) — JSON-LD
    `Offer` → OG `product:price` → microdata → embedded app-state JSON. Inline
    `window.__… = {}` state is scanned from untyped, `text/javascript`, and
    `application/javascript` scripts. Generic price objects may declare currency as
    a string or as a nested ISO object beside the amount (for example,
    `{currency:{code:"AUD",symbol:"$"},value:49.9}`); this does not require a
    retailer-specific rule.
- **Google Shopping aggregate pages → multi-seller trackers** (`GoogleShoppingProductParser`).
  A saved Google Shopping page is an aggregator, not a seller, so it becomes a tracker
  over the retailer pages Google lists (never `google.com`). `GoogleShoppingURL.isProductPage`
  is the ONE predicate (shared with `Classifier`, which routes a hit straight to
  `.product`) recognizing `google.com/search` with any shopping marker: the results grid
  (`tbm=shop`/`udm=28`/`shopmd`) or a specific product's offers page (`ibp=oshop`/`prds`
  — what a shared `share.google` product link resolves to). Each `<a>` is unwrapped from
  Google's `/url?…&url=`/`q=`/`adurl=` redirect, Google-owned hosts are dropped, the
  nearby price (walking ≤6 ancestors) + currency (symbol → seller-TLD) become a
  `ProductSellerInfo`, and sellers are **deduped by host+path** (so one retailer listed
  twice under different click-tracking query strings is a single seller; `srsltid`/`gclid`
  are stripped from the stored URL). Lowest price = the tracker baseline.
- **The WKWebView render tier is structurally unreachable in extensions.** `extract`
  takes `render: ((URL) async -> String?)?`; the render tier runs ONLY when `render !=
  nil`. `IngestPipeline.process` defaults `render` to **nil**, so the share/action
  extensions can never spin up a `WKWebView` (the "spins forever" fix); only the main
  app (`ReadingListIngestor`) injects `WebViewPriceRenderer.renderedHTML`. Where it does
  run it is hard-bounded (deterministic poll + single deadline).
- Tests: `ProductMetadataExtractorTests` (amazon buy-box vs list-price fixture, lookalike
  host rejection, target/walmart `__NEXT_DATA__`, generic JSON-LD/OG/bunnings, no-price→nil,
  render-unreachable-with-nil, render-used-when-provided, determinism). Fixtures:
  `Products/{amazon-dp,amazon-listprice,target-nextdata,walmart-nextdata}.html`.

The legacy **`PriceFetcher`/`PriceFetching`** below now backs the **background refresher
only** (`PriceRefresher`); the save-time decision no longer calls it.

- `ReaderKit/ProductPageDetector.swift` — **pure** detection. Given URL + HTML
  returns an optional `ProductCandidate { name, staticPrice: ProductPrice?,
  imageURL?, brand?, productID? }`. `ProductPrice { amount: Decimal, currency }` is
  the shared (always-present) price value type. Detection answers "is this a
  product?" and reports the price in the static markup (`staticPrice`); it does NOT
  gate on a price (a heuristic candidate may have its price only in the rendered
  DOM). **Two tiers:**
  - **Tier 1 — structured price (a single hit = product; `staticPrice` non-nil).**
    (1) JSON-LD `Product`/`Offer` (`offers.price`/`priceCurrency`, recursing
    `@graph`/arrays and `AggregateOffer.offers`/`lowPrice`/`priceSpecification`); (2)
    OpenGraph `product:price:amount`/`og:price:amount` + currency; (3) schema.org
    microdata (`itemprop=price`/`priceCurrency`); (4) bare price meta.
  - **Tier 2 — heuristic (no structured price; retailers that render price
    client-side, e.g. Bunnings).** `heuristicProductScore` sums STRONG signals, each
    worth 1: `og:type=product`; an "add to cart"/`addToCart` affordance (button text
    or JS handler); a rating (`aggregateRating`/`ratingValue`/"out of 5"/"Star
    Rating"); a retail URL pattern (`urlLooksLikeProduct`: `_p<digits>`, `/dp/<id>`,
    `/p/<digits>`, `/products/<slug>`, `/itm/<id>`); and a price recovered from
    embedded app-state JSON. **≥2 (`minimumHeuristicScore`) ⇒ product.** The
    candidate's `staticPrice` is the embedded-JSON price if found, else **nil** (the
    price is only in the rendered DOM → the `PriceFetcher`'s WebView fallback).
  - **`staticPrice(urlString:html:)`** — resolves the price visible in the STATIC
    markup (Tier 1 structured data → Tier 2 embedded JSON → **Amazon retailer-specific**),
    independent of product detection; the `PriceFetcher` calls it for its fast,
    no-WebView paths.
  - **Amazon static price** (`amazonStaticPrice(html:baseURL:)`, pure): Amazon `/dp/`
    pages embed the price in the static markup but with NO JSON-LD/OG/microdata price
    node, so Tier 1 + embedded-JSON both miss. This reads Amazon's price shapes
    directly: `"priceAmount":<n>`, `"displayPrice":"$…"`, and the visible
    `.a-price .a-offscreen` span. Currency: a declared `currencyCode`/`priceCurrency`
    if present, else the **Amazon TLD → currency** map (`amazonCurrency(forHost:)`:
    `.com.au`→AUD, `.com`→USD, `.co.uk`→GBP, `.ca`→CAD, `.de`/`.fr`/`.it`/`.es`→EUR,
    `.co.jp`→JPY, `.in`→INR), so a bare `$` resolves correctly per storefront. Detection
    of the page itself already works via `urlLooksLikeProduct` (`/dp/<ASIN>`,
    `/gp/product/`) + add-to-cart. Fixture `Products/amazon-dp.html` (trimmed
    amazon.com.au) → **39.99 AUD** via the fast static path, no WebView, no spin.
  - **`priceFromEmbeddedJSON`** scans `__NEXT_DATA__`, every
    `<script type=application/json>`, and inline `window.__…={…}` blobs
    (`firstJSONObjectLiteral` balanced-brace extractor). `firstPrice(in:)` recurses
    JSON **in sorted-key order** (Swift dictionary iteration is hash-seed randomized
    per process — sorted traversal keeps a tree with >1 price node resolving to the
    same price every launch) for the first object carrying a price-context key (`priceAvailable`/
    `priceType`/`priceCurrency`/`currencyIso`/`currencyCode`/`sellPrice`/`nowPrice`/
    `salePrice`/`formattedValue`), a numeric value (`value`/`amount`/`*price`, or a
    `formattedValue` like `"$99.00"`), and a currency (sibling currency string,
    nested currency `code`/`iso` object, or a `formattedValue` symbol). Bunnings
    fixture → **99 AUD** (`{currencyIso:"AUD",
    formattedValue:"$99.00",priceAvailable:true,priceType:"FROM",value:99}`).
  - `parsePrice` tolerates `$1,234.56` (US) and `1.234,56`/`23,50 €` (EU);
    `normalizeCurrency` maps `$£€¥` → ISO codes. `productID` from
    gtin13/12/14/8/gtin/isbn/mpn/sku/productID. Reuses the article extractor's
    recursive JSON-LD walk pattern.
- `ReaderKit/PriceFetcher.swift` — `PriceFetching` (protocol + live `PriceFetcher` +
  `MockPriceFetcher` in tests). `fetchPrice(forURLString:prefetchedHTML:)` resolves
  the **mandatory** current price in order: **(a) static markup** (structured data →
  embedded JSON via `ProductPageDetector.staticPrice`, using `prefetchedHTML` when
  the caller already fetched it, else fetching), **(b) WKWebView render fallback** —
  if the static paths find nothing, `WebViewPriceRenderer.renderedHTML(for:)` loads
  the page in an off-screen `WKWebView` so client-side JS runs, then re-applies the
  same static extractor to the rendered `outerHTML` (recovering prices that only
  exist after rendering). Returns nil when no price is found by any method (→ article
  fallback). Reused by BOTH save-time and the background refresher, so the WebView
  fallback runs in both. `WebViewPriceRenderer` runs on the main actor, creates/tears
  down its WebView per call (nothing held between fetches). It **polls** the rendered
  DOM (`pollIntervalSeconds`) and returns as soon as `staticPrice` is extractable, up
  to a hard timeout — NOT a fixed settle sleep, which would race JS hydration and make
  the same page sometimes yield a price and sometimes time out (→ article). Lives in
  ReaderKit (UIKit/WebKit, like `ArchiveWebReaderViewController`), so it works in the
  main app and the UI-hosting action/share extension. **No infinite spin**: `fetchPrice`
  wraps the whole resolution in a hard overall timeout (`overallTimeoutSeconds`, default
  30s) and `WebViewPriceRenderer.render` bounds navigation + price-poll under ONE shared
  deadline (was two sequential 20s waits → ~40s worst case). On timeout it returns nil →
  the caller falls back to a normal article (mandatory-price rule), so a save can NEVER
  hang in the loading state. Test: `testOverallTimeoutTerminatesAHangingRender`.
- `ProductInfo { name, priceAmount: Decimal, priceCurrency, imageURL?, brand?,
  productID? }` (in `ProductPageDetector.swift`) — a candidate paired with a fetched
  price, built via `ProductInfo(candidate:price:)`. The price is **required**; a
  `ProductInfo` only exists once a real price is in hand, so a tracker can never be
  created without one.
- `ReaderKit/PriceTracker.swift` — the model + the friend-share payload:
  - `PriceTrackerStore { urlString, lastPrice: Decimal?, currency, lastRefreshed: Date? }`.
  - `PriceTracker` — `productName`, `stores` (private(set), **always ≥1**), `brand?`,
    `productID?`, `imageFileName?`, `initialPrice` (best at creation = alert
    baseline), `initialCurrency`, **`alertThresholdFraction: Double?`** —
    `private(set)`, **nil = no alert set at all** (default `0.10` =
    `PriceTracker.defaultAlertThresholdFraction` when one is seeded) —
    `isArchived`, `alertAcknowledgedAt: Date?` (nil = the current alert, if any, is
    still UNVIEWED). **`init(price:)` takes a required `Decimal`** — a tracker cannot
    exist without a real numeric price (the `PriceFetcher` resolves it before the
    tracker is created). Computed: `currentBestPrice` (min across fetched store
    prices, else `initialPrice`), `displayCurrency`, `discountFraction`,
    **`hasAlertThreshold`**, `isAlerting`
    (`threshold != nil && !isArchived && discount ≥ threshold` — **a tracker with no
    threshold never alerts, however far the price falls**), `alertThresholdPrice:
    Decimal?` (nil ⇒ the graph draws no alert line), **`hasUnviewedAlert`**
    (`isAlerting && alertAcknowledgedAt == nil` — the condition that floats the row to
    the very top of the whole list). Mutators: `upsertStore`,
    `removeStore` (no-ops on the last store → ≥1 invariant), `setPrice` (a strictly
    lower price for a store clears `alertAcknowledgedAt` so a fresh drop re-floats),
    **`setAlertThresholdFraction` / `setAlertThresholdPrice`** (the ONLY ways in — both
    clamp to 0.01…0.95, and both leave the unset state), **`clearAlertThreshold`**,
    **`markAlertViewed(at:)`** (sets `alertAcknowledgedAt`; no-ops when not alerting —
    called when the user opens an alerting tracker). **Migration-safe** `Codable` (all
    fields defaulted; `alertAcknowledgedAt` absent in old payloads → nil → unviewed;
    empty `stores` repaired; a present threshold clamped 0.01…0.95). **An ABSENT
    `alertThresholdFraction` key IS the unset state** — the encoder omits a nil
    optional, so "no alert" round-trips through `readingList.json` with no sentinel
    number, and a pre-threshold payload reads as unset too. Merging a cheaper store
    does NOT lower `initialPrice` (the baseline is fixed at creation).
  - `PriceTrackerShare` — portable friend-share form (URLs + best price at share
    time + threshold + brand/productID); `makeTracker()` rebuilds on receipt.
- `ReaderKit/ProductMatcher.swift` — **pure, order-stable** same-product matching:
  (1) normalized `productID` equality wins (lowest id when several match); (2) else
  fuzzy token-Jaccard name similarity ≥ 0.6 with compatible brand (equal, or one side
  unbranded), highest score, **ties broken by lowest id** (not input order). Stop-words
  stripped.
- `ReaderKit/PriceRefresher.swift` — **pure-ish** background-refresh logic.
  `PriceTrackerPersisting` seam (`ReadingListStore` conforms); injects a
  `PriceFetching` + a clock. `refreshAll()` processes trackers **stalest-first**,
  re-fetches each store's price via the same `PriceFetcher` (incl. the WebView
  fallback), updates prices, persists each tracker as it finishes (resumable), and
  returns `PriceRefreshOutcome` per tracker with `newlyAlerting` (crossed threshold
  THIS run = the notification trigger).
- `ReaderKit/PriceFormatting.swift` — **pure** currency string (`$45.99`, `€23.50`,
  `AUD 89.00`) and `thresholdDescription` ("10% off — alert below $90.00").
- `Luna/ReadingList/PriceTrackingManager.swift` — `PriceTrackingManaging`
  (`fetchPrice(urlString:) -> ProductPrice?`); live impl wraps `PriceFetcher` so the
  add-a-store UI resolves a new URL's price with the same strategy.
- `ReaderKit/PriceTrackingExitContext.swift` — **pure** navigation decision model.
  `PriceTrackingHost` (`.inApp`/`.extension`) + `PriceTrackingEntry`
  (`.creation` / `.merge(addedStoreURLString:)` / `.existing`) → a
  `PriceTrackingExitContext` exposing `leftButton` (`.back` in-app / `.done` in an
  extension). Unit-tested, no UIKit — the editor's exit is a function of the host,
  decided independent of the view hierarchy. The entry no longer decides chrome of
  its own (it used to add a top-right "Read instead"); `merge` still names the
  seller URL the editor flashes at the top.
- `ReaderKit/ProductSearchURL.swift` — **pure** URL builders. `googleShoppingURL(forProductName:)`
  (`…/search?tbm=shop&q=<+-encoded name>`, escaping `&=+?#/`); `navigationURL(fromBarText:)`
  (scheme → load; bare `host.tld[/…]` → https; else a Google web search). Unit-tested.
- `ReaderKit/ProductSearchOverlayViewController.swift` — the **search overlay**, a
  near-fullscreen WKWebView styled like the inline reader (`SplitWebOverlayViewController`):
  inset rounded glass card (`ReaderDepth` background), a compact ✕ tab above its
  leading edge, a compact Safari tab above its trailing edge, and a bottom glass bar
  with back/forward controls, an editable URL field, and a circular **+**. There is
  no tab strip. Preloads the Google Shopping search for the product. Free
  browse/type-and-go. **+** → a **"Use this page?"** alert ("Add to tracker" /
  "No thanks").
  - **Keyboard avoidance:** the bottom bar is a direct child of the root view (NOT the
    card) and its `bottomAnchor` is pinned to `view.keyboardLayoutGuide.topAnchor`
    (`.defaultHigh`) with a `lessThanOrEqualTo` `safeAreaLayoutGuide.bottomAnchor` cap —
    so it rides up just above the keyboard while typing and drops back on dismiss, the
    URL field always visible/usable.
  - **Auto-suggest (UNIFIED):** on `didFinish` it reads
    `document.documentElement.outerHTML` and runs `ProductPageSuggestion.resolve`
    (`ReaderKit/ProductPageSuggestion.swift`) — the SAME `Classifier.classify == .product`
    + `ProductMetadataExtractor` (`render: nil`, the page is already rendered) the ingest
    pipeline uses. If the rendered page is a product WITH a resolvable price it
    AUTO-presents the "Use this page?" alert. This is exactly the Add-success condition,
    so a page that auto-suggests is a page whose Add will succeed (no parallel detector).
    Debounced per-URL via `ProductSuggestionDebouncer` (`ReaderKit/`, pure, tested) so it
    fires at most once per page.
  - **Add → outcome:** on confirm (manual + or auto-suggest) it hands the current URL +
    rendered HTML up via `onUseThisPage(urlString, html, completion)` and AWAITS the
    host's `ProductSearchAddOutcome`. On `.added` it **dismisses** (returning to the
    tracker page, now updated); on `.noPrice` it shows **"Couldn't find a price"**; on
    `.duplicate` it shows "Already tracked" — never a silent no-op. It never touches the
    store (the host does the mandatory price fetch + dedupe + add). Lives in ReaderKit
    (WebKit, reusable), free of ReadingList deps.
- `ReaderKit/ProductPageSuggestion.swift` — **pure** unified suggest decision.
  `resolve(url:html:)` returns `ProductMetadata?` = `Classifier.classify == .product`
  AND `ProductMetadataExtractor.extract(render: nil)` over the RENDERED `outerHTML`
  (JS-loaded prices already in the DOM). The single source of "suggest = Add succeeds".
- `ReaderKit/ProductSuggestionDebouncer.swift` — **pure** per-URL debounce
  (`shouldOffer(urlString:)` true once per URL; `hasOffered(urlString:)`).
- `LunaPriceUI/ProductDetailViewController.swift` — **the product surface**, and
  the only one. Every app and every extension that shows a tracked product shows
  this controller; its hosts add chrome and nothing else. Top to bottom:
  - **Header** — a 46pt product thumbnail (`ProductArtwork.swift`: the declared
    product image, then the page header image, then its favicon; never Luna's
    price-tag glyph), the product's SHORT name, the
    full scraped title under it in caption type over at most two lines, and — on
    the right — the current best price with `N% off` beneath it when the tracker
    is below its baseline. The short name comes from `ProductTitleSummary`
    (below).
  - **Graph** — the always-present `PriceGraphView`, with its directly editable
    green absolute alert threshold (or, for a tracker with no alert set, the
    **"Set price alert"** pill in its place) and its tap-only point tooltip. Its
    height is a share of the surface (30%, clamped to 132…260pt, and to 168pt
    while there is no history to draw) rather than a constant, because the two
    hosts are different sizes. It is also the band that absorbs spare height.
  - **Alert row** (`AlertThresholdRow.swift`) — one 46pt line: a bell, "Alert
    at", the slider (0.01…0.90), and the price it resolves to. See the next
    section for its two states. The row's slider and the graph's line drive each
    other live through `PriceGraphView.setThresholdPrice`, so the two controls
    can never show different thresholds mid-drag.
  - **Sellers** — the heading, a green **+**, and a scroll viewport of
    `SellerRowView`s. A row is 44pt: favicon, seller NAME, price (the cheapest
    tinted green when there is more than one). Tap → in-app Safari; long press →
    Open / Remove. The viewport is exactly as tall as its rows until they stop
    fitting, then it takes the remainder and scrolls — so a longer list is cut
    mid-row rather than just past the first one. While a save-time fan-out is
    out, its "Checking for other sellers…" row sits at the end of the list.
  - **+** offers both ways to add one, in both hosts: **Search** (presents
    `ProductSearchOverlayViewController` with the Reader-style eclipse) and
    **Paste a link** (a URL alert). Either way the price fetch is MANDATORY —
    `PriceFetcher` (static → embedded JSON → WebView), no price ⇒ "No price
    found" and nothing added, `hasStore` dedupe. In the main app only, a no-price
    page also offers `ProductPriceRescue.resolver` ("Try using on-device AI"),
    the URL-rescue seam `KindWiring` installs at launch.
  - Reloads on `.readingListChanged` — a fan-out lands its retailers one at a
    time from a background task, so the surface has to hear about changes it did
    not make.
- `LunaPriceUI/ProductTitleSummary.swift` — **pure**, shape-only heuristic for
  what a card leads with. `headline(for:)` cuts at the first separator
  (`| : – — · , ;` or a spaced hyphen), drops bracketed asides, takes up to three
  words, stops early at a token containing a digit once two words are already
  down ("Apple iPhone", but "Sony WH-1000XM5 Wireless"), and falls back to two
  words when three run past 30 characters. `detail(for:)` is the whole title, or
  nil when the headline already said it. No brand or noun vocabulary anywhere:
  the worst case is "the first few words", never a confident wrong guess.
- `LunaPriceUI/SellerNaming.swift` — what a seller is CALLED, everywhere Luna
  names one (the rows here AND `SellerComparisonDocument`): the bundled seller
  directory's own name first ("Amazon Australia", "JB Hi-Fi"), else the
  registrable domain with its public suffix dropped and its first letter raised.
  Plus the lettered badge a host with no readable favicon falls back to.
- `LunaFetch/SiteIconCache.swift` — the favicon behind each seller row. It used
  to live in the app shell as `SourceIconCache` (the Reader's scrub chips), which
  the extensions could not reach — so the card drew a `safari` compass for every
  seller alike. One cache now: memory + disk + a negative cache + in-flight
  de-duplication over `FaviconFetcher`.
- `Luna/PriceTracker/ProductCardContent.swift` — the card HOST: the deck's card
  frame, an 18pt inset, and the surface above inside it. It also carries the two
  `UtilCardSaveTransitionAnchor` identifiers the save transition flies into.
- `LunaPriceUI/PriceTrackingViewController.swift` — the screen HOST: a
  `NavHeaderBar`, a `ReadableColumn`, the way out, and the same surface between
  them. PUSHED onto the reading-list nav stack in-app, or PRESENTED modally by the
  action/share extension's `ShareSurfaceDriver` on a `.product` outcome
  (`PriceTrackingHost.extension`, exiting via the injected `onDone`). **The exit
  differs by host and nothing else**: in-app, a back chevron in the header; in an
  extension, the floating glass `ExtensionExitButton`, with the content's bottom
  edge pinned above it so the circle never covers the seller list. There is no
  "Read instead" button — the editor no longer re-saves a tracker as an article.
  `Mode.existing(itemID:)` (tap a row) / `.creation(itemID:host:)` /
  `.merge(itemID:addedStoreURLString:host:)` (save-time, flashes the added
  seller). Each `Mode` maps to a `PriceTrackingExitContext`. Declares
  `Notification.Name.priceTrackerSavedInteractively`.
- `Luna/ReadingList/PriceRefreshCoordinator.swift` — main-app side effects: runs
  `PriceRefresher` over the shared store and posts `NotificationManager.postPriceDrop`
  per `newlyAlerting` outcome.
- `LunaLibraries/Sources/LunaStorage/NotificationAuthorizationState.swift` — the
  shared latch (**"has the notification prompt ever been shown"**) plus
  `PriceAlertThresholdPolicy`, the ONE decision about a new tracker's threshold. See
  the next section.

## Alert threshold and notification permission

A price alert is a promise to send a notification, so Luna does not make one before
it may notify. **Notification authorization is requested only at explicit opt-in
moments** (see the root `CLAUDE.md`); committing a price-alert threshold in EITHER
price editor is one of them, and that is what this flow is built around.

**A new tracker's threshold is a decision, not a constant.**
`PriceAlertThresholdPolicy.initialThresholdFraction` (LunaStorage) answers it:

| System authorization status when the product is tracked | New tracker starts with |
| --- | --- |
| `.notDetermined` (never asked) | **no threshold** — `alertThresholdFraction == nil` |
| anything else (granted **or** denied) | `PriceTracker.defaultAlertThresholdFraction` (10%) |

Denied counts as answered: the question has been put to the user, so trackers behave
exactly as they always did (an undelivered notification is then the OS's business,
not a promise Luna withheld). The policy is asked at every creation site —
`ProductTrackerIngestor` (main app), `ExtensionProductPresenter` (share/action
extensions), `ShareReaderViewController`'s silent product save — and
`ProductInfo.makeTracker(fallbackURL:alertThresholdFraction:)` **requires** the value
rather than defaulting it, so a new surface cannot quietly promise an alert.

**Reading the status.** The truth is `UNUserNotificationCenter`'s
`authorizationStatus`, which is asynchronous and unavailable to ask (only to read)
inside an `.appex`. `NotificationAuthorizationState` (App-Group `UserDefaults`) is the
synchronous latch over it:

- `NotificationManager.requestAuthorization()` marks it the moment it asks (the prompt
  is up whatever the user answers) and, as before, is **idempotent** and **self-skips
  in an `.appex`** — so the extension-hosted price editor calls it harmlessly.
- `NotificationManager.refreshAuthorizationRequestedState()` (async, returns the
  answer) reads the real status and latches it; the ingestor awaits it before deciding,
  and both price surfaces kick the fire-and-forget form
  (`refreshAuthorizationRequestedStateInBackground()`) on load — which is also how an
  install that granted permission *before this latch existed* heals.
- The latch only ever goes ON: revoking permission in Settings does not un-answer the
  question. `reset()` exists for tests.

**The unset state in the UI.** Both editors show it, and both treat committing a
threshold as the opt-in that raises the prompt:

- **The `AlertThresholdRow`** parks its slider at the default 10% with a dimmed
  track and thumb and puts a **"Set price alert"** button where the threshold
  price goes. Dragging the parked slider un-dims it and shows the real price from
  the first movement; release (or the button) commits. Nothing about the row's
  geometry changes between the two states, so setting an alert never moves the
  layout underneath it.
- **The `PriceGraphView`** has no line to drag, so with `allowsThresholdEditing`
  and a nil threshold it draws no alert line and shows a **"Set price alert"**
  pill where the line's price label would sit, reporting the tap through
  `onThresholdRequested`.
- Both, plus the graph's own committed drag, funnel into ONE
  `commitThreshold(fraction:)` on `ProductDetailViewController`:
  `setAlertThresholdFraction` + persist + `NotificationManager
  .requestAuthorization()` + reload. That is the only call to
  `requestAuthorization` anywhere in the product kind, and
  `NotificationAuthorizationCallSiteTests` pins it.

Once a threshold exists, everything downstream is the old behavior: `isAlerting`,
the floated `.priceAlert` row, and `PriceRefreshCoordinator`'s `postPriceDrop` on a
`newlyAlerting` outcome.

**Notification permission is asked when the threshold is committed, not at launch.**
Setting the alert line IS the request to be told about a drop, and it's the only thing
this app posts, so the one commit funnel calls
`NotificationManager.requestAuthorization()` right after persisting. It's idempotent,
so only the first commit prompts and no "have we asked yet" flag is needed; it also
self-skips in an `.appex`, so a threshold set inside the share/action sheet doesn't
spend the one-time prompt on a surface that's about to dismiss — the next in-app
commit asks. The other two ask-moments are the Save of the Week key and connecting a
sending account; nothing else in Luna requests authorization.

## Deck integration (`ReadingListSectioning` / the card roots)

The sectioned rows below remain for central Luna and test/extension navigation.
The standalone Price Tracker app uses the card root above.

- `Section.priceTracking` (raw 5, non-collapsible) sits **below** `.reading` in
  `displayOrder`; `Section.priceAlert` (raw 6, non-collapsible) is the very FIRST
  section (ahead of `.pasteboard`) and holds the single floated alert row.
  `displayOrder = [.priceAlert, .pasteboard, .reading, .priceTracking, .archive,
  .error]`. `ListFilter.priceTrackers` (raw 3).
- `rendersAsReader` is false for trackers; `ListFilter.mediaAndLinks` excludes them.
- `assignSections` returns a 4th `priceTracking` bucket (non-archived trackers;
  archived ones drop out of ALL buckets and the background refresh). The single
  floated tracker is excluded from this bucket.
- **`topUnviewedAlertingPriceTracker(items:)`** — the single tracker that is alerting
  AND **not yet viewed** (`hasUnviewedAlert`), greatest discount (ties by id),
  **at most one**. It floats to the very **top** of the whole list (rendered by the VC
  as the one row of the `.priceAlert` section), badged **red**. Once the user opens it,
  `markAlertViewed` is called (`ProductCardPresenter.itemDidCenter`, the same code in both apps), `hasUnviewedAlert`
  becomes false, and the row rejoins the `priceTracking` section below Reading. A later
  strictly-lower price clears the ack so a genuinely fresh drop re-floats.
- `shouldShowFilter` = ≥2 of {reader, media/link, price-tracker} kinds present.
  `hasPriceTrackers` gates the Price segment. The VC rebuilds the segmented control
  dynamically from `visibleFilters()` (index ↔ filter map, not raw-value coupling).
- Tracker rows render via `configurePriceTrackerCell` (keyed on `item.priceTracker`,
  so they render identically in the `.priceTracking` and floated `.priceAlert`
  sections): product image thumbnail (or a `tag`/`tag.fill` glyph), title = product
  name, subtitle = current best price (currency-formatted), `↓N%` in red when alerting.
  Tapping a row → `open` → marks the alert viewed if it was floating, then pushes
  `PriceTrackingViewController(itemID:)`.
- `ReadingListStore`: `savePriceTracker`, `updatePriceTracker`,
  `priceTrackersStalestFirst()` + `stalestRefresh(_:)`.

## Save-time UX

**Product detection + the mandatory price fetch run BEFORE any paywall/archive
treatment in every save path**, so a product page (incl. a client-rendered one
detected heuristically) routes to price tracking and is NEVER classified
`.paywalled`/`.unreadable` or sent through the archive/removepaywall bypass. Paste
and the action/share extension reach the SAME decision for a given URL. **Tracker
creation is gated on a successful price fetch**: detect a candidate → fetch the
price (static → embedded JSON → WebView) → if a price is obtained, create the
tracker; if NO price by any method, fall through to the normal article pipeline (a
plain article — never a broken tracker, never paywall-bypassed).

- **In-app paste / manual / app-intent**: `ReadingListIngestor.ingest` fetches once,
  article resolve), then `PriceFetcher.fetchPrice` on a candidate. On a real price →
  `ProductInfo(candidate:price:)` → `ingestProductTracker` (intelligent merge via
  `ProductMatcher`, else new tracker; collects product artwork, falling back to
  the page header image or favicon and repairing an artwork-less merged tracker), then posts
  `.priceTrackerSavedInteractively`; the reading list presents the editor in
  `.creation` mode (new tracker) or `.merge` mode (matched into an existing tracker;
  the new seller row is flashed), top-of-stack only. No fetchable price → records a
  note and falls through to `ArticleResolver`.
- **Share / action extension** (`ShareKit/ShareViewController.ingestArticleThenComplete`):
  runs `ProductPageDetector` then `PriceFetcher` on the fetched HTML **before**
  `ArticleResolver.resolve`. This is why the action extension never
  paywall-bypasses a product page. No fetchable price → article path. On a real
  price it persists the tracker, starts the alternative-seller fan-out in the
  background (below) and presents the SAME `PriceTrackingViewController` the app
  shows, IMMEDIATELY — `ExtensionProductPresenter.presentPriceEditor`.

## Save-time alternative-seller comparison

A new tracker does not stay a one-store tracker. Immediately after the initial
save, every save surface runs the alternative-seller fan-out — the same product
on other retailers' own sites, fetched now — and attaches what it verifies. The
engine, the candidate ranking and the match rules are `LunaPriceCompare`; the
whole feature is documented in `claudedocs/price-comparison.md`. What matters
here is where it sits in THIS pipeline:

- **Nobody waits for it.** `ProductTrackerIngestor.ingest` STARTS the run
  (`SellerComparison.beginAndRunInBackground`) and moves straight on to
  `PriceTrackerSaveAnnouncement`. The card the deck centres is the one-seller
  card the user was looking at, and it grows.
- **New trackers only.** The merge branch runs nothing: that tracker has been
  through a fan-out once, and re-running it would spend a dozen candidates
  re-finding the stores it is excluding.
- **Source first, then sellers, then the baseline.** Each verified seller is
  `upsertStore`d — with a live price AND a recorded day sample — as it lands, and
  the baseline is settled once at the end. Building every store up front instead
  would go through `PriceTracker`'s multi-store initializer, which takes the
  CHEAPEST store's currency as `initialCurrency` — one foreign-currency listing
  that happens to be numerically lowest would silently redenominate the tracker.
- **The baseline becomes the MEDIAN, unless the user has spoken.** See
  `claudedocs/price-comparison.md` § The median baseline and § Whose baseline it
  is. A tracker whose alert configuration the user changed while the run was out
  keeps their number and their baseline — and a cheaper seller arriving from the
  fan-out is then allowed to cross it and fire.
- **One store per retailer family.** The engine keys its own results by
  registrable domain; `apply` additionally refuses a domain the tracker already
  holds, which the engine cannot know about.
- **It is installed, not called.** `ProductKindComposition.install()` fills
  `SellerComparisonRunner.installed`; a process without it compares nothing, and
  stamps no pending marker either — a "checking for other sellers" row for a run
  that will never happen is worse than no row.

Surfacing the wait: both product surfaces draw one extra row while
`tracker.pendingComparison` is set — a spinner and "Checking for other sellers…"
under the seller list — one list, in one controller, in both hosts. It reloads
on `.readingListChanged`, which every streamed
seller posts, so the row fills in from underneath and disappears with the marker.

Surviving the process: the marker is on the TRACKER, so a share extension torn
down mid-run leaves the app something to resume from. `SellerComparison
.completePending` is swept at app launch (the product `KindWiring`s'
`appDidLaunch`) and at the head of every background refresh cycle
(`PriceRefreshCoordinator.refreshAndNotify`, before the refresh, so the sellers
it attaches arrive already priced). `SellerComparisonTasks` keeps two callers for
the same tracker on ONE run.

## Determinism (same URL → same result, always)

The classification of a page ("is this a product → is it a tracker, and which
price") must be a **pure deterministic function of the page content**. The only
allowed non-determinism is genuine network failure, which fails safely+consistently
(→ article) rather than flipping the classification. Sources that were fixed:

- **Hash-randomized JSON traversal.** `ProductPageDetector.firstPrice` and
  `firstProductNode` recursed `dictionary.values` in Swift's per-process hash-seed
  order, so a JSON tree with more than one price-bearing (or `@type:Product`) node
  resolved differently per app launch. Both now traverse children in **sorted-key
  order**. `price(inDictionary:)` likewise resolves lowercased-key collisions by
  the sorted-first original key.
- **Matcher tie-breaks.** `ProductMatcher.bestMatch` now breaks equal name scores
  and multiple id matches by **lowest id**, independent of the order `existing` is in.
- **WebView render race.** `WebViewPriceRenderer` **polls** the rendered DOM until
  the price is extractable (or a hard timeout) instead of a fixed settle sleep that
  raced JS hydration. Bunnings never needs the WebView at all — its price is static
  in `__NEXT_DATA__` and the static path returns 99 AUD deterministically.
- **Re-save dedup BEFORE re-detection.** `ReadingListIngestor.ingest` checks
  `ReadingListStore.priceTracker(containingStoreURL:)` first: if the URL is already a
  store inside an existing tracker (e.g. a previously-merged URL whose placeholder
  item was deleted), it short-circuits to that tracker and drops the duplicate
  instead of re-detecting (which could reach a different outcome) or creating a
  duplicate tracker. A NEW (un-merged) tracker keeps its item `.ready`, so `ingest`'s
  top guard already blocks re-detection. Paste and the extensions reach the same
  decision for a given URL.

## Passive product snapshots seed history at save time

Every product-page visit in a product-handling Safari extension is silently recorded
(`claudedocs/safari-extension.md`'s "Passive product snapshots" section) into an App
Group JSON file — `{name, price, currency, canonical url, host, keyed identifiers,
day, capturedAt}`, one record per (url, day). NOT a save: no reading-list row is
created, nothing is scheduled for refresh, and no alert can ever fire from one.
`LunaHTMLClassification.ProductSnapshot` is the one Codable shape; `LunaPriceUI
.ProductSnapshotStore` reads the shared file app-side (own mirrored App-Group path,
since `LunaSafari` links no package — parity pinned by `SharedProductSnapshotsTests`).

When `ProductTrackerIngestor.ingest` actually saves a product (new tracker OR merge),
it matches snapshots against the just-detected `ProductInfo`
(`LunaHTMLClassification.SnapshotMatcher` — same precedence as `ProductMatcher.
bestMatch` but over KEYED identifiers: GTIN/ISBN → retailerItemID+host-family →
mpn+brand → sku+host → canonical URL → fuzzy name+brand; the tracker's single flat
`productID` participates via `ProductMatcher.normalizedID` against every keyed
field). Matched snapshots are grouped by HOST: a host the tracker already has a store
for gets its `priceHistory` MERGED in (`PriceTracker.mergeHistorySamples`,
day-bucketed, lowest price wins per day — never touches `initialPrice`/`lastPrice`/
`lastRefreshed`, which describe a live fetch, not a passive record); a new host gets a
brand-new store seeded with that history. This is the ONE way a product can have a
non-empty `priceHistory`/graph at the moment it's first saved, instead of waiting for
the first background refresh. Snapshots are never deleted by matching — the same
snapshot can seed a different product later, and remains available to the history
pill.

Immediately after persisting, ingestion regenerates `priceHistoryIndex.json` (see
below) and fires a SINGLE-tracker refresh (`PriceRefresher.refreshTracker(itemID:)` /
`PriceRefreshCoordinator.refreshTracker(itemID:)` — same `newlyAlerting`/notification
semantics as a background cycle, scoped to one tracker) under a background task, so a
product seeded from history — or bounced back to Safari immediately after
(`claudedocs/safari-extension.md`) — still gets a LIVE price without waiting up to
12h for the next cycle.

### The compact history index (`PriceHistoryIndexWriter`)

The Safari extension can't read `readingList.json` (package-free, and it's both too
large and the wrong shape to hand-parse in an appex), so a product-handling app
maintains a compact mirror, `priceHistoryIndex.json`, next to the snapshots file: per
non-archived tracker, `{name, brand?, productID?, stores: [{url, host, points:
[{day, price, currency}]}]}`, capped at the last 365 days per store. Regenerated
whole-file (atomic) after `ProductTrackerIngestor` persists, after every
`PriceRefreshCoordinator.refreshAndNotify`/`refreshTracker` cycle, and from the
product apps' `KindWiring.appDidEnterBackground` (edits like clearing an alert
threshold or archiving a tracker don't otherwise trigger a write). Presence of a
matching product in this index is the extension's answer to "is this page already
tracked" — see the history-pill flow in `claudedocs/safari-extension.md`. Only `Luna`
and `LunaPriceTracker` link `LunaPriceUI`, so only those two ever write it.

## Background refresh (`AppDelegate`)

`BGProcessingTaskRequest` id `com.hsanabria.luna.priceRefresh` (~every 12h, needs
network), registered + scheduled alongside the existing inbox/mail tasks; the
identifier is in `Info.plist` `BGTaskSchedulerPermittedIdentifiers`. Handler →
`PriceRefreshCoordinator.refreshAndNotify`. Resumable: stalest-first + per-tracker
persistence, so a cancelled run still advances the oldest trackers. Archived
trackers are skipped. Every cycle re-fetches the real current price via the same
`PriceFetcher` (incl. the off-screen WKWebView fallback), so JS-rendered sites
refresh correctly.

## Friend sharing (`MessageBody.priceTracker`)

`MessageEnvelope` adds a `priceTracker(PriceTrackerShare)` case (wire field
`priceTracker`; decodes to `.unknown` if no store URLs — forward-compatible).
`SocialMessageCenter.sendPriceTracker(_:to:)` seals+sends; the receive branch (a
stored friend whose signing key matches) recreates the tracker via
`share.makeTracker()`, dedupes on the first store URL, sets `sharedByUsername`, and
notifies. See `social-sharing.md`.

## Tests

- `SellerComparisonTests` — the save-time fan-out's effect on a tracker: the
  pending marker's life (stamped, resumed, always cleared by a finished run, and
  deliberately NOT cleared by a process that cannot run one), per-seller
  streaming, the median (foreign-currency store attached but excluded from it),
  alerting-without-badging on the untouched path, the touched-threshold rule and
  its genuine alert, the per-retailer-family refusal, the new-tracker-only rule,
  the launch/refresh sweeps, the two-callers-one-run rendezvous, and the two
  indistinguishable no-op states (no runner installed / nothing found).
- `SellerComparisonDocumentTests` — the summary document's structure, led by
  self-containment (no `src="http`, no `<link`, no `<script`), the flat-series
  graph, and markup escaping.

- `ProductPageDetectorTests` — fixtures `LunaTests/Fixtures/Products/`
  (amazon JSON-LD, shopify OG, bestbuy microdata, generic `@graph`+AggregateOffer+EU
  price, article no-price negative, **bunnings-nextdata** heuristic+embedded-JSON;
  Tier-1 candidates assert `staticPrice`) + embedded-price `firstPrice` unit tests
  (NEXT_DATA value+currencyIso → 99 AUD, sellPrice shape, no-context rejection),
  URL-pattern matching, news-article negative (productish URL alone is below the ≥2
  threshold), + price/currency parsing. The Bunnings price is recovered via the
  **static** embedded-JSON path (no WebView). **Determinism**: detect+staticPrice over
  the Bunnings fixture is identical across 200 runs; `firstPrice` and JSON-LD product
  selection are order-stable when a tree has >1 price/Product node.
- `PriceFetcherTests` (4) — static embedded price uses prefetched HTML with **no
  WebView render**; structured price fetched when no prefetched HTML; **WebView
  render fallback recovers a JS-loaded price** (the static markup has none, the
  injected render returns the hydrated HTML); no price by any method → nil (article
  fallback). Uses `MockArticleFetcher` + an injected `renderHTML` closure (headless).
- `PriceTrackerTests` — best price, discount/alert, threshold, ≥1-store
  invariant, baseline immutability, Codable migration + clamp, stalest-first, plus the
  **alert-viewed transition**: a fresh drop is `hasUnviewedAlert`; `markAlertViewed`
  clears it while still alerting; a deeper drop re-opens it; `markAlertViewed` no-ops
  when not alerting; ack survives Codable round-trip; old payloads (no
  `alertAcknowledgedAt` key) decode as unviewed. Plus the **unset threshold**: a
  tracker without one never alerts (a 90% drop included) and has no
  `alertThresholdPrice`; setting one leaves the state and clamps; `clearAlertThreshold`
  returns to it; and unset encodes as an **absent key** (no sentinel) that round-trips.
- `PriceAlertThresholdPolicyTests` (7) — the seeding decision (`.notDetermined` → no
  threshold; asked → the 10% default) and the App-Group latch (starts clear, sticky,
  never un-latches on a revoked permission, resettable), over an injected
  `NotificationAuthorizationState.testDefaultsOverride` suite.
- `ProductMatcherTests` (8) — productID, fuzzy name+brand, brand block, unbranded,
  no-match, highest-score, + **order-independent tie-breaks** (equal name score and
  multiple id matches both resolve to the lowest id regardless of input order).
- `PriceRefresherTests` (5) — price update + newly-alerting, already-alerting,
  stalest-first order, failing fetch (`MockPriceFetcher` yields nil → unchanged),
  archived skip. Driven by `MockPriceFetcher` (prices keyed by URL).
- `PriceFormattingTests` (3) — currency string, threshold description percent+abs.
- `ReadingListSectioningTests` — price-tracking bucket, archived exclusion,
  unviewed-alert float-out + greatest-discount, **at-most-one float**, **viewed alert
  does NOT float** (and yields the top to a smaller-but-unviewed one), filter
  visibility, displayOrder (price-tracking below Reading; `.priceAlert` first). Plus
  `PriceTrackingScreenTests` (editor chrome): existing-mode **Back** pops;
  **extension host shows the floating exit circle, in-app shows Back** (and the
  circle stays a circle, clear of the seller list); opening an alerting tracker
  **marks the alert viewed**; the waiting row appears and goes with the pending
  marker; and the **no-alert-set** state — the graph's "Set price alert" pill
  (with the line handle hidden) and the alert row's button each commit the
  default threshold to the store, while a tracker that HAS one shows neither.
- `ProductSurfaceTests` — `ProductTitleSummaryTests` over the marketplace title,
  model codes, separators/brackets/commas, the short name that draws no duplicate
  line, the three-long-words fallback and the degenerate inputs; plus
  `ProductSurfaceParityTests`, which is the refactor itself: the card and the
  extension-hosted editor both HOST a `ProductDetailViewController` (rather than
  each building a rendition of one), and the alert row's slider and the graph's
  line show the same threshold, live, before anything is persisted.
- `ProductSearchURLTests` (7) — Google Shopping URL encoding (`+` spaces, escaped
  `&`/`#`, empty → nil) + URL-bar navigation target (scheme → load, bare domain →
  https, free text → Google search, empty → nil).
- `PriceTrackingExitContextTests` (6) — left button per host (in-app Back / extension
  Done) + "Read instead" per entry (creation→discard, merge→revert-exact-URL,
  existing→hidden regardless of host).
- `PriceTrackerTests` add-seller: reverting exactly the added seller leaves the rest
  intact (merge-revert), `hasStore` dedupe (no duplicate row / refetch).
- `MessageEnvelopeTests` — priceTracker round-trip + recreate, no-URL → unknown.
