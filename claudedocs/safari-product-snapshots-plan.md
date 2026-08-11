# Plan: passive product snapshots, Safari bounce-back saves, and the "Was $X" history pill

Three features over the Safari extension + price-tracking + media-download stack. Commit this
file as `claudedocs/safari-product-snapshots-plan.md` in your first commit and keep it updated
if implementation diverges.

## Context (verified against the tree, 2026-08-07)

- The Safari extension (`LunaSafari/`, one source built per host app) classifies pages and shows
  a deep-link pill. Native handler: `LunaSafari/SafariWebExtensionHandler.swift` (106 lines),
  message types `buttonContext`/`buttonMode`, `setupCelebrationShown`, `bypassEnabled`,
  `saveContent`, default URL record. Per-app support flags derived from bundle-id suffix
  (`hostHandlesProducts` = central `luna` or `.pricetracker`; `hostHandlesMedia` = central or
  `.downloader`). All persistence today is App Group `UserDefaults` via
  `LunaSafari/SharedSafariURL.swift` — the extension links NO package (deliberate; mirrored
  constants + parity tests are the established pattern, see `SafariSetupCelebrationTests`).
- `LunaSafari/Resources/content.js` (1609 lines): routing in `offerLunaButton` (:116-154);
  product branch at :139-143 → `trackTargetFor` (:1253) → `injectLunaButton` (:1175). Product
  classifier `looksLikeProductPage` (:859) + helpers (`findProductNodeWithPrice` :928,
  `offerPrice` :958, `hasMicrodataPrice` :984, `metaContent` :1047), driven by generated
  `product_rules.generated.js`. Deep-link built in `ownSchemeTarget` (:1228):
  `scheme + "://read?url=" + encodeURIComponent(sourceURL)`. The ONE existing page-data→native
  message is `{type:"saveContent", url, html}` (:1214, gated on `captureContent`, ≤1.5MB).
  `background.js` relays each message type explicitly (:80-122) — new types must be added there.
- Price model: `PriceTracker` (LunaModels/PriceTracker.swift) with `stores: [PriceTrackerStore]`
  (≥1 invariant, identity = `urlString`); **history is per-store**:
  `PriceTrackerStore.priceHistory: [PriceDaySnapshot]` (dayStart, lowestPrice, currency,
  fxRate?), day-bucketed lowest, oldest-first, appended ONLY by
  `PriceTracker.recordPriceSample` (:324), whose only production caller is
  `PriceRefresher.refresh` (LunaPriceUI/PriceRefresher.swift:104, private per-tracker method
  inside public `refreshAll`). A new tracker has ZERO graph points until first refresh.
  Graph: `PriceGraphView.setData([PriceGraphPoint]…)`; series derived by
  `PriceHistory.series(for:)` (LunaModels/PriceHistory.swift:70). Matching:
  `ProductMatcher.bestMatch(for:among:)` (LunaHTMLClassification/ProductMatcher.swift:28) —
  normalized-ID equality then brand-compatible token-Jaccard ≥ 0.6; helpers `normalizedID`,
  `brandsCompatible`, `nameSimilarity` are public. `productID` extraction reads
  `gtin13/12/14/8/gtin/isbn/mpn/sku/productID` (JSON-LD, ProductPageDetector.swift:713) and the
  same itemprops (:745) into ONE raw string.
- Deep-link path: `SceneDelegate.route` (:134-154) → `LunaDeepLink.articleURL(from:)`
  (LunaURLClassification/LunaDeepLink.swift:65 — extracts the `url` query item by name, so
  EXTRA query params parse harmlessly) → `openReader(articleURL:)` (:158-200) →
  `ReadingListIngestor.shared.handleSavePress` (source defaults `.manual`) → kind dispatch in
  `IngestorOutcomePresenter.present`. Media leg: `PlatformItemIngestor` (LunaPlatforms:53-60) →
  in Downloader/central, `LiveMediaDownloadManager.shared.start(...)` which requests the Live
  Activity (`LiveMediaDownloadManager+ActivityKit.swift:64`). Product leg:
  `ProductTrackerIngestor.ingest` (LunaPriceUI:27-82; merge branch :31-56, new-tracker :59-81),
  user lands on the product deck card (no pushed editor).
- Live Activity: `LunaDownloaderLiveActivityWidget.swift` (one source, two host-prefixed widget
  targets: `LunaLiveActivity` + `LunaDownloaderLiveActivity`). Has
  `SuspendLiveMediaDownloadIntent` (labeled Cancel; suspend → auto-teardown after a 5s grace
  via `reapExpiredSuspensions`) + `ResumeLiveMediaDownloadIntent`. **No `widgetURL` anywhere**;
  finished state has no button and auto-dismisses after 20s (`endActivity` default delay).
  `ContentState`: phase/progress/mediaKind/message/thumbnailFileName/actionURLString/
  suspendDeadline. `actionURLString` is only used for the Photos-permission failure `Link`.
- The widget targets do NOT use synchronized groups — adding a file to them means explicit
  build-file entries. And deleting any file carried by a membership exception means editing
  `project.pbxproj` (verify from an EMPTY derivedData).
- Existing "open in Photos" precedent: the media card's Photos rosette
  (`Luna/Downloader/MediaCardFactory.swift:131-133`, `MediaCardPresenter.swift:391`) — reuse
  its mechanism for any "view in Photos" behavior; do not invent a new scheme.

---

## Feature 1 — Passive product snapshots

**Behavior.** Every time the Price Tracker or central Luna app's Safari extension classifies a
page as a product (the same condition that would offer the Track pill, but independent of the
pill suggestion mode — snapshots are passive, local-only data), it persists a snapshot:
`{name, price, currency, canonicalURL, host, identifiers, brand, date}`. Snapshots are NOT
saves: no reading-list row, no background refresh, no alerts. They exist only to (a) seed a
tracker's history/seller list when the user later saves that product, and (b) power the
Feature-3 history pill.

### 1a. Extraction (content.js)

New function `extractProductSnapshot()` next to `looksLikeProductPage()`:
- **name**: JSON-LD Product `name` → `og:title` → `document.title` (trimmed).
- **price + currency**: extend the existing tier-1 helpers to return currency, not just detect:
  JSON-LD offer `price`+`priceCurrency` (reuse `findProductNodeWithPrice`/`offerPrice` shapes),
  OG `product:price:amount` + `product:price:currency` (also `og:price:*`), microdata
  `itemprop=price` + `itemprop=priceCurrency`. No heuristic/rendered-DOM tier: **no structured
  price ⇒ no snapshot** (mirrors "the price is mandatory").
- **identifiers** (keyed object, all optional): from JSON-LD product+offer nodes and microdata:
  `gtin` (first of gtin13/gtin12/gtin14/gtin8/gtin/isbn), `mpn`, `sku`, `productID`; `brand`
  (JSON-LD brand name / `og:brand`); `retailerItemID` from OG `product:retailer_item_id` or
  URL-derived: Amazon ASIN (`/dp/<id>`, `/gp/product/<id>`), eBay `/itm/<id>`, Walmart
  `/ip/…/<id>`, Target `/p/…/-/A-<id>`.
- **canonicalURL**: `link[rel=canonical]` if same-host, else `location.href`; strip known
  tracking params (`srsltid`, `gclid`, `utm_*`, `ref`, `tag` on amazon) — mirror what
  `GoogleShoppingProductParser` already strips where applicable.
- Expose as `window.__lunaExtractProductSnapshot` for the WKWebView test harness.

In the product branch of `offerLunaButton` (and in the already-tracked case of Feature 3),
when `context.supportsProducts` and extraction yields a price, send
`{type:"productSnapshot", snapshot}` (relay it in background.js). Fire once per page load
(guard like the pill), and also from the SPA retry path if the product branch runs there.

### 1b. Persistence (native handler, package-free)

New `LunaSafari/SharedProductSnapshots.swift` (sibling of `SharedSafariURL`, plain Foundation +
`SafariAppGroup.id`): a JSON **file** in the App Group container (snapshots are too big for
UserDefaults hygiene), e.g. `Library/ProductSnapshots/productSnapshots.json` under
`FileManager.containerURL(forSecurityApplicationGroupIdentifier:)`.

- Record shape (Codable, keys are a wire format — document them):
  `{name, price: String (decimal), currency, url, host, day: String (yyyy-MM-dd, UTC),
  capturedAt: ISO8601, gtin?, mpn?, sku?, productID?, retailerItemID?, brand?}`.
- **Dedupe**: one record per (canonical url, day); a same-day revisit overwrites price/date.
- **Prune on write**: drop records older than 365 days; cap total at 2000, oldest-first eviction.
- Atomic write (`.atomic`); read-modify-write per message. Handler validates: http(s) URL,
  price parses as a positive decimal, non-empty name; silently drops invalid payloads.
- Handler gates on `hostHandlesProducts`.

App side: `ProductSnapshotStore` in **LunaPriceUI** (or LunaPriceIngest — implementer's choice,
but it must live in a product-kind module so only product-linking targets compile it) that
reads the SAME file with its own mirrored constants (the `SharedSafariURL`/`SafariURLStore`
duplication pattern). Add a parity test pinning path + key names between the two copies
(follow `SafariSetupCelebrationTests`' approach to testing the LunaSafari-target copy).

### 1c. Save-time matching + seeding

In `ProductTrackerIngestor.ingest`, in BOTH branches (new tracker and merge), after the tracker
exists and before persisting the final state:

1. Load snapshots. Match against the saved `ProductInfo` with a new pure
   `SnapshotMatcher` (LunaHTMLClassification, next to `ProductMatcher`), precedence:
   1. **GTIN/ISBN equality** (normalize: uppercase alphanumerics, then zero-pad numeric GTINs
      to 14 digits for comparison) — valid cross-host.
   2. **retailerItemID equality, same retailer family** (compare against the tracker/candidate
      URL host suffix — an ASIN only matches amazon.* hosts, etc.). The tracker side's raw
      `productID` string participates: compare `ProductMatcher.normalizedID` of every snapshot
      identifier against the candidate's normalized `productID` too.
   3. **mpn + compatible brand** (`ProductMatcher.brandsCompatible`).
   4. **sku equality, same host only.**
   5. **canonical URL equality** (candidate URL and every existing store URL, tracking params
      stripped both sides).
   6. **fuzzy name**: `ProductMatcher.nameSimilarity ≥ 0.6` AND `brandsCompatible`.
   Reuse the public `ProductMatcher` helpers; keep it order-stable/deterministic (sort
   candidate snapshots by day then url before folding).
2. Group matched snapshots by **host**. For each host:
   - If the tracker already has a store whose URL host matches → merge points into THAT
     store's `priceHistory` (no second store for the same host — this is the "deduped by url
     host" requirement).
   - Else `upsertStore(PriceTrackerStore(urlString: <newest snapshot's url for that host>,
     lastPrice: nil, currency: snapshot currency, lastRefreshed: nil, priceHistory: <points>))`.
   Add a `PriceTracker`/`PriceTrackerStore` API for history merging (e.g.
   `mergeHistorySamples(_:)`) that keeps the invariants: day-bucketed (one `PriceDaySnapshot`
   per day, LOWEST price wins on collision), oldest-first sorted, currency carried per point.
   Never touch `initialPrice`.
3. Persist (`store.updatePriceTracker` / `savePriceTracker` as the branch already does).
4. **Immediate refresh**: expose a public single-tracker refresh —
   `PriceRefresher.refreshTracker(_:itemID:)` (widen the existing private `refresh`, same
   outcome type) plus a convenience on `PriceRefreshCoordinator` (e.g.
   `refreshTracker(itemID:)` that skips drop notifications or reuses `refreshAndNotify`
   semantics for just that tracker — keep notification behavior identical to a background
   cycle for consistency). Call it fire-and-forget from the ingest path AFTER persisting,
   wrapped in `UIApplication.beginBackgroundTask` (Feature 2 may background the app
   immediately; the static-path fetch then still completes. The WKWebView render tier won't
   run in background — acceptable: the next BG cycle heals it).

Snapshots are never deleted by matching (they remain history for other products/the pill).

**Non-goals honored by construction:** nothing schedules snapshots into `PriceRefresher`
(`refreshAll` iterates trackers only) and no alert path sees them.

---

## Feature 2 — Bounce back to Safari after pill saves (media + product, NEVER articles)

### 2a. Deep-link flag

- content.js: in `downloadTargetFor` (:1243) and `trackTargetFor` (:1253) ONLY — not
  `readTarget`, not `ownSchemeTarget` itself — append `&ret=safari` to the built URL.
  Also flip `trackTargetFor` to `captureContent: true` so the tap posts `saveContent` with the
  rendered DOM: the app's product save then runs over prefetched, hydrated HTML
  (`SceneDelegate.openReader` already consumes `SafariContentStore.take(for:)`), which makes
  the save fast and lets client-rendered prices resolve without the WebView tier. (Keep the
  1.5MB guard.)
- `LunaDeepLink`: add `requestsReturnToSource(_ url: URL) -> Bool` reading the `ret` query
  item (value `safari`). Extend `LunaDeepLinkTests`: flag present/absent, and that
  `articleURL(from:)` is unaffected by the extra item.

### 2b. SceneDelegate behavior

In `route`/`openReader`: capture the flag; after `handleSavePress` returns, decide via a new
PURE helper (unit-testable, e.g. `SafariReturnPolicy.shouldReturn(result:kind:flagged:)`):

- Return to Safari ONLY when the flag is present AND the save outcome is a media or product
  kind AND the save was handled (persisted / already-saved dedupe / deferred-until-WiFi all
  count; a failed or unsupported save keeps the user in the app to see the error surface).
- **Media ordering**: the download start on this path is
  `PlatformItemIngestor` → `LiveMediaDownloadManager.start`, which requests the Live Activity
  while the app is still foreground — await the save call as `openReader` already does, then
  bounce. The transfer continues in the background URLSession; the Live Activity tracks it.
- **Product ordering**: persist + kick the single-tracker refresh (Feature 1c step 4, already
  under a background task), then bounce.
- The bounce itself: `UIApplication.shared.open(<original https URL>)` — the URL from the deep
  link, un-unwrapped (the page the user was on), NOT the `URLUnwrapper.ingestURL` result.
  Skip the `openExternally` deck-centering leg when bouncing (don't animate a deck the user
  won't see). Known/accepted limitations — note them in the doc: this opens the user's DEFAULT
  browser (Safari unless they changed it) and typically lands in a new tab rather than the
  originating one. There is no supported "return to previous app" API; do not use private
  schemes like `x-safari-https://`.
- Articles: `readTarget` never carries the flag; additionally the policy helper must return
  false for article kinds even if a flag sneaks in (defense in depth, tested).

### 2c. Live Activity: cancel + tap-to-view

Cancel already exists (`SuspendLiveMediaDownloadIntent` reads as Cancel; suspend hard-cancels
after the 5s grace unless resumed) — leave that mechanism alone.

New: make the activity tappable.
- Add `.widgetURL(...)` to both the lock-screen view (`DownloadActivityView`) and the Dynamic
  Island expanded region in `LunaDownloaderLiveActivityWidget.swift`, phase-dependent:
  - while running/suspended/failed: `<ownScheme>://media?url=<encoded sourceURLString>`
    (opening the app on the downloading card is correct and harmless);
  - `.finished`: same URL — the app decides where "view" goes (below). The scheme comes from
    the widget's own bundle (`LunaDeepLink.ownScheme` logic — the widget links LunaMediaDownload
    which links… verify; if `LunaDeepLink` isn't reachable from the widget target, put the
    prebuilt URL string into `ContentState` (a new `viewURLString` field set by
    `activityState(for:)` in LunaMediaDownload, which knows `ownScheme` — mirror how
    `actionURLString` is populated today) rather than adding a dependency.
- Keep the 20s finished-state dismissal EXACTLY as it is (do NOT extend it). Instead, on
  completion the activity must re-present prominently: `endActivity` already passes an
  `AlertConfiguration` on the final `.finished`/`.failed` update (:139-150) — verify it fires
  on the deep-link save path and that the alerting final state carries the tap URL, so within
  the 20s window a tap opens the media. If the alert isn't reaching the Lock Screen/Dynamic
  Island prominently on completion, fix the alert configuration rather than the dismissal
  policy.
- App side, new route branch in `SceneDelegate.route`: host `media` with a `url` item →
  look up the saved media row (`SavedMediaStore.matchingItem(forURLString:)`):
  - `.localFile` → pop to root, center the deck on that item and open it (the deck's existing
    open path; Downloader/central both root on the media deck — use the presenter/centering
    mechanism `ProductCardPresenter`-style code uses, i.e. `requestCentering(onItemID:)` +
    open).
  - `.photosReference` → **reuse the Photos-rosette open mechanism**
    (`MediaCardFactory.swift:131-133`): read that code and route the same way (it is the
    existing, shipped answer to "deep link to Photos"; if it only opens the Photos app rather
    than the exact asset, that is the accepted behavior — do NOT add undocumented schemes
    beyond what that code already uses). If for any reason it can't be reused, fall back to
    opening the item in-app.
  - still downloading / no row → land on the deck (current behavior).
- The widget targets are explicit-build-file targets: if any new Swift file must compile into
  them, add the build-file entries (both `LunaLiveActivity` and `LunaDownloaderLiveActivity`).
  Prefer changing only existing files there.
- New user-visible strings: none expected in the widget beyond existing keys; if any are
  added, they're `Localizable.strings` `_Luna`-suffixed entries + `scripts/strings_sync.py`
  and the app-bundle copy rule apply (`add_strings_to_app_bundles.rb` already covers the
  widget).

---

## Feature 3 — "Was $X on <date>" history pill

**Behavior.** On a product page in a product-handling host's extension, if historical data
(snapshots OR a saved tracker's history) matched by id / URL / fuzzy name shows a price
STRICTLY LOWER than the current page price **in the same currency**, show a second pill:
`Was $79.99 on 1/12/25` (localized price + short localized date).
- Not saved → history pill stacked ABOVE the Track pill (same style, fixed bottom-right,
  Track pill in its usual slot).
- Already saved → show ONLY the history pill (no Track pill). If saved but no lower historical
  price exists → no pills at all on this page.
- The history pill is informational — non-interactive (no click handler; keep pointer-events
  none so it never swallows page taps).

### 3a. The app-written history index

The handler can't read `readingList.json` (package-free, and the payload is huge). Instead the
APP maintains a compact `priceHistoryIndex.json` next to the snapshots file: per tracked
product: `{name, brand?, productID?, stores: [{url, host, points: [{day, price, currency}]}]}`.
- Writer in LunaPriceUI (`PriceHistoryIndexWriter`), regenerated (atomic, whole-file) after:
  `ProductTrackerIngestor.ingest` persists, each `PriceRefresher` run completes
  (`PriceRefreshCoordinator`), and the product apps' `KindWiring.appDidEnterBackground`.
  Only Luna + PriceTracker link LunaPriceUI, so only product apps ever write it — correct.
- Cap: points already day-bucketed; include at most the last 365 days per store.
- Presence of a matching product in this index IS the "already saved" answer.

### 3b. Handler query

New message `{type:"productHistory", snapshot}` (same extracted payload as Feature 1; content.js
sends ONE extraction through both messages, or the handler answers productHistory as part of
handling productSnapshot — implementer's choice, but keep one page-side extraction). Handler
(gated `hostHandlesProducts`):
1. Match the page's snapshot payload against (a) the history index (tracked products) and
   (b) the snapshot store, using a handler-local mirror of the matching precedence in
   Feature 1c (GTIN → retailer-id/host-family → mpn+brand → sku+host → canonical URL → fuzzy
   name with the same normalization + Jaccard-≥0.6 rule). This is a THIRD copy of matching
   logic (Swift appex), so: keep it in `SharedProductSnapshots.swift` (or a sibling
   `SharedProductMatching.swift`), and add a **parity test** in LunaTests running a fixture
   matrix through this copy and through `SnapshotMatcher`/`ProductMatcher`, the way
   `SafariIndexVetoParityTests` pins the JS/Swift veto pair.
2. Over all matched points (index + snapshots), find the LOWEST price strictly below the
   page's current price, **same currency only**; ties → earliest date. Reply
   `{hasHistory: true, amount, currency, day, isTracked}` or `{hasHistory: false, isTracked}`.

### 3c. Pill rendering (content.js)

- In the product branch: after extraction, send `productHistory`; render per the reply:
  `isTracked` → skip `injectLunaButton`, show only the history pill when `hasHistory`;
  else show Track pill and, when `hasHistory`, the history pill above it.
- Format: `Intl.NumberFormat(undefined, {style:"currency", currency})` for the price;
  `new Date(day)` → `toLocaleDateString(undefined, {day:"numeric", month:"numeric",
  year:"2-digit"})` for the date.
- Strings: add the label to `_locales/en/messages.json` AND `MESSAGE_DEFAULTS` with `{price}`
  and `{date}` tokens substituted in JS — **never `$`-style placeholder syntax** (a `$` with no
  `placeholders` dict segfaults WebContent; `SafariPillLabelTests.
  testNoLocalizedMessageCarriesPlaceholderSyntax` guards this — keep it passing).
- The SPA retry / reddit-style soft-nav paths must remove/re-evaluate BOTH pills.

---

## Feature 4 — the alternative-seller pill (added 2026-08-08, price-comparison B3)

A later feature reuses this one's whole apparatus, and the contract between them
is worth stating here rather than only in `claudedocs/safari-extension.md`:

- **The snapshot store gained a second writer.** The constrained fan-out
  (`LunaSafari/ComparableSellerFinder.swift`) records every seller page it
  verifies through `SharedProductSnapshots.record`, the same one write path the
  `productSnapshot` message uses — a fan-out result has exactly the Record shape
  (named product, price, currency, one retailer's URL, keyed identifiers). So
  Feature 1's dedupe-by-`(url, day)`, its 365-day/2000-record prune and Feature
  3's matching all apply to fetched prices with no change, and a price found for
  a seller pill becomes "Was $X" material on the next visit.
- **The matching tiers gained a second reader.** `SharedProductMatching.matches`
  answers "is this stored price about the page's product?" for both features;
  the freshness filter on top of it is Feature 4's alone.
- **Feature 3's rule is deliberately NOT Feature 4's.** The history pill accepts
  any matched point in the last 365 days, because it is a claim about the past.
  The seller pill accepts only points under 24h old, because it is a claim about
  now (`FreshComparablePrices`, LunaPriceCompare — which is where it lives so a
  test can execute it; the appex is not compiled into LunaTests, see the note in
  "Deviations" below).
- **They share one slot and never coexist.** `finishSellerLookup` either fills
  the seller pill or removes it and calls `renderProductPills` unchanged, so
  Feature 3's behaviour is the literal fallback rather than a re-implementation
  of it.
- **The soft-nav gap noted below still binds**, and now for three pills rather
  than two: if a product-page SPA retry is ever added, the seller pill and its
  one-shot flag need including in it.

---

## Identifier research summary (for the record, goes in the doc)

Matching strength order: GTIN family (gtin8/12/14, gtin13=EAN, UPC=gtin12; ISBN for books) is
globally unique and the only safe cross-retailer key — normalize to digits and zero-pad to 14.
Retailer item IDs (ASIN, eBay item, Walmart `/ip/`, Target TCIN, OG `product:retailer_item_id`)
are unique within one retailer family — match only when host families agree. MPN is
manufacturer-scoped — require compatible brand. SKU is retailer-scoped — require same host.
Then canonical URL, then fuzzy name (existing token-Jaccard ≥ 0.6 + brand compatibility).
Store them KEYED (never flattened) so the scope rules stay applicable; the tracker side's
legacy single `productID` string participates via `ProductMatcher.normalizedID` comparison
against every keyed value.

---

## Tests (new/updated — non-negotiable set)

1. `SharedProductSnapshots` round-trip, same-day overwrite, prune (age + cap), invalid-payload
   rejection; path/key parity with the app-side `ProductSnapshotStore`.
2. JS extraction parity: fixture HTML matrix (JSON-LD, OG, microdata, ASIN URL, no-price page)
   through `window.__lunaExtractProductSnapshot` in a bare WKWebView (use
   `SafariJSTestHarness`) vs Swift expectations — model on `ProductPageJSFixtureParityTests`.
3. `SnapshotMatcher`: each precedence tier, host-family scoping (ASIN doesn't match
   non-amazon), sku-same-host, brand-blocked fuzzy, determinism (input order shuffled).
4. Handler-copy matching parity vs `SnapshotMatcher` over the same matrix.
5. `ProductTrackerIngestor` seeding: matched snapshots → new store per new host, merged history
   into existing same-host store (host dedupe), day-bucket lowest-wins, `initialPrice`
   untouched, single-tracker refresh invoked (assert via `MockPriceFetcher` / a spy runner),
   graph series now non-empty at creation.
6. `PriceRefresher.refreshTracker` — refreshes exactly one tracker, records a sample,
   `newlyAlerting` semantics unchanged.
7. `LunaDeepLinkTests`: `ret=safari` parsing; `articleURL` unaffected.
8. `SafariReturnPolicy` (pure): flagged media/product handled → return; article → never;
   failed/unsupported → never; unflagged → never.
9. Live Activity: `activityState(for:)` populates the view URL (if the ContentState route is
   taken); finished dismissal delay; existing suspend/resume tests untouched.
10. `SafariPillLabelTests`: new message key has an inline default, no `$` placeholder syntax.
11. `PriceHistoryIndexWriter`: contents, 365-day trim, regeneration hooks.
12. History-pill decision (JS-side logic that picks lower-price-same-currency) — cover in the
    WKWebView harness with stubbed `browser.runtime.sendMessage` replies (the harness pattern
    content.js's `typeof browser` guards exist for).

## Workflow requirements (repo rules — follow exactly)

- Work in your own worktree off `main`; commit in small logical chunks as you go; merge into
  `main` when done and clean up the worktree/branch. **The
  `mkdir -p LunaLibraries/Tests/LunaURLClassificationTests` fresh-worktree
  workaround is no longer needed as of the August 2026 tree-shake, which deleted
  `LunaLibraries/Tests/` and all its `.testTarget` declarations entirely.**
- Compile-check per commit (`xcodebuild build-for-testing -scheme Luna -destination
  'generic/platform=iOS Simulator' DIAGNOSE_MISSING_TARGET_DEPENDENCIES=NO`), use
  `scripts/run_tests.sh --changed` only while iterating, and finish with ONE full
  `scripts/run_tests.sh --fresh` — read the `Executed N tests, with M failures` line, not the
  banner. Baseline: 0 failures; ~21 env-gated skips are expected.
- New extension resources/messages: remember `_locales` must not be flattened (the branding
  build phase handles it); manifest `description` stays ≤ ~112 chars; content.js must stay
  evaluable standalone (`typeof browser !== "undefined"` guards on every new `browser.*` call,
  and export new test hooks on `window.__luna*`).
- Kind-pack rule: no direct registry writes; anything per-kind stays in the kind's module.
  New public API in LunaLibraries needs `public` + explicit `public init`.
- Strings: extension copy lives in `messages.json` + `MESSAGE_DEFAULTS`; any in-APP strings go
  in `Localizable.strings` with `_Luna` fallback keys and `scripts/strings_sync.py --write`.
- Update `claudedocs/safari-extension.md`, `claudedocs/price-tracking.md`,
  `claudedocs/media-download.md` sections your changes touch, and commit this plan as
  `claudedocs/safari-product-snapshots-plan.md`.

## Deviations from this plan (recorded during implementation)

- **Feature 1c's identifier research** distinguishes GTIN cross-host matching from
  retailerItemID host-FAMILY matching. `SnapshotMatcher.hostFamilyMatches` approximates
  "family" as a registrable-domain compare (last two labels, or three for a short list of
  known compound suffixes — `co.uk`, `co.jp`, `co.nz`, `co.in`, `com.au`, `com.br`,
  `com.mx`, `com.tr`) rather than a full public-suffix-list implementation. This correctly
  separates `amazon.com`/`smile.amazon.com` from `amazon.co.jp`, which is the case that
  matters (an ASIN is not guaranteed to carry across separate national storefronts), but
  is not exhaustive against every real-world compound TLD.
- **Testing `LunaSafari`'s package-free Swift copies** (`SharedProductSnapshots.swift`,
  `SharedProductMatching.swift`) follows the codebase's EXISTING convention for this exact
  situation (`SafariSetupCelebrationTests` vs. `SharedSafariURL`): pinning literal
  constants/keys/behavior markers against the extension's SOURCE TEXT, rather than adding
  dual Sources-phase membership so `LunaTests` could compile and execute those files
  directly. The latter is achievable (the widget targets show the pattern for
  cross-target shared build-file references) but is exactly the kind of `project.pbxproj`
  surgery this repo's own guidance calls fragile, and no existing test does it. Net effect:
  `SharedProductSnapshotsTests` executes the REAL validation/prune logic through the
  app-side `ProductSnapshotStore` (identical Swift to the extension's copy) and pins the
  extension's literal constants against it; `SharedProductMatchingParityTests` runs the
  fixture matrix through the real `SnapshotMatcher`/`ProductMatcher` and pins the
  extension's copy structurally (same tier markers, same thresholds, same stop-word/
  tracking-param literals) rather than executing it. This is a real (documented) gap
  relative to "runs a fixture matrix through this copy" read literally.
- **Feature 3's plan item 12** ("JS-side logic that picks lower-price-same-currency
  price") is tested as the JS-side RENDER decision (`renderProductPills`, driven via the
  new `window.__lunaRenderProductPills` hook with a stubbed reply), not a price
  computation — per section 3b, the lowest-price-same-currency computation itself is
  native (`SharedProductMatching.historyAnswer`), which `ProductHistoryPillRenderTests`
  does not re-verify (that's `SharedProductMatchingParityTests`'s job). No test stubs
  `browser.runtime.sendMessage` itself: no existing LunaSafari test does, and the exposed
  hook exercises the identical downstream code path.
- **No SPA/soft-nav retry currently reaches the product branch** of `offerLunaButton`
  (only the article and Reddit branches retry today), so Feature 1a's "also from the SPA
  retry path if the product branch runs there" and Feature 3c's "remove/re-evaluate BOTH
  pills on soft-nav" don't currently bind — there is nothing to wire up. If a product-page
  soft-nav retry is added later, both pills need including in it.
- **Feature 2c's "open" for a `.localFile` media item is centering the deck**
  (`requestCentering`/`ExternalItemOpening`), not a second push into a fullscreen player:
  reading `MediaCardPresenter`, a downloaded media save plays INLINE on its own card once
  centered/visible (there is no separate "open the player" push for media the way an
  article pushes into the reader) — `MediaCardPresenter.openExternally(_:host:)` is a
  DIFFERENT thing (the "no local file yet" ladder: native app / embed / in-app browser for
  the SOURCE platform link). Centering is therefore the correct and complete "open" for
  this kind.
- **No dedicated test for `KindWiring.mediaDeepLinkAction`**: its only state source is the
  real `SavedMediaStore.shared` (App-Group-backed, shared across the whole test run), and
  it takes no injectable seam — the risk of cross-test pollution from seeding real saved-
  media rows outweighed adding one for this pass. Coverage is indirect: `LunaDeepLinkTests`
  covers the URL round trip, `LiveMediaDownloadJobTests`/existing suites cover
  `SavedMediaItem.storageState`, and the routing was reviewed by hand.
- **The Live Activity finished-state dismissal window was, per an explicit correction
  mid-task, left at its existing 20s default** — an earlier draft of this plan asked for
  15 minutes; that instruction was revoked. Tap-to-view rides the alert `endActivity`
  already sends on the final `.finished`/`.failed` update instead. See
  `claudedocs/media-download.md`.
  **SUPERSEDED (2026-08-11).** That window turned out to be beside the point: a
  dismissal policy only governs the Lock Screen's after-end banner, so ending the
  activity right after the `.finished` update dismissed the LIVE presentation
  instantly and the completed state was never seen at all. The finished card now
  gets a real five-second live hold (`finishedLiveHold`) before an `.immediate`
  end, and carries Play/Share links. `claudedocs/media-download.md` is the
  description; the 20s default survives only on the FAILURE paths.
