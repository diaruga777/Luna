# Price History Graph

Every refreshed price is bucketed by calendar day (lowest per day) and shown in
the Price Tracker card's adaptive price-over-time graph.

## Storage and aggregation

- `PriceDaySnapshot { dayStart, lowestPrice, currency, fxRate? }` is stored on
  each `PriceTrackerStore`. Migration defaults missing history to `[]`.
- Successful refreshes call `recordPriceSample`; failed fetches record nothing.
- `PriceHistory.series(for:)` takes the daily low across stores and adapts day →
  week → month → year as the span grows.
- The graph accepts zero, one, or many points. Zero points draw real axes instead
  of replacing the chart with a pending state; an existing alert is still mirrored.
- FX conversion remains deferred. An optional per-snapshot `fxRate` is applied
  when present; otherwise v1 assumes the tracker's display currency.

## View and interaction

- The product thumbnail/title header sits above the tracked sellers and add
  button; `PriceGraphView` follows them, with the alert row last.
- The price series is grey. When an alert exists, its absolute threshold is a
  dashed Price Tracker green line with one bell marker and no repeated value.
  Points strictly below the threshold are green dots. With no alert, neither the
  line nor bell is drawn.
- The graph is read-only apart from point selection. `AlertThresholdRow` is the
  sole editor; slider movement updates the graph line live before persistence.
- The currency symbol appears once above the y axis. Numeric labels keep cents
  while space permits, compact five-digit thousands and millions to `k` / `m`,
  and leave four-digit prices expanded.
- The series itself never drags or scrubs. Tapping near one point shows the small
  price/date/store tooltip; tapping elsewhere dismisses it.

## Tests

`PriceHistoryTests` covers bucketing, cross-store lows, rebucketing, and migration.
`PriceTrackerTests` covers absolute-threshold/fraction conversion and clamping.
`PriceTrackingScreenTests` verifies the carousel root and zero-point alert marker.
