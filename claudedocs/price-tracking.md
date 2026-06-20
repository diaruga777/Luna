# Price Tracking

When a saved/pasted URL is a **product page with a price**, Clip treats the save
as a **price tracker** instead of an article: it watches the product's price
across one or more store URLs and alerts the user (local notification + a red
top-of-list badge) when the price drops past a threshold.

## Key files

- `ReaderKit/ProductPageDetector.swift` — **pure** detection (`ProductInfo`). Given
  URL + HTML returns an optional `ProductInfo { name, priceAmount: Decimal,
  priceCurrency, imageURL?, brand?, productID? }`. Signals, trust order: (1) JSON-LD
  `Product`/`Offer` (`offers.price`/`priceCurrency`, recursing `@graph`/arrays and
  `AggregateOffer.offers`/`lowPrice`/`priceSpecification`); (2) OpenGraph
  `product:price:amount`/`og:price:amount` + currency; (3) schema.org microdata
  (`itemprop=price`/`priceCurrency`); (4) bare price meta. `parsePrice` tolerates
  `$1,234.56` (US) and `1.234,56`/`23,50 €` (EU); `normalizeCurrency` maps `$£€¥` →
  ISO codes. `productID` from gtin13/12/14/8/gtin/isbn/mpn/sku/productID. Reuses the
  article extractor's recursive JSON-LD walk pattern.
- `ReaderKit/PriceTracker.swift` — the model + the friend-share payload:
  - `PriceTrackerStore { urlString, lastPrice: Decimal?, currency, lastRefreshed: Date? }`.
  - `PriceTracker` — `productName`, `stores` (private(set), **always ≥1**), `brand?`,
    `productID?`, `imageFileName?`, `initialPrice` (best at creation = alert
    baseline), `initialCurrency`, `alertThresholdFraction` (default 0.10),
    `isArchived`. Computed: `currentBestPrice` (min across fetched store prices,
    else `initialPrice`), `displayCurrency`, `discountFraction`, `isAlerting`
    (`!isArchived && discount ≥ threshold`), `thresholdAbsoluteDrop`. Mutators:
    `upsertStore`, `removeStore` (no-ops on the last store → ≥1 invariant),
    `setPrice`. **Migration-safe** `Codable` (all fields defaulted; empty `stores`
    repaired; threshold clamped 0.01…0.95). Merging a cheaper store does NOT lower
    `initialPrice` (the baseline is fixed at creation).
  - `PriceTrackerShare` — portable friend-share form (URLs + best price at share
    time + threshold + brand/productID); `makeTracker()` rebuilds on receipt.
- `ReaderKit/ProductMatcher.swift` — **pure** same-product matching: (1) normalized
  `productID` equality wins; (2) else fuzzy token-Jaccard name similarity ≥ 0.6 with
  compatible brand (equal, or one side unbranded). Stop-words stripped.
- `ReaderKit/PriceRefresher.swift` — **pure-ish** background-refresh logic.
  `PriceTrackerPersisting` seam (`ReadingListStore` conforms); injects
  `HTMLFetching` + `ProductPageDetector` + a clock. `refreshAll()` processes
  trackers **stalest-first**, re-fetches each store, updates prices, persists each
  tracker as it finishes (resumable), and returns `PriceRefreshOutcome` per tracker
  with `newlyAlerting` (crossed threshold THIS run = the notification trigger).
- `ReaderKit/PriceFormatting.swift` — **pure** currency string (`$45.99`, `€23.50`,
  `AUD 89.00`) and `thresholdDescription` ("10% off — alert below $90.00").
- `Clip/ReadingList/PriceTrackingManager.swift` — `PriceTrackingManaging`
  (`detectProduct(urlString:)`); live impl = `ArticleFetcher` + detector.
- `Clip/ReadingList/PriceTrackingViewController.swift` — the tracker editor (main
  app). `Mode.existing(itemID:)` (tap a row) or `.creation(itemID:isMerge:highlightedURL:)`
  (save-time). Insets table of store rows (each shows extracted price; tap → in-app
  Safari; swipe → remove, guarded by ≥1), a **+** add-store button (fetch+extract a
  new URL's price), and a bottom alert-config (threshold slider shown as percent AND
  absolute price). `.creation` adds a **Cancel** that deletes the tracker and
  re-saves the URL as a normal article (`handleSavePress`). Declares
  `Notification.Name.priceTrackerSavedInteractively`.
- `Clip/ReadingList/PriceRefreshCoordinator.swift` — main-app side effects: runs
  `PriceRefresher` over the shared store and posts `NotificationManager.postPriceDrop`
  per `newlyAlerting` outcome.

## Reading-list integration (`ReadingListSectioning` / `ReadingListViewController`)

- New `Section.priceTracking` (raw 5, non-collapsible) sits between `.pasteboard`
  and `.reading` in `displayOrder`. New `ListFilter.priceTrackers` (raw 3).
- `rendersAsReader` is false for trackers; `ListFilter.mediaAndLinks` excludes them.
- `assignSections` returns a 4th `priceTracking` bucket (non-archived trackers;
  archived ones drop out of ALL buckets and the background refresh).
- `topAlertingPriceTracker(items:)` — the single alerting tracker (greatest
  discount, ties by id) floats to the **top** of the whole list (inserted at row 0
  of the price-tracking section by the VC), badged **red**.
- `shouldShowFilter` = ≥2 of {reader, media/link, price-tracker} kinds present.
  `hasPriceTrackers` gates the Price segment. The VC rebuilds the segmented control
  dynamically from `visibleFilters()` (index ↔ filter map, not raw-value coupling).
- Tracker rows render via `configurePriceTrackerCell`: product image thumbnail (or a
  `tag`/`tag.fill` glyph), title = product name, subtitle = current best price
  (currency-formatted), `↓N%` in red when alerting. Tapping a row → `open` →
  `PriceTrackingViewController(itemID:)`.
- `ReadingListStore`: `savePriceTracker`, `updatePriceTracker`,
  `priceTrackersStalestFirst()` + `stalestRefresh(_:)`.

## Save-time UX

- **In-app paste / manual / app-intent**: `ReadingListIngestor.ingest` fetches once
  and runs `ProductPageDetector` after the YouTube/platform checks, before the
  article resolve. On a hit → `ingestProductTracker` (intelligent merge via
  `ProductMatcher`, else new tracker; downloads the product image), then posts
  `.priceTrackerSavedInteractively`. The reading list presents the `.creation`
  editor (top-of-stack only). Merge highlights the new row.
- **Share / action extension** (`ShareKit/ShareViewController.ingestArticleThenComplete`):
  detects the product and saves the tracker **silently** (extensions can't present
  the main-app editor); the user edits it in the app.

## Background refresh (`AppDelegate`)

`BGProcessingTaskRequest` id `com.hpiddy.clip.priceRefresh` (~every 12h, needs
network), registered + scheduled alongside the existing inbox/mail tasks; the
identifier is in `Info.plist` `BGTaskSchedulerPermittedIdentifiers`. Handler →
`PriceRefreshCoordinator.refreshAndNotify`. Resumable: stalest-first + per-tracker
persistence, so a cancelled run still advances the oldest trackers. Archived
trackers are skipped.

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

- `ProductPageDetectorTests` (11) — fixtures `ClipTests/Fixtures/Products/`
  (amazon JSON-LD, shopify OG, bestbuy microdata, generic `@graph`+AggregateOffer+EU
  price, article no-price negative) + price/currency parsing.
- `PriceTrackerTests` (14) — best price, discount/alert, threshold, ≥1-store
  invariant, baseline immutability, Codable migration + clamp, stalest-first.
- `ProductMatcherTests` (6) — productID, fuzzy name+brand, brand block, unbranded,
  no-match, highest-score.
- `PriceRefresherTests` (5) — price update + newly-alerting, already-alerting,
  stalest-first order, failing fetch, archived skip.
- `PriceFormattingTests` (3) — currency string, threshold description percent+abs.
- `ReadingListSectioningTests` — price-tracking bucket, archived exclusion, alerting
  float-out + greatest-discount, filter visibility, displayOrder.
- `MessageEnvelopeTests` — priceTracker round-trip + recreate, no-URL → unknown.
