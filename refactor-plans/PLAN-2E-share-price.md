# Wave 2E — share surface / price UI

Read `PLAN.md` hard rules and `audits/share-price-intents.md` §2, §4, top-10 first.
Files: `LunaShareSurface/*`, `LunaPriceUI/*`, plus (item 3 only) the shared helper's
adoption in `Luna/Downloader/SavedMediaCardsViewController.swift` — coordinate: Wave 3C
also touches that file, so land this wave first (PLAN.md ordering already guarantees it).
One commit per item.

1. **Route `ShareReaderViewController`'s `.product` case through
   `ShareSurfaceDriver.persistTracker`** (audit top-10 #3): the audit found the
   `PriceTracker` construction duplicated byte-for-byte; deduping through the driver is
   behavior-identical by construction. Verify field-for-field equality before switching.

2. **Replace `SavedNonTextualViewController.downsampledImage` with
   `LunaDesignSystem.ImageDownsampling.decode`** (top-10 #4) — BUT preserve current
   rendering: the hand-rolled copy omits the display-scale argument, so pass an explicit
   scale that reproduces today's output (likely `1`). Note the fidelity discrepancy in
   your report; fixing it is a visible behavior change we're not making.

3. **Consolidate save-to-Photos / delete flows** shared by
   `SavedNonTextualViewController` and `SavedMediaCardsViewController` (top-10 #5).
   The two copies differ (defensive temp-copy present in one, operation ordering
   differs) — extract a shared helper (natural home: `LunaMediaDownload`, next to
   `PhotoLibrarySaver`) that captures the identical core, with parameters/hooks that let
   each caller keep its EXACT current ordering and temp-copy behavior. Do not "pick the
   better variant" — that's a behavior change; document the difference at the call sites.

4. **`ProductSearchOverlayDelegate`** (top-10 #2): convert
   `ProductSearchOverlayViewController.onUseThisPage` (3-arg closure with nested
   completion) into a delegate protocol (one method mirroring the closure signature,
   completion parameter preserved). Update its call site(s) mechanically.

5. **Collapse `PriceTrackingManaging`/`PriceTrackingManager`** (top-10 #10): the 18-line
   indirection with one call site → direct `PriceFetching` usage.

6. **`AlertThresholdSlider` pill chrome dedupe** (top-10 #8): ~35 near-identical layout
   lines mirrored in `CatchUpPriceTrackerCardBody.makeThresholdReadout`
   (`Luna/CatchUp/CatchUpSubviews.swift`). Extract the shared pill construction into
   `LunaPriceUI` (the app shell already links it) and have both use it. The two files'
   comments already acknowledge the mirroring — remove those comments once the code is
   actually shared.

7. **`PriceTrackingViewController` orphaned `// MARK: - Threshold footer`** (top-10 #6):
   relocate the threshold-footer code under its marker or delete the marker — match
   whichever reflects reality.

Leave `ShareViewController.javaScriptResult`'s `public`-for-tests exposure in place for
now — Wave 4 may restore the driver tests that used it; it gets tightened there if they
don't.

Verification: build-for-testing per commit; at wave end run
`-only-testing:LunaTests/ShareSurfaceDriverInteropTests -only-testing:LunaTests/InteropSettingsTests -only-testing:LunaTests/CatchUpAndPriceScreenTests`
plus tests matching touched types. Snapshot diffs in CatchUpAndPriceScreenTests = you
changed pixels; fix the code.
