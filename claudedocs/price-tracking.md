# Price Tracking

When a saved/pasted URL is a **product page with a price**, Clip treats the save
as a **price tracker** instead of an article: it watches the product's price
across one or more store URLs and alerts the user (local notification + a red
top-of-list badge) when the price drops past a threshold.

## Key files

**The price is MANDATORY.** A tracker is only ever created from a real numeric
price + currency, fetched up front (and re-fetched on every background cycle).
There is no pending/unknown/nil price state. Detection identifies a product
*candidate*; the `PriceFetcher` resolves the price; only a candidate with a real
fetched price becomes a tracker — otherwise the page is saved as a plain article.

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
    markup (Tier 1 structured data → Tier 2 embedded JSON), independent of product
    detection; the `PriceFetcher` calls it for its fast, no-WebView paths.
  - **`priceFromEmbeddedJSON`** scans `__NEXT_DATA__`, every
    `<script type=application/json>`, and inline `window.__…={…}` blobs
    (`firstJSONObjectLiteral` balanced-brace extractor). `firstPrice(in:)` recurses
    JSON **in sorted-key order** (Swift dictionary iteration is hash-seed randomized
    per process — sorted traversal keeps a tree with >1 price node resolving to the
    same price every launch) for the first object carrying a price-context key (`priceAvailable`/
    `priceType`/`priceCurrency`/`currencyIso`/`currencyCode`/`sellPrice`/`nowPrice`/
    `salePrice`/`formattedValue`), a numeric value (`value`/`amount`/`*price`, or a
    `formattedValue` like `"$99.00"`), and a currency (sibling currency key, or a
    `formattedValue` symbol). Bunnings fixture → **99 AUD** (`{currencyIso:"AUD",
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
  main app and the UI-hosting action/share extension.
- `ProductInfo { name, priceAmount: Decimal, priceCurrency, imageURL?, brand?,
  productID? }` (in `ProductPageDetector.swift`) — a candidate paired with a fetched
  price, built via `ProductInfo(candidate:price:)`. The price is **required**; a
  `ProductInfo` only exists once a real price is in hand, so a tracker can never be
  created without one.
- `ReaderKit/PriceTracker.swift` — the model + the friend-share payload:
  - `PriceTrackerStore { urlString, lastPrice: Decimal?, currency, lastRefreshed: Date? }`.
  - `PriceTracker` — `productName`, `stores` (private(set), **always ≥1**), `brand?`,
    `productID?`, `imageFileName?`, `initialPrice` (best at creation = alert
    baseline), `initialCurrency`, `alertThresholdFraction` (default 0.10),
    `isArchived`, `alertAcknowledgedAt: Date?` (nil = the current alert, if any, is
    still UNVIEWED). **`init(price:)` takes a required `Decimal`** — a tracker cannot
    exist without a real numeric price (the `PriceFetcher` resolves it before the
    tracker is created). Computed: `currentBestPrice` (min across fetched store
    prices, else `initialPrice`), `displayCurrency`, `discountFraction`, `isAlerting`
    (`!isArchived && discount ≥ threshold`), **`hasUnviewedAlert`**
    (`isAlerting && alertAcknowledgedAt == nil` — the condition that floats the row to
    the very top of the whole list), `thresholdAbsoluteDrop`. Mutators: `upsertStore`,
    `removeStore` (no-ops on the last store → ≥1 invariant), `setPrice` (a strictly
    lower price for a store clears `alertAcknowledgedAt` so a fresh drop re-floats),
    **`markAlertViewed(at:)`** (sets `alertAcknowledgedAt`; no-ops when not alerting —
    called when the user opens an alerting tracker). **Migration-safe** `Codable` (all
    fields defaulted; `alertAcknowledgedAt` absent in old payloads → nil → unviewed;
    empty `stores` repaired; threshold clamped 0.01…0.95). Merging a cheaper store
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
- `Clip/ReadingList/PriceTrackingManager.swift` — `PriceTrackingManaging`
  (`fetchPrice(urlString:) -> ProductPrice?`); live impl wraps `PriceFetcher` so the
  add-a-store UI resolves a new URL's price with the same strategy.
- `Clip/ReadingList/PriceTrackingViewController.swift` — the tracker editor (main
  app), always PUSHED onto the reading-list nav stack. `Mode.existing(itemID:)` (tap a
  row) or `.creation(itemID:isMerge:highlightedURL:)` (save-time). Insets table of
  store rows (each shows extracted price; tap → in-app Safari; swipe → remove, guarded
  by ≥1), a **+** add-store button (fetch+extract a new URL's price), and a bottom
  alert-config (threshold slider shown as percent AND absolute price).
  - **Exit (always available):** `.existing` shows a left **Done**; `.creation` shows
    a left **Cancel** that deletes the tracker and re-saves the URL as a normal article
    (`handleSavePress`). Both route through `dismissOrPop()` — pop when pushed (the
    real case), else dismiss. **Cancel-was-a-no-op root cause:** the old
    `dismissOrPop` only popped when `presentingViewController == nil`; if the
    reading-list nav was itself presented modally that was non-nil, so it fell to
    `dismiss(animated:)` (dismissing the whole stack / doing nothing) instead of
    popping the single VC. It now keys purely on "am I the nav root?", so pop vs
    dismiss is correct regardless of whether the nav is presented.
  - Declares `Notification.Name.priceTrackerSavedInteractively`.
- `Clip/ReadingList/PriceRefreshCoordinator.swift` — main-app side effects: runs
  `PriceRefresher` over the shared store and posts `NotificationManager.postPriceDrop`
  per `newlyAlerting` outcome.

## Reading-list integration (`ReadingListSectioning` / `ReadingListViewController`)

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
  `markAlertViewed` is called (in `ReadingListViewController.open`), `hasUnviewedAlert`
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
  runs `ProductPageDetector` after the YouTube/platform checks (**before** the
  article resolve), then `PriceFetcher.fetchPrice` on a candidate. On a real price →
  `ProductInfo(candidate:price:)` → `ingestProductTracker` (intelligent merge via
  `ProductMatcher`, else new tracker; downloads the product image), then posts
  `.priceTrackerSavedInteractively`; the reading list presents the `.creation` editor
  (top-of-stack only; merge highlights the new row). No fetchable price → records a
  note and falls through to `ArticleResolver`.
- **Share / action extension** (`ShareKit/ShareViewController.ingestArticleThenComplete`):
  runs `ProductPageDetector` then `PriceFetcher` on the fetched HTML **before**
  `ArticleResolver.resolve`; on a real price saves the tracker **silently**
  (extensions can't present the main-app editor); the user edits it in the app. This
  is why the action extension never paywall-bypasses a product page. No fetchable
  price → article path.

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

## Background refresh (`AppDelegate`)

`BGProcessingTaskRequest` id `com.hpiddy.clip.priceRefresh` (~every 12h, needs
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

## Replay compatibility (`replays.md`)

A tracker save is Replay-compatible: `ingest` records a `note("product detected:
…")`, a per-URL price fetch as `networkRequest`/`networkResponse` (via the wrapping
`RecordingHTMLFetcher`), the product image as a `mediaReference` (URL only),
`note("created price tracker"` | `"merged into existing tracker <id>")`, and
terminates `.success`. `ReplayPlayer` rejects these as `unsupportedSource` (product
notes), like youtube/platform/document saves.

## Tests

- `ProductPageDetectorTests` (18) — fixtures `ClipTests/Fixtures/Products/`
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
- `PriceTrackerTests` (20) — best price, discount/alert, threshold, ≥1-store
  invariant, baseline immutability, Codable migration + clamp, stalest-first, plus the
  **alert-viewed transition**: a fresh drop is `hasUnviewedAlert`; `markAlertViewed`
  clears it while still alerting; a deeper drop re-opens it; `markAlertViewed` no-ops
  when not alerting; ack survives Codable round-trip; old payloads (no key) decode as
  unviewed.
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
  `CatchUpAndPriceScreenTests`: existing-mode **Done** pops, creation-mode **Cancel**
  removes the tracker + pops, opening an alerting tracker **marks the alert viewed**.
- `MessageEnvelopeTests` — priceTracker round-trip + recreate, no-URL → unknown.
