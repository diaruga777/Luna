# Price History Graph

Every refreshed price is bucketed by calendar day (lowest per day) and shown in
the Price Tracker card's adaptive price-over-time graph.

## Storage and aggregation

- `PriceDaySnapshot { dayStart, lowestPrice, currency, fxRate? }` is stored on
  each `PriceTrackerStore`. Migration defaults missing history to `[]`.
- Successful refreshes call `recordPriceSample`; failed fetches record nothing.
- `PriceHistory.series(for:)` takes the daily low across stores and adapts day →
  week → month → year as the span grows.
- The graph accepts zero, one, or many points. Zero points draw real axes and the
  editable threshold instead of replacing the chart with a pending state.
- FX conversion remains deferred. An optional per-snapshot `fxRate` is applied
  when present; otherwise v1 assumes the tracker's display currency.

## View and interaction

- The product thumbnail/title header sits above `PriceGraphView`; tracked sites
  and the add button sit below it.
- The price series is grey. The absolute alert threshold is a dashed, fixed
  Price Tracker green line with a leading grab handle and a price label above it.
  Points strictly below the threshold are green dots.
- Dragging only the handle moves the threshold and changes its label into a
  decimal-pad text field with checkmark/cancel controls. Checkmark persists via
  `PriceTracker.setAlertThresholdPrice`; cancel restores the pre-edit value.
- The series itself never drags or scrubs. Tapping near one point shows the small
  price/date/store tooltip; tapping elsewhere dismisses it.

## Tests

`PriceHistoryTests` covers bucketing, cross-store lows, rebucketing, and migration.
`PriceTrackerTests` covers absolute-threshold/fraction conversion and clamping.
`PriceTrackingScreenTests` verifies the carousel root and zero-point threshold.
