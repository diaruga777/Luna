# Plan: per-save diagnostics capture + failed-card share (Plan A)

Goal: a failed save carries a complete, shareable debug trace — every network
request and response shape, every classification decision, every strategy tried
— written into the general diagnostics stream (tagged with the save it belongs
to) AND into a per-item sidecar file that the failed-save card can export as a
.txt and that the Apple Intelligence rescue engine can read back as evidence
(consumed by the companion plan, `rescue-improvements-plan.md`).

The shared seam already exists on `main`:
`LunaLibraries/Sources/LunaStorage/SaveDiagnosticsStore.swift` — one plain-text
file per item at `<AppGroup>/saveDiagnostics/<UUID>.log`, lines in the same
`ISO8601 [category] message` format as `clip-diagnostics.log`. This plan builds
the recorder, the instrumentation, and the card UI around it. Behavior tests
for the store itself are part of this plan (none exist yet).

## Current state (verified 2026-08-13)

- `DiagnosticLog` / `SharedDiagnosticLog` (LunaStorage) write
  `ISO8601 [category] message` lines to the App Group `clip-diagnostics.log`.
  `SharedDiagnosticLog.record` is synchronous (extension jetsam);
  `DiagnosticLog.shared.record` is async on a serial queue. 1 MB cap, trimmed
  only by `DiagnosticLog`.
- **No correlation ID exists anywhere.** `record(_:category:)` has no context;
  concurrent saves interleave indistinguishably.
- **The fetch layer logs nothing.** Zero `DiagnosticLog` references in
  LunaFetch, LunaMediaResolve, LunaPaywallBypass, LunaIngest, LunaArticleIngest,
  LunaPriceIngest. The one worked example of good attempt logging is the price
  fan-out: `SellerFanOutAttempt.logLine` / `SellerFanOutOutcome.logSummary`
  (`LunaPriceCompare/SellerFanOut.swift:196,235,280`) — structured record on a
  value type, formatting on the value, one `onAttempt` sink.
- Failure recording: `ReadingListStore.markFailed` (state only) +
  `SaveFailureStore` sidecar (`saveFailures.json`: reason, count, dates,
  resolvedTitle, aiAttemptVersion). Failed card =
  `FailedSaveCardViewController` (LunaReadingListUI) with injected
  `FailedSaveCardActions { rescue, share, delete }`, assembled by
  `Luna/ReadingList/FailedSaveCardFactory.swift` (universal, all four apps).
  The URL-bar share button exists and currently shares the raw URL via
  `SendToFriendSheet.shareLink` (`FailedSaveCardFactory.swift:131`).

## Work items

### 1. `SaveDiagnosticsRecorder` + task-local context (LunaModels)

New file `LunaLibraries/Sources/LunaModels/SaveDiagnostics.swift` (LunaModels so
that Foundation-only modules — LunaFetch, LunaMediaResolve, LunaPaywallBypass,
LunaHTMLClassification, LunaIngest — can record without new dependency edges;
LunaModels must NOT import LunaStorage):

```swift
public final class SaveDiagnosticsRecorder: @unchecked Sendable {
    public let itemID: UUID
    /// Mirrors each line to the general diagnostics stream; installed by the
    /// layer that owns storage (ReadingListIngestor / ShareSurfaceDriver).
    public init(itemID: UUID, mirror: @escaping @Sendable (String, String) -> Void)
    /// Timestamps, buffers, and mirrors "[save <first8>] <message>".
    public func record(_ message: String, category: String)
    /// The buffered, formatted lines (for the failure-time flush).
    public func drainLines() -> [String]
}

public enum SaveDiagnostics {
    @TaskLocal public static var recorder: SaveDiagnosticsRecorder?
    /// No-op when no recorder is bound — instrumentation call sites stay
    /// unconditional and cost nothing outside a save.
    public static func record(_ message: String, category: String)
}
```

Rules:
- One formatter per recorder; the line written to the sidecar and the message
  mirrored to the general stream carry the same timestamp.
- The general-stream tag is `[save <first 8 of UUID>]`, prepended to the
  message (the `[category]` slot is already taken by the line format).
- **Task-locals do not survive delegate callbacks.** Components that log from
  WKWebView/main-actor callbacks (`WebViewPriceRenderer`, snapshot renderers)
  must capture the recorder reference at creation instead of reading the
  task-local inside the callback.
- New instrumentation records ONLY through `SaveDiagnostics.record` — i.e. it
  is silent unless a save is in flight. Existing direct
  `DiagnosticLog`/`SharedDiagnosticLog` call sites are untouched.

### 2. Binding points (who creates/flushes the recorder)

- **`ReadingListIngestor.ingest`** (`LunaReadingList/ReadingListIngestor.swift:96-118`):
  create a recorder for the placeholder item's UUID, bind with
  `SaveDiagnostics.$recorder.withValue(...)` around the pipeline call. Mirror
  closure: `DiagnosticLog.shared.record` in-app. After `applyResult`: outcome
  `.failed` ⇒ flush `drainLines()` via `SaveDiagnosticsStore.appendLines`,
  prefixed with an attempt separator line (`— attempt N via <source>, <reason> —`
  where N is `SaveFailureStore` failureCount); any other outcome ⇒ drop the
  buffer and `SaveDiagnosticsStore.shared.delete(for:)` so a recovered item
  sheds its stale trace. Launch-sweep retries flow through this same path and
  therefore append later attempts to the same file.
- **`ShareSurfaceDriver`** (`LunaShareSurface/ShareSurfaceDriver.swift:51,75,149-160`):
  same binding, mirror = `SharedDiagnosticLog.record` (synchronous). **Also fix
  the recording gap here**: the driver currently calls `store.markFailed($0.id)`
  without `SaveFailureStore.recordFailure` — every other failure path pairs
  them. Pair them, so extension failures carry a reason and a count.
- **Media terminal failure**: `SaveFailureReason.noMediaFound` currently has NO
  writer (`Luna/URLRescueWiring.swift:124` reads it to pick
  `RescueRequest.FailureKind.mediaNoAssets`, a dead branch). Find where a media
  save becomes terminally failed with zero resolved assets and write
  `.noMediaFound` into `SaveFailureStore` there, flushing the recorder if one
  is bound. (Investigate: `SocialMediaResolver.resolveAssets` returning `[]`,
  the media kind wiring, `LiveMediaDownloadManager`.)
- Do NOT bind in preload (`PreloadCoordinator`), the reader clip, metadata
  refreshes, or the onboarding demo — those are not user saves.

### 3. Instrumentation sites (the meat)

Log shapes, sizes, statuses, decisions — never bodies. Cap any quoted snippet
at ~200 chars. Category strings: reuse existing conventions (`ingest`,
`fetch` (new), `bypass` (new), `media`, `price`, `rescue`).

1. **`ArticleFetcher.fetch`** (`LunaFetch/ArticleFetcher.swift:525-556`) — the
   choke point behind six of seven `HTMLFetching` methods. One line per
   request outcome: URL, UA/referer/XFF presence (token names, not values),
   HTTP status, content-length, actual bytes, elapsed ms; on throw, which
   `FetchError` (`badResponse(status:)`, `notHTML`, `tooLarge`,
   `subscribeRedirect(landedOn:)` incl. the landing URL).
2. The three archive-index calls that bypass `fetch`
   (`ArticleFetcher.swift:125` archive.today TimeMap, `:204` Wayback
   availability, `:463` CDX) — same shape.
3. **`ArticleExtraction.fetchAndExtract`**
   (`LunaHTMLClassification/ArticleExtraction.swift:76`) — extraction outcome:
   extracted char count, title present, or the swallowed fetch error (the
   existing `onFetchError` seam observes it).
4. **`ArticleResolver.resolve`** (`LunaPaywallBypass/ArticleResolver.swift:54`)
   — the gate decision (`BypassGate.decision`), the plan
   (`BypassPlan.make`: silent strategy list, webPreStages, allowsArchiveToday),
   and the final `resolution(direct:archived:directFailure:...)` mapping.
5. **`BypassRunner.run`** (`LunaPaywallBypass/BypassRunner.swift:30-39`) — per
   strategy: name + outcome (extracted chars, or nil). Follow the
   `SellerFanOutAttempt` pattern: a small value type with a `logLine`, one
   line per strategy. This is where "what strategies were employed" lives.
6. **`IngestPipeline`** (`LunaIngest/IngestPipeline.swift:211-370`) — unwrap
   result (`:222`), classification verdict (kind/platform, `:228`),
   multi-item-listing and non-content vetoes (`:282`, `:343`), product path
   entered / price found or nil (`:317-329`), article path entered, timeout
   (`:186-207`).
7. **`SocialMediaResolver.resolveAssets`**
   (`LunaMediaResolve/SocialMediaResolver.swift:27-46`) — platform picked, each
   ladder step tried (fxtwitter / GraphQL / embed / og-tags…), per-step
   status/bytes, final asset count and types.
8. **Product extraction** (`LunaPriceIngest/ProductIngestProcessor.swift:46-65`,
   `ProductMetadataExtractor.swift:95`) — host rule applied, JSON-LD present,
   price found or nil, Safari-snapshot fallback used.
9. **`PriceFetcher.fetchPrice` / `WebViewPriceRenderer`**
   (`LunaPriceUI/PriceFetcher.swift:66,152,192`) — remember the delegate-callback
   caveat from item 1.

Constraint reminders: LunaMediaResolve and LunaPriceCompare must stay on their
Foundation-only dependency floors (LunaModels is already below both — fine).
Do not add heavier edges.

### 4. Share button on the failed card

- `FailedSaveCardViewController` (LunaReadingListUI): the URL-bar share button
  gains a `UIMenu` — "Share Link…" (existing behavior) + "Share Diagnostics…",
  the latter present only when `SaveDiagnosticsStore.hasDiagnostics(for:)`.
  Extend `FailedSaveCardActions` with `shareDiagnostics: ((UIView) -> Void)?`
  (nil ⇒ menu omits the item) or pass a menu-builder — pick whichever reads
  best against the existing injected-closure style.
- `FailedSaveCardFactory.makeMenu(shareLink:delete:)`
  (`Luna/ReadingList/FailedSaveCardFactory.swift:92`) — the long-press deck
  menu gains the same "Share Diagnostics…" item.
- Export path: header (mirror `DiagnosticLog.header()` — app version, OS,
  exported-at) + save metadata (URL, `SaveFailureReason.headline`,
  failureCount, first/last failure dates, aiAttemptVersion, rescue-ledger
  summary if present) then `SaveDiagnosticsStore.exportFile(for:header:)` into
  a `UIActivityViewController` anchored on the source view (see
  `ArticleExportService.presentShareSheet`,
  `LunaSend/ArticleExportService.swift:167-197`, for the presentation shape).
- Extension failure card (`LunaShareSurface/RescueFailureViewController.swift`):
  optional stretch — same menu if the trace file was flushed in-process.
- Strings: new keys in
  `LunaLibraries/Sources/LunaModels/Resources/en.lproj/Localizable.strings`
  with `_Luna` suffix, resolved via `L10n.string` — never a switch on
  `LunaApp.current`. Run `scripts/strings_sync.py` to verify.

### 5. Lifecycle

- Delete the trace file wherever the item stops being failed or exists:
  the card/deck delete actions (`FailedSaveCardFactory.makeActions`,
  `KindDeckProvider` delete), success paths that call
  `SaveFailureStore.clear` (`ReadingListStore.swift:799,822`), and the rescue
  sweep's `SaveFailureStore.prune` call site gets a paired
  `SaveDiagnosticsStore.prune(keeping:)`.

### 6. Tests (behavior bar per CLAUDE.md — no constant echoes)

- `SaveDiagnosticsStoreTests`: append/read round-trip, attempt append across
  two flushes, front-trim keeps the newest lines, delete/prune, export header
  + contents.
- Recorder: buffering + mirroring with the same timestamp, tag format, no-op
  without binding, task-local propagation through an async pipeline call
  (fake fetcher records through `SaveDiagnostics.record`, assert the flushed
  file holds the line).
- `ShareSurfaceDriver` failure now writes a `SaveFailureStore` reason.
- Card: menu shows/hides "Share Diagnostics…" by `hasDiagnostics`.
- Pipeline instrumentation: one integration-style test per major leg (article
  fail, media zero-assets, product no-price → article fail) asserting the
  flushed trace names the strategies/statuses involved — assert on presence of
  the load-bearing tokens, not exact strings.

### 7. Docs

Update `claudedocs/failed-saves.md` (share button, sidecar), add
`claudedocs/save-diagnostics.md` describing the recorder/store/tag format, and
note the new categories in the diagnostics section of
`claudedocs/price-comparison.md` only if its text is now stale.

## Out of scope (Plan B owns these)

Anything inside `LunaURLRescue`/`URLRescueCoordinator`/`URLRescueWiring`:
feeding the trace to the model, rescue-time appends to the sidecar, guardrail
attempt policy, rescue telemetry. Plan A only guarantees the file exists,
is complete, and is shareable.
