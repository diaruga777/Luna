# Price History Graph Plan (nextcommands #5)

Store every refreshed price bucketed by calendar day (lowest per day), and show an
adaptive price-over-time graph in the price-tracker detail view.

## Storage (migration-safe)
- `PriceDaySnapshot { dayStart, lowestPrice, currency, fxRate? }` (ReaderKit).
- `PriceTrackerStore.priceHistory: [PriceDaySnapshot]` (oldest-first).
- **Migration**: `PriceTrackerStore` gets a custom `init(from:)` that
  `decodeIfPresent`s `priceHistory ?? []` — synthesized Decodable does NOT default
  missing keys (it throws `keyNotFound`), so this is required for old saves to load.
- `PriceTrackerStore.recordSample(price:currency:at:)`: append a new day or lower the
  existing day's minimum (bucket by `Calendar.startOfDay`). Pure.
- Wired in `PriceRefresher.refresh` on the SUCCESS branch only (via
  `PriceTracker.recordPriceSample`) — failed fetches don't record.

## Aggregation (`PriceHistory`, pure, tested)
- `series(for:)`: per-day lowest ACROSS stores → if the overall span is small keep
  daily points, else re-bucket to week/month/year taking the lowest per period.
- `bucket(forSpanDays:)`: <61d → day, <366d → week, <3y → month, else year.
- `distinctDayCount` + `minimumDaysForGraph = 3` gate the graph vs the pending state.

## FX (deferred)
The app has no exchange-rate source today, and most trackers are single-currency
(one product across stores in one region). v1 plots `lowestPrice` directly in the
tracker's `displayCurrency`; each snapshot carries an optional `fxRate` that
`PriceHistory` applies when present, so adding an FX-rate fetch later is a pure
data fill with no migration. Multi-currency conversion is therefore best-effort in
v1 (documented).

## View (`PriceGraphView` + `PriceTrackingViewController`)
- A `graphContainer` is inserted BELOW the sellers table and ABOVE the alert footer,
  OUTSIDE the scroll view (fixed height), per the spec.
- ≥3 days → `PriceGraphView` (line + filled area, y min/max labels, x endpoint
  dates); else an "Awaiting more data" pending label.
- `PriceGraphView` press-and-drag scrubber (`UILongPressGestureRecognizer`,
  minimumPressDuration 0): highlights the nearest point + a callout with the value,
  full date, and store host. Refreshed on `viewWillAppear`.

## Tests
`PriceHistoryTests`: day bucketing keeps the lowest per day; new-day append;
per-store merge takes the cross-store low; span→bucket thresholds; re-bucketing to
week/month takes the period low; `distinctDayCount`; old-save decode (no
`priceHistory` key) → empty history.
