# Audit: LunaShareSurface / LunaPriceUI / LunaPriceMetadata / LunaIntents / LunaInterop / LunaInteropUI / LunaReadingListUI + extension targets

Read-only, behavior-preserving-refactor audit. No code was changed. Every file listed
in the assignment was read in full; every "who uses it" and "dead code" claim below is
backed by an inline grep command. Two prior passes already landed and are **not**
re-reported here: `CODE_REVIEW_PLAN.md` (2026-07-02) and `PERF_REVIEW_PLAN.md`
(2026-07-05, STATUS: COMPLETE). A third, apparently **unexecuted** plan,
`claudedocs/codebase-audit-2026-07.md` (committed 2026-07-19), partially overlaps this
scope — its item **B2** (decode caching in `DownloaderProgressFooterView`) is already
implemented in current code (verified by reading the file — see below), and its items
**B1/B4/D1** target `Luna/Downloader/SavedMediaGridViewController.swift` and
`SavedMediaViewerViewController.swift`, which **no longer exist** — they were replaced
by the carousel (`Luna/Downloader/SavedMediaCardsViewController.swift`, commits
`ff0d049e`..`e987747c`, this week) after that plan was written. That plan is stale for
this area; flagged once here, not treated as live work.

## 0. Headline regression since the two prior passes

**A single commit, `97833a34` "Clean up broken integrations" (2026-07-07 — after both
prior passes completed), deleted ~35 `LunaTests` files (~4,000+ lines), the large
majority unrelated to that commit's stated purpose (removing the `LunaYouTubeAPI`
module).** Verified: `git show 97833a34 --stat` and `git log --all --diff-filter=A --
LunaTests/<name>.swift` for each filename below returns **no re-creation, ever** — the
coverage is simply gone, not renamed or merged elsewhere (spot-checked by grepping
current `LunaTests/*.swift` for the type names each file exercised).

Deleted files landing squarely in **this audit's scope**:

| Deleted test file | Lines | Covered | Current replacement |
| --- | --- | --- | --- |
| `ReadingListSectioningTests.swift` | 399 | `ReadingListSectioning` (all of it — sections, catch-up queue, dot logic, filter visibility) | **None.** Only incidentally touched by `CatchUpAndPriceScreenTests`'s `catchUpQueue` call and `ReadingListDiffTests` |
| `ReadingListSubtitleTests.swift` | 164 | `ReadingListSubtitle.parts` (every branch: reading time, progress, send states, lifecycle) | **None** |
| `ShareSurfaceDriverTests.swift` | 263 | `ShareSurfaceDriver.present()`'s full `Outcome` switch (article/video/social/document/product/archive/failed presentation + persistence) | Narrowed to `ShareSurfaceDriverInteropTests.swift` (9 tests, **interop-gate outcomes only** — `.blocked`/`.allowedNeedsInstall`/`.allowed` branches, not the underlying per-`Outcome`-case presentation/persistence behavior) |
| `ShareKitScreenTests.swift` | 99 | `ShareReaderViewController` loading/Done-button snapshot, `SavedNonTextualViewController` layout snapshot, `ShareViewController.javaScriptResult` decoding (wrapped + direct-payload) | **None** |
| `NonTextualContentTests.swift` | 90 | `NonTextualContent`/platform embed/preview-image model logic that `SavedNonTextualViewController` renders | **None** |
| `SurfaceParityTests.swift` | 293 | Cross-surface parity: same `Outcome` from the same URL whether ingested via main app or extension; same presentation *intent* across surfaces — "FAILS if any surface diverges again" (its own doc comment) | **None** |
| `ReadingListScreenTests.swift` | 359 | `ReadingListViewController`/`ReadingListItemCell` screen-level behavior | **None** |
| `ReadingListStoreTests.swift` | 382 | `ReadingListStore` (out of this audit's module list, but every module here sits on top of it) | **None** |
| `OutcomePresenterTests.swift` | 102 | The main-app counterpart to `ShareSurfaceDriver` (`ShareSurfaceDriver.persistArticle`'s doc comment explicitly calls out "shared shape with the main app's `IngestorOutcomePresenter`") | **None** |

This is the single most consequential finding in this audit: the exact regression class
`SurfaceParityTests` existed to catch (a surface silently diverging in what it saves or
how it presents an outcome) now has **zero automated coverage**, and the richest
behavioral test of the extension pipeline (`ShareSurfaceDriverTests`) was replaced by a
test file that only exercises the interop gate wrapped around it. See "Top 10" #1.

---

## 1. Structure map

### LunaShareSurface (8 files, 2,480 lines) — package deps: `LunaAppConfig, LunaModels, LunaStorage, LunaIngest, LunaURLClassification, LunaDesignSystem, LunaReaderUI, LunaArchiveReader, LunaAudioPlayback, LunaPriceUI, LunaMediaDownload, LunaPlatforms, LunaInterop, LunaInteropUI`

- **`ShareViewController.swift`** (678 lines) — the zero-UI share extension AND the
  "Read in Luna" action extension in one class, branching throughout on
  `isActionExtension` (computed from `NSExtensionPointIdentifier`). Owns attachment
  loading (URL / doc / text / Safari JS-preprocessing payload), a 15s load watchdog, and
  the terminal chrome (saved checkmark, error text, downloading badge). Public API:
  `isActionExtension`, `failOrComplete`, `javaScriptResult(from:)` /
  `(fromPropertyListData:)` (public, `nonisolated static`, used by tests per its own doc
  comment — but see Dead/unused below), `confirmSavedThenComplete`, `completeSilently`,
  `openURL`, `autoDownloadThenComplete`. Conforms to `ExtensionHost`. **Who uses it**:
  `NSExtensionPrincipalClass` string in `LunaShare/Info.plist` and
  `"Luna Action Extension"/Info.plist` (both literally `LunaShareSurface.ShareViewController`
  — confirmed: `grep -A1 NSExtensionPrincipalClass LunaShare/Info.plist "Luna Action
  Extension/Info.plist"`). No Swift call site references it directly outside its own
  file and `ShareSurfaceDriver.swift`'s doc comment (`grep -rln "ShareViewController"
  --  *.swift` → only `LinkAnchor.swift`×2 comments, `ExtensionHost.swift`,
  `ShareViewController.swift`, `ShareSurfaceDriver.swift`) — this is expected for a
  principal-class-only entry point, not dead code.
- **`SavedNonTextualViewController.swift`** (977 lines) — the extension's post-save
  confirmation screen for non-article content (video/post/etc.): friend-share list,
  inline media preview/download/save-to-Photos/share/delete state machine
  (`MediaState`). Public: `init(articleURLString:content:onDone:)`. **Who uses it**:
  `ShareSurfaceDriver.presentNonTextual` (production), `InteropPromptViewController`
  (doc-comment reference only), `Luna/UITestScreen.swift` (UI-test harness hook). Was
  also covered by the now-deleted `ShareKitScreenTests.swift` (see §0).
- **`ShareReaderViewController.swift`** (233 lines) — presents the shared `ReaderKit`
  reader scoped to one article inside an extension; also handles `.product` (saves a
  price tracker inline and shows a confirmation — see Duplication #1) and
  `.needsArchive` (archive.today CAPTCHA reader) outcomes when a standalone `Outcome` is
  supplied. **Who uses it**: `ShareViewController` (via `ShareSurfaceDriver`),
  `ActionReaderMode`. Was covered by the deleted `ShareKitScreenTests.swift`
  (`testShareReaderLoadingSnapshot`, `testShareReaderHasDoneButton`); no replacement.
- **`ShareSurfaceDriver.swift`** (365 lines) — the host-agnostic ingest→classify→
  persist→present flow shared by both extension surfaces; the single place the
  `Outcome` switch and the interop gate are evaluated for extensions. Public:
  `init(host:store:process:interopDecision:currentSurface:)`, `ingestAndPresent`,
  `present(_:url:blockedItemID:)`. **Who uses it**: `ShareViewController`
  (`presentSavedOrReader`), `LunaTests/ShareSurfaceDriverInteropTests.swift`,
  `LunaTests/ExtensionAudioScriptWriterTests.swift` (doc-comment reference to
  `persistArticle`'s call-out). This is the type that lost the bulk of its
  non-interop behavioral coverage (§0).
- **`ExtensionHost.swift`** (57 lines) — the `@MainActor` protocol abstracting
  `NSExtensionContext`/UIKit so `ShareSurfaceDriver` is testable with a fake. Clean,
  narrow, well-documented seam. **Who uses it**: `ShareViewController` (conformer),
  `ShareSurfaceDriver` (consumer), `InteropPromptViewController` (context enum case),
  test files `ShareSurfaceDriverInteropTests`, `CatchUpAndPriceScreenTests`,
  `ProductSearchAndExitContextTests` (all via `FakeExtensionHost`/`.extensionHost`
  context cases).
- **`ExtensionReaderShareProvider.swift`** (29 lines) — the extension's
  `ReaderShareProviding` conformance: plain system share sheet, no Luna deep link, no
  friend-share (needs the email account, main-app-only). **Who uses it**:
  `ShareReaderViewController` only (`grep -rln "ExtensionReaderShareProvider"` → those
  two files exactly).
- **`ActionReaderMode.swift`** (22 lines) — persists the action extension's own
  last-used reader mode in its private `UserDefaults.standard` (explicitly NOT the App
  Group). **Who uses it**: `ShareViewController.readerMode`, `ShareReaderViewController`
  (`onModeChange`) — exactly the two files besides its own.
- **`SharedReadingListAppender.swift`** (119 lines) — appends a pending item to
  `readingList.json` via raw `JSONSerialization` dictionaries (deliberately NOT the
  typed model, to avoid dropping unknown fields — see Comment hygiene #1) under
  `NSFileCoordinator`. **Who uses it**: `ShareViewController` (URL/text/JS-result save
  paths), `ExtensionReaderShareProvider.saveLink`, `ShareSurfaceDriver.presentPriceEditor`
  ("Read instead"). All three of the extension's actual write paths funnel through this
  one file — good centralization, no duplication found.

### LunaReadingListUI (6 files, 1,078 lines) — package deps: `LunaModels, LunaStorage, LunaDesignSystem, LunaPlatforms, LunaMediaDownload, LunaReaderUI, LunaSend`

- **`ReadingListItemCell.swift`** (384 lines) — the reading-list row: title/subtitle/
  thumbnail with a 3-state thumbnail machine (spinner/art/logo), an `NSCache`-backed
  decoded-bitmap cache, and a `loadToken`-guarded async downsample
  (`ImageDownsampling.decode`, shared with `LunaDesignSystem`). **Who uses it**:
  `Luna/ReadingList/ReadingListViewController.swift`, `Luna/MiniPlayer/
  AudioMiniPlayerView.swift`, `Luna/CatchUp/CatchUpDeleteReadView.swift` — all in the
  shared `Luna/` app shell, so all three apps get it. No dedicated test file exists now
  (see §0 — this is what `ReadingListScreenTests.swift` used to cover).
- **`ReadingListSectioning.swift`** (233 lines) — pure decision logic: section
  assignment (Reading/Archive/Error/PriceTracking), the single floated-to-top alerting
  tracker, filter-segment visibility, catch-up queue ordering, catch-up dot logic; also
  hosts `AppSurface` (the reader/downloader/priceTracker enum every `ReadingListViewController`
  instance is constructed with). **Who uses it**: `Luna/ReadingList/
  ReadingListViewController.swift`, `Luna/Reader/ArticleCardsViewController.swift`,
  `Luna/AudioPlaybackWiring.swift`, `Luna/UITestScreen.swift`,
  `LunaAudioPlayback/AudioPlaybackSeams.swift`, `ReadingListDiff.swift` (its own sibling
  file). **Lost its 46-test dedicated file in the §0 regression** — see there.
- **`ReadingListSubtitle.swift`** (81 lines) — pure assembly of the grey metadata line
  (leading label, date, reading time, progress %, send states, lifecycle status).
  **Who uses it**: `Luna/ReadingList/ReadingListViewController.swift` only. **Lost its
  22-test dedicated file in the §0 regression; currently has zero test coverage at
  all** (`grep -rln "ReadingListSubtitle" LunaTests/*.swift` → no results).
- **`ReadingListDiff.swift`** (109 lines) — pure id-keyed diff between two grouped
  models, producing `performBatchUpdates` inputs. **Who uses it**:
  `Luna/ReadingList/ReadingListViewController.swift`. Tested by
  `LunaTests/ReadingListDiffTests.swift` (8 tests) — this one file in the module kept
  its coverage.
- **`DownloaderProgressFooterView.swift`** (167 lines) — a footer pinned to the
  Downloader carousel showing whichever download job is in flight; caches its decoded
  thumbnail per job (`cachedThumbnailFileName`/`cachedThumbnailImage`) — this is exactly
  `claudedocs/codebase-audit-2026-07.md`'s item **B2**, already implemented (confirmed
  by reading lines 26-30, 128-138). **Who uses it**: `Luna/Downloader/
  SavedMediaCardsViewController.swift` only.
- **`MediaDownloadStatusView.swift`** (104 lines) — the analogous non-blocking status
  pill for the *reading list* screen's own media-download status (different from the
  Downloader-grid footer above — these two views are siblings, not duplicates of each
  other; verified their call sites don't overlap). **Who uses it**:
  `Luna/ReadingList/ReadingListViewController.swift`.

### LunaPriceUI (11 files, 2,414 lines) / LunaPriceMetadata (1 file, 55 lines) / LunaInterop (6 files, 531 lines) / LunaInteropUI (3 files, 570 lines)

*(from the parallel sub-audit; file-by-file detail preserved verbatim below in
§2/§3/§4 — summarized here for the map)*

- `PriceTrackingViewController.swift` (706 lines) — full price-tracker editor (sellers,
  alert threshold, history graph, add-seller, "Read instead"). Used from the shared
  `Luna/` shell (`AppDelegate`, `AudioPlaybackWiring`, `ReadingListViewController`,
  `CatchUpSubviews`/`CatchUpViewController`, `UITestScreen`) and from
  `ShareSurfaceDriver.presentPriceEditor` (extension host). Tested only by
  `CatchUpAndPriceScreenTests.swift` (2 of its snapshot tests are among CLAUDE.md's 4
  documented `XCTSkip`s).
- `ProductSearchOverlayViewController.swift` (561 lines) — WKWebView search/browse
  overlay for adding a seller, with a Google-Shopping DOM-observer JS bridge. Single
  consumer (`PriceTrackingViewController`), **zero test coverage**.
- `PriceFetcher.swift`, `PriceRefresher.swift`, `PriceTrackingManager.swift`,
  `PriceGraphView.swift`, `AlertThresholdSlider.swift`, `PriceUIAlerts.swift`,
  `ProductPageSuggestion.swift`, `ProductSuggestionDebouncer.swift`, `InAppBrowser.swift`
  — each a narrow, mostly single-consumer type; see §3 for the two real duplication
  findings among them.
- `LunaPriceMetadata/ProductMetadataParsing.swift` — pure JSON-LD parser, one caller
  (`LunaHTMLClassification/ProductMetadataExtractor.swift`), correctly layered
  underneath, package-level test coverage.
- `LunaInterop/*` — the pure entitlement/gate/purchase tier
  (`InteropGate`/`InteropEntitlement`/`InteropPurchaseController`/`InteropProductID`/
  `InteropAppGroupDefaults`/`InteropSurface`), used throughout `LunaReadingList`,
  `LunaShareSurface`, `LunaPriceUI`; heavily tested (`InteropGateTests`,
  `InteropEntitlementTests`, `InteropPurchaseControllerTests`, `InteropSurfaceTests`).
- `LunaInteropUI/*` — `InteropPromptViewController` (inline blocked/needs-install
  sheet), `InteropPaywallViewController` (full Settings/deep-link purchase screen),
  `InteropPromptKind`. Used from `ShareViewController`, `ShareSurfaceDriver`,
  `PriceTrackingViewController`, `Luna/AppDelegate.swift`, `Luna/Settings/
  SettingsViewController.swift`, `Luna/SceneDelegate.swift`.

### LunaIntents (18 files) / Luna/Mail/Intents (6 files: `SaveIntent`, `ProvideContextIntent`, `ReadArticleIntent`, `ArticleEntity`, `CaptureIntentResult`, `LunaShortcuts` — the sub-audit found 6, not the 4 named in the assignment)

*(from the parallel sub-audit; full detail in §2/§3/§4)*

- The **library/definition split here is the cleanest of the three sub-scopes**: every
  `AppIntent.perform()` in `Luna/Mail/Intents/*.swift` delegates outward to a named
  `LunaIntents` type with no reimplemented logic — verified line-by-line, not just by
  grep.
- `ScreenCaptureModelSession`/`ScreenCaptureModelSessionFactory`/
  `FoundationModelsScreenCaptureSession` — a clean protocol seam for the iOS 26/27
  on-device-vision gate, no UI leakage.
- `BlueskyPostQuery`/`RedditPostQuery` — parallel but genuinely disjoint (different
  field shapes), correctly *not* unified.
- Every file in this module has a corresponding `LunaTests` file except the thin
  `AppIntent`/`AppEntity`/`AppShortcutsProvider` definitions themselves (typical/expected
  for that type) and `ScreenCaptureModelSession` (untestable without a real
  device — the pure decision logic downstream, `ProvideContextDecision`, is tested
  instead, which is the right place for that coverage to live).

### Extension/clip targets

- **`LunaSafari/`** (4 files, 260 lines) — `SafariAppGroup` (Info.plist-injected App
  Group id, since this target doesn't link the package), `SharedSafariURL` (writes
  last-seen URL + unlocked-content HTML to the App Group), `SafariWebExtensionHandler`
  (the JS↔native bridge: button visibility, installed-app markers, onboarding
  handshake), `SharedOnboardingStatus` (per-surface enabled/takeover flags). Necessarily
  duplicates several literals from the app-side stores
  (`LunaStorage.SafariExtensionStatusStore`, `LunaDeepLink`'s scheme strings) because
  this target intentionally doesn't link `LunaLibraries` — each duplication site says so
  in a comment (`SharedOnboardingStatus.swift:14-15`, `SharedSafariURL.swift:10-11,13-14`).
  This is documented, deliberate duplication, not an oversight — not re-flagged as a
  finding.
- **`LunaShare/LinkAnchor.swift`** / **`Luna Action Extension/LinkAnchor.swift`** — two
  files, byte-for-byte identical except the enum name
  (`LunaShareLinkAnchor`/`LunaActionExtensionLinkAnchor`), each a workaround for an
  Xcode "source-less extension target" link-closure bug. Genuinely necessary duplication
  (one file per target, can't be shared — that's the entire point of the workaround);
  not a finding.
- **`LunaReaderClip/`** (3 files, 219 lines) — the App Clip: `AppDelegate` (2-line
  scene-config boilerplate), `SceneDelegate` (routes launch URL/`NSUserActivity` to the
  reader), `ClipReaderViewController` (loads via `IngestPipeline.processResolved`
  directly, presents the shared `ReaderViewController` for `.article`, else a "not
  readable here" message). Clean, minimal, no findings.
- **`Luna/Downloader/SavedMediaCardsViewController.swift`** (911 lines) — not in the
  assignment's module list, but explicitly required reading for the
  duplication-with-`SavedNonTextualViewController` comparison (§3, Duplication #2/#3/#4
  below). It is the Downloader app's root screen: a `CardCarousel`-based carousel over
  *every* `SavedMediaItem`, with cross-process change observation
  (`SavedMediaStore.startObservingCrossProcessChanges`), Photos reconciliation, a
  pasteboard-suggestion leading card, and context-menu share/save/delete/download
  actions. No dedicated test file (`grep -rl "SavedMediaCardsViewController" LunaTests`
  → empty).

---

## 2. Findings — Stored-callback communication

Every closure-as-cross-component-seam found across all six modules, with an assessment
of whether a protocol would be cleaner. One-shot completion closures (`onDone`,
`init`-supplied config) are excluded per the audit brief.

1. **`PriceTrackingViewController.defaultSaveAsArticle`**
   (`LunaPriceUI/PriceTrackingViewController.swift:91`, `public static var
   defaultSaveAsArticle: ((String) -> Void)?`) — set once at
   `Luna/AppDelegate.swift:73`, invoked at `PriceTrackingViewController.swift:571`
   inside `performReadInstead()`. This is the CLAUDE.md-documented seam. It's a static
   mutable global specifically because `LunaPriceUI` must not depend on
   `LunaReadingList` (module-tier constraint) — a protocol would need the same
   define-here/conform-there split and buys little. **Low-value to change.**
2. **`PriceTrackingViewController.interopSellerAddDecision` /
   `interopReadInsteadDecision`** (`:424`, `:535`, both `public static var … : () ->
   InteropGate.Decision`) — pure test seams over `InteropGate.evaluateForCurrentProcess`,
   almost never actually overridden in production. Consistent with
   `ReadingListIngestor.interopDecision`'s pattern elsewhere (instance-injected there
   vs. static here) — a legitimate tradeoff given `PriceTrackingViewController`'s
   `init` already takes several parameters. **Not worth changing.**
3. **`ProductSearchOverlayViewController.onUseThisPage`**
   (`ProductSearchOverlayViewController.swift:59-60`, `public var onUseThisPage:
   ((_ urlString: String, _ html: String, _ completion: @escaping
   (ProductSearchAddOutcome) -> Void) -> Void)?`) — set at
   `PriceTrackingViewController.swift:507`, invoked at `:347`/`:355`. **The one real
   outlier**: a 3-argument closure where one argument is itself a callback, functioning
   as a delegate method in closure clothing. A `ProductSearchOverlayDelegate` protocol
   method (`func productSearch(_:didConfirmPage:html:completion:)`) would let the
   compiler enforce the "must call completion" contract instead of a comment. **Best
   protocol-conversion candidate in the whole audit.**
4. **`ReadingListIngestor.interopPromptPresenter`** (outside this audit's file list,
   `LunaReadingList/ReadingListIngestor.swift`, but load-bearing for
   `LunaInteropUI`) — static `@MainActor (InteropPromptKind, retry: (() -> Void)?) ->
   Void`, set at `Luna/AppDelegate.swift:80` to construct an
   `InteropPromptViewController`. Same static-hook module-tier pattern as #1.
5. **`InteropPromptViewController.onDone`** (`InteropPromptViewController.swift:52`,
   `public var`) and **`InteropPaywallViewController.onUnlocked`** (`:24`) — set
   externally per call site (`PriceTrackingViewController.swift:609`,
   `ShareViewController.swift:455`, `Luna/SceneDelegate.swift`'s deep-link route). Same
   house style as `ExtensionHost`'s completion methods and `SavedNonTextualViewController.onDone`
   — consistent, one-shot, fine.
6. **`AlertThresholdSlider.onCommitted`** (`:23`) — single seam, single consumer
   (`PriceTrackingViewController.swift:366`). A delegate protocol here would be pure
   ceremony. Fine as-is.
7. Every `ShareSurfaceDriver` constructor-injected closure (`process`,
   `interopDecision`, `LunaShareSurface/ShareSurfaceDriver.swift:45,51`) is a
   textbook dependency-injection test seam (mock the pipeline/gate without touching the
   App Group), not cross-component "communication" — excluded from findings by the
   brief's own carve-out.
8. **`SavedNonTextualViewController.onDone` / `ShareReaderViewController.onDone` /
   `PasteboardMediaCardContentViewController.download` /
   `UndownloadedMediaCardContentViewController.download`** — all one-shot,
   constructor-supplied completion/action closures with a single call site each. Not
   findings, listed only to show the sweep was exhaustive.

**Net assessment**: the codebase has one consistent, deliberate house style — static
closure hooks for module-tier "main app installs behavior into a lower module" seams,
instance closures for one-shot completions. Finding #3 is the single genuine outlier
worth converting.

## 3. Findings — View/container boundary violations

1. **`ShareViewController` serves two different `NSExtensionPointIdentifier`s
   (`com.apple.share-services` / `com.apple.ui-services`) from one class**, branching on
   `isActionExtension` at 7 sites (`ShareViewController.swift:62, 70, 176, 504, 645,
   652`, plus the property itself at `35`). This is explained and deliberate (shared
   attachment-loading code, one Info.plist-driven flag), not accidental — but it means
   the class's control flow can't be read without holding the action/share distinction
   in your head for the whole file. **Not a defect; flagged as a complexity/boundary
   observation only** — a future split into `ShareExtensionHost`/`ActionExtensionHost`
   thin structs implementing `ExtensionHost` differently, with `ShareViewController`
   reduced to attachment-loading, would remove the branching but isn't free (both would
   still need the same `viewDidLoad` dispatch). Low priority given the existing doc
   comment already explains the tradeoff.
2. **`ShareReaderViewController` reaches directly into price-tracking's domain** for the
   `.product` outcome case (`ShareReaderViewController.swift:108-115`): it constructs a
   `PriceTracker` and calls `ReadingListStore.shared.savePriceTracker` itself, rather
   than delegating to the price module. This is the *reader* surface doing the *price
   tracker* persistence job that `ShareSurfaceDriver.persistTracker` already does
   elsewhere — see Duplication #1 immediately below; the boundary blur and the
   duplication are the same underlying issue.
3. No other boundary violations found. `PriceTrackingViewController` reaching into
   `LunaInteropUI` directly, and `ProductSearchOverlayViewController` constructing
   `ProductInfo` (a `LunaHTMLClassification` type) are both the designed, documented
   integration points (`claudedocs/interop-purchase.md`), not violations.

## 4. Findings — Duplicated or disjoint-but-related logic

1. **`PriceTracker` construction duplicated between `ShareReaderViewController` and
   `ShareSurfaceDriver`.** `ShareReaderViewController.swift:108-115`:
   ```swift
   case let .product(product, _):
       let tracker = PriceTracker(
           productName: product.name, stores: product.trackerStores(fallbackURL: url),
           brand: product.brand, productID: product.productID)
       ReadingListStore.shared.savePriceTracker(tracker, for: item.id)
       presentSavedConfirmation(productName: product.name)
   ```
   is byte-for-byte the same construction as `ShareSurfaceDriver.persistTracker`
   (`ShareSurfaceDriver.swift:263-271`):
   ```swift
   private func persistTracker(_ product: ProductInfo, url: URL) -> UUID? {
       guard let saved = store.item(forURLString: url.absoluteString) else { return nil }
       let tracker = PriceTracker(
           productName: product.name, stores: product.trackerStores(fallbackURL: url),
           brand: product.brand, productID: product.productID)
       store.savePriceTracker(tracker, for: saved.id)
       return saved.id
   }
   ```
   `ShareReaderViewController` is only reached when a standalone `Outcome` is presented
   outside the driver's own `present()` (its `precomputedOutcome` path exists for when
   it's shown directly rather than through `ShareSurfaceDriver`) — but the two code
   paths having independently re-derived the identical `PriceTracker(...)` construction
   is exactly the kind of divergence `SurfaceParityTests` (deleted, §0) existed to catch.
2. **`SavedNonTextualViewController.downsampledImage` duplicates
   `LunaDesignSystem.ImageDownsampling.decode` exactly**, despite `LunaShareSurface`
   already importing `LunaDesignSystem` (line 6) and already using it elsewhere
   (`ReadingListItemCell.decodeThumbnail` calls the shared helper). Compare
   `SavedNonTextualViewController.swift:801-813`:
   ```swift
   private func downsampledImage(from fileURL: URL, maxPixelSize: CGFloat = 1400) -> UIImage? {
       guard let source = CGImageSourceCreateWithURL(
           fileURL as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
       let options: [CFString: Any] = [
           kCGImageSourceCreateThumbnailFromImageAlways: true,
           kCGImageSourceCreateThumbnailWithTransform: true,
           kCGImageSourceShouldCacheImmediately: true,
           kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
       ]
       guard let cgImage = CGImageSourceCreateThumbnailAtIndex(
           source, 0, options as CFDictionary) else { return nil }
       return UIImage(cgImage: cgImage)
   }
   ```
   against `LunaDesignSystem/ImageDownsampling.swift:19-32` (identical CGImageSource
   options, same four thumbnail keys) — **and the duplicate is subtly *wrong* relative
   to the shared helper**: `ImageDownsampling.decode` returns `UIImage(cgImage:
   scale:orientation:)` with the caller's display scale, while
   `SavedNonTextualViewController`'s copy calls plain `UIImage(cgImage:)`, defaulting to
   scale `1.0` — meaning the extension's inline media preview can render at the wrong
   pixel density (up to 3× too large) versus what `ImageDownsampling` would have
   produced from the same file. `SavedNonTextualViewController` is also inconsistent
   within itself: its video poster path (`makeVideoPoster`, line 971-974) uses the
   *other* shared helper, `MediaPreviewFetcher.image(from:maxPixelSize:)`, while its
   ready-media inline preview path (`showReadyPreview`, line 519-547) uses the
   hand-rolled duplicate.
3. **The "save a local file to Photos, then flip storage state" sequence is duplicated
   between `SavedNonTextualViewController.saveToPhotos` and
   `SavedMediaCardsViewController.saveToPhotos`.** Compare
   `SavedNonTextualViewController.swift:682-701` (already-downloaded branch):
   ```swift
   let identifier = try await PhotoLibrarySaver().save(
       fileURL: fileURL, kind: kind, shouldMoveFile: false)
   _ = try SavedMediaStore.shared.transitionToPhotosReference(
       item.id, localIdentifier: identifier, kind: kind)
   ```
   against `SavedMediaCardsViewController.swift:319-343`:
   ```swift
   let tempURL = MediaDownloadStorage.newFileURL(extension: fileURL.pathExtension)
   try FileManager.default.copyItem(at: fileURL, to: tempURL)
   defer { try? FileManager.default.removeItem(at: tempURL) }
   let localIdentifier = try await photoSaver.save(fileURL: tempURL, kind: kind)
   _ = try store.transitionToPhotosReference(
       item.id, localIdentifier: localIdentifier, kind: kind)
   ```
   Same two-step "PhotoKit save → `transitionToPhotosReference`" sequence, independently
   written twice, with a real behavioral difference: `SavedMediaCardsViewController`
   defensively copies to a temp file first (so the original on-disk copy survives if the
   Photos save fails or is slow), `SavedNonTextualViewController`'s already-downloaded
   branch does not (its `.ready`-state branch at `:661-680` doesn't need to, since
   PhotoKit moves that file, but the `.alreadyDownloaded` branch saves the *library's
   own* file directly with no defensive copy — if `PhotoLibrarySaver().save` ever moved
   rather than copied on that path, the library's file would vanish on failure).
4. **The "delete: remove Photos asset if present, then delete from both stores" flow is
   duplicated between `SavedNonTextualViewController.deleteAndExit`
   (`:740-780`) and `SavedMediaCardsViewController.deleteSavedItem`
   (`:351-369`).** Both: conditionally `PhotoLibrarySaver().deleteAsset`, then
   `AutoDownloadSettings.unmarkDownloaded`, then delete the `ReadingListStore` item (if
   present), then delete the `SavedMediaStore` item. `SavedNonTextualViewController`
   additionally awaits `libraryPersistenceTask` first (a race unique to it, since the
   extension may still be persisting when the user taps delete) and orders the
   `ReadingListStore` deletion before the `AutoDownloadSettings.unmarkDownloaded` call
   rather than after — the two files agree on *what* to do but not the exact order,
   which matters if either operation is partially observable (e.g. a concurrent read
   between steps).
5. **This is the third and largest area of precise overlap the assignment asked to
   document between `SavedNonTextualViewController` (extension's single-item
   confirmation screen) and `SavedMediaCardsViewController` (Downloader app's carousel
   of every saved item).** Beyond #3/#4, both independently implement: "is this a video
   → show a poster + play overlay, tap to play in `AVPlayerViewController`" (compare
   `SavedNonTextualViewController.playVideo`/`previewTapped`,
   lines 583-620, against `SavedMediaCardsViewController`'s `VideoCardContentViewController`
   construction + `loadThumbnail`, lines 446-451/564-584) and "resolve a Photos-backed
   asset to a still image for preview" (compare `SavedNonTextualViewController.photosPreviewImage`,
   `:836-854`, against `SavedMediaCardsViewController.loadPhotosImage`, `:536-561` — same
   `PHImageManager.requestImage` shape, different target sizes/delivery modes). None of
   this is wrong, but the two files are solving the same five problems (video poster,
   Photos-asset preview, Photos-asset video-asset resolution, save-to-Photos, delete)
   independently, in two different modules, with no shared helper — a natural
   consolidation target (e.g. a `SavedMediaPreviewKit` used by both) if this surface
   grows further.

## 5. Findings — Overly complex code

1. **`PriceTrackingViewController` (706 lines)** combines table data source/delegate,
   threshold footer, price-history graph, add-seller flow, search-overlay presentation,
   interop-prompt presentation, and exit/navigation chrome in one type — broad rather
   than deep (no single method is a monster), but a "god object" by breadth. Not urgent
   per CLAUDE.md's anti-premature-abstraction guidance.
2. **`PriceTrackingViewController.addSeller`** (`:428-487`) performs its duplicate-seller
   check twice — once synchronously before the async price fetch, once again inside the
   `Task` after it — which is *correct* (the tracker can change mid-await) but
   uncommented, so it reads like copy-paste at a glance.
3. **`PriceTrackingManaging`/`PriceTrackingManager`** (`LunaPriceUI/PriceTrackingManager.swift`,
   39 lines) is a protocol+struct pair whose entire contract duplicates `PriceFetching`
   one-for-one, for exactly one call site (`PriceTrackingViewController`'s default
   `manager:` parameter). Redundant indirection, not incorrect.
4. **`ProductSearchOverlayViewController`** mixes Auto Layout (card, bottom bar) with
   fully manual `CGRect` frame math for the card's internal chrome
   (`layoutCardContents()`, `:265-287`, recomputed every `viewDidLayoutSubviews()`) —
   an unusual two-layout-system split within one view controller.
5. **`ShareViewController.viewDidLoad`** (`:57-139`) is a single 82-line cascading
   `if`/`guard` chain classifying five different attachment shapes (JS-preprocessing
   plist → web URL → document → fallback URL → text) in strict priority order, each
   documented but none factored into a named classification function — readable
   top-to-bottom, but a single change to the ordering logic has to be made inside this
   one long method rather than in an isolated, unit-testable classifier. (This exact
   classification logic is one of the things `ShareKitScreenTests.swift`'s
   `testActionPreprocessingDecodesWrappedPropertyListData`/`testActionPreprocessingAcceptsDirectPayload`
   used to test directly — now untested per §0.)
6. **`SavedNonTextualViewController.applyMediaState`** (`:338-410`) is a 6-way switch
   over `MediaState` that individually sets ~8 UI properties per case with no shared
   helper for the properties that repeat across 4 of the 5 cases (`previewSpinner.stopAnimating()`,
   `pendingIconView.isHidden`, `previewImageView.isHidden`, `playOverlay.isHidden`,
   `previewPlaceholder.isHidden` are each set in 4-5 of the 5 branches, sometimes to the
   same value) — a "reset to defaults, then override what this state needs" structure
   would cut the method roughly in half without changing behavior.
7. **`SaveIntent.perform()`** (`Luna/Mail/Intents/SaveIntent.swift:93-219`, ~127 lines,
   from the LunaIntents sub-audit) is the single largest orchestration function across
   all six modules — six sequenced concerns (double-press short-circuit, prompt
   selection, model invocation + error translation, per-platform save + a second error
   translation, outcome switch, media-download call, dialog-string construction), though
   each step delegates outward with no reimplemented logic (verified clean per the
   sub-audit).

## 6. Findings — Dead/unused code

Every claim below is a grep result, run against the full repo (all 3 apps, both
extension source trees, `LunaTests`) excluding `.build*` and stale worktrees.

- **None found in `LunaShareSurface`, `LunaReadingListUI`, `LunaSafari`, `LunaShare`,
  `Luna Action Extension`, `LunaReaderClip`, or `SavedMediaCardsViewController`.** Every
  public type/method traced to a real call site:
  - `find . -name "*.swift" -not -path "*/.build*" -not -path "*/.claude/worktrees/*"
    -print0 | xargs -0 grep -l "<Type>"` for `ShareViewController`,
    `SavedNonTextualViewController`, `ShareSurfaceDriver`, `ShareReaderViewController`,
    `ExtensionReaderShareProvider`, `ActionReaderMode`, `SharedReadingListAppender`,
    `ExtensionHost` — every one resolves to ≥1 real caller beyond its own declaration
    file (documented per-type above in §1).
  - `ReadingListItemCell`/`DownloaderProgressFooterView`/`MediaDownloadStatusView`/
    `ReadingListSectioning`/`ReadingListSubtitle`/`ReadingListDiff`/`ReadingListGroup`/
    `AppSurface` — same sweep, all live (§1).
- **One near-miss, not dead but worth a note**: `ShareViewController.javaScriptResult(from:)`
  / `javaScriptResult(fromPropertyListData:)` are `public` specifically per their doc
  comment "Internal for regression tests" — but the regression tests that exercised
  them (`ShareKitScreenTests.testActionPreprocessingDecodesWrappedPropertyListData`/
  `testActionPreprocessingAcceptsDirectPayload`) were deleted in the §0 regression.
  `grep -rn "javaScriptResult" LunaTests/*.swift` → **zero results**. The `public`
  visibility is now unused by anything except the production call site inside the same
  file — not dead code (still called in production), but the *reason* it's `public`
  (test access) no longer holds.
- **`PriceTrackingViewController.swift:320-322`** — an empty `// MARK: - Threshold
  footer` section marker with no code beneath it before the next `// MARK:` at `:322`;
  the actual threshold-footer code (`makeThresholdFooter()`/`syncThresholdControl()`)
  lives elsewhere in the file (`:362`+), outside this marked region. Leftover structure
  from a prior reorganization — not dead code, but an orphaned section header.
- From the LunaIntents/LunaPriceUI sub-audits: no dead code found in either scope either
  (every type/method grepped to a live caller or a live test).

## 7. Findings — Comment hygiene

Change-narration / "what it doesn't do" / stale-reference comments, each with a
concrete rewrite.

1. **`ShareSurfaceDriver.swift:150-153`**:
   ```swift
   case let .product(product, _):
       // Persist the tracker, then present the SAME price-tracking editor the
       // main app shows (the extension host wraps it in Done chrome). Previously
       // both extensions only saved silently + showed a checkmark.
       presentPriceEditor(product: product, url: url)
   ```
   The last sentence narrates a past behavior change with no present-tense value.
   **Rewrite**: delete the sentence "Previously both extensions only saved silently +
   showed a checkmark." entirely; keep the first two lines.
2. **`ShareSurfaceDriver.swift:328-333`**:
   ```swift
   /// A paywalled article: EVERY surface opens the same `ArchiveWebReaderViewController`
   /// (the archive-CAPTCHA reader, URL pre-filled), identically to the main app — so the
   /// presentation intent matches across surfaces (it used to diverge: the action
   /// extension wrapped it in `ShareReaderViewController`). On a successful extract the
   /// action extension swaps in the in-sheet native reader showing the captured content;
   /// the zero-UI share extension confirms the save.
   ```
   **Rewrite**: drop the parenthetical `(it used to diverge: the action extension
   wrapped it in ShareReaderViewController)` — the sentence reads identically and more
   clearly as "...identically to the main app, so the presentation intent matches across
   surfaces. On a successful extract...".
3. **`SavedNonTextualViewController.swift:654-656`**:
   ```swift
   /// Requests Photos add access and saves the downloaded file, then marks the item
   /// READ in the reading list (new behavior — saving counts as consuming it). Only
   ```
   **Rewrite**: `/// READ in the reading list (saving counts as consuming it). Only` —
   drop "new behavior —".
4. **`SharedReadingListAppender.swift:16-18`** (borderline — this is the repo's own
   "explain the why" convention, referencing a past bug to justify the current design
   choice, which the repo's other conventions treat as acceptable; flagged only because
   it's the most narration-heavy instance found in this scope):
   ```swift
   /// struct and re-encoding it used to silently drop any field the mirror didn't
   /// know about — e.g. `platform`/`sendStates` — corrupting other items.)
   ```
   If tightened: `/// struct and re-encoding it would silently drop any field the mirror
   /// doesn't know about — e.g. `platform`/`sendStates` — corrupting other items.)` (shifts
   from narrating a historical incident to stating the general risk the current design
   avoids — same information, no "used to").
5. **Stale file-header module names in `LunaPriceUI`** (from the sub-audit,
   `grep "^//  " LunaLibraries/Sources/LunaPriceUI/*.swift`):
   `PriceTrackingViewController.swift:3` and `PriceGraphView.swift:3` say `// ShareKit`;
   `AlertThresholdSlider.swift:3`, `InAppBrowser.swift:3`, `PriceFetcher.swift:3`,
   `PriceRefresher.swift:3`, `PriceTrackingManager.swift:3`,
   `ProductSearchOverlayViewController.swift:3` say `// Luna`;
   `ProductPageSuggestion.swift:3`, `ProductSuggestionDebouncer.swift:3` say
   `// ReaderKit`. None of `ShareKit`/`Luna`/`ReaderKit` is a real target
   (`grep "ShareKit\|ReaderKit" LunaLibraries/Package.swift` → zero hits) — these are
   Xcode file-template relics from before the module was assembled as `LunaPriceUI`.
   **Rewrite**: `//  LunaPriceUI` in all 8 files, or delete the header line.
6. **`AlertThresholdSlider.swift:27`** and **`Luna/CatchUp/CatchUpSubviews.swift:494`**
   (the latter outside this audit's file list, but the matching half of the same
   comment): `/// De-glassed (Task 3): a solid rounded pill...` — an internal ticket
   reference ("Task 3") meaningless outside that ticket, narrating why it changed rather
   than describing current behavior. **Rewrite**: `/// A solid rounded pill (no blur) —
   it sits on the editor / catch-up card's solid background, so a live blur would add
   little and can't be captured consistently across presentation contexts.`
7. **`LunaIntents/AppNamePlatform.swift:3`** — file header reads `//  Luna`; every other
   file in the directory reads `//  LunaIntents` (`grep -l "^//  Luna$"
   LunaLibraries/Sources/LunaIntents/*.swift` → only this file). **Rewrite**: `//
   LunaIntents`.
8. **`LunaIntents/ArticleMatcher.swift:9`** — doc comment cites `Luna/Intents/ArticleEntity.swift`;
   the real path is `Luna/Mail/Intents/ArticleEntity.swift` (`find . -iname
   ArticleEntity.swift` confirms). **Rewrite**: fix the path in the doc comment.
9. **`LunaIntents/PlatformFieldSave.swift:16`** — "There is no music/podcast case (that
   platform support was retired in `7c34cd69`)" ties a current invariant to a commit
   hash that will be meaningless once it ages out of memory. **Rewrite**: `//
   LunaPlatforms.ContentPlatform has no music/podcast case.` (states the current fact
   only).

No other "used to"/"no longer"/"NEW:"/"FIXED:" comments were found across the full
scope beyond the ones listed — the codebase's comment style is otherwise consistently
"why," not "what changed," matching the repo's stated convention.

## 8. Findings — Animation structure

- **`ShareViewController.showSavedBadge`/`showDownloadingBadge`** (`:589-630`,
  `:541-573`) — spring-animated liquid-glass badges (`usingSpringWithDamping: 0.65`),
  scale 0.7→1.0 + fade-in on `showSavedBadge`; `showDownloadingBadge` has no entrance
  animation of its own (appears instantly), which is a visible asymmetry between the two
  badges shown in the same flow (auto-download start vs. finish) — minor polish gap, not
  a defect.
- **`DownloaderProgressFooterView`/`MediaDownloadStatusView`** — both use a plain
  `UIView.animate(withDuration: 0.25/0.3)` alpha fade for reveal/hide, no spring, no
  crossfade between content changes (a mid-flight `apply(_:)` call while already visible
  swaps title/progress instantly, only the initial reveal/final hide animate) — consistent
  and appropriately minimal for a status pill.
- **`ReadingListItemCell`**'s art crossfade (`applyArt(fadeIn:)`, `artFadeInDuration =
  0.2`) only fires for a genuine cache-miss decode landing on an empty well — a cache
  hit or an already-visible image is applied instantly with no fade, which is the
  correct choice (fading a synchronous same-frame set would be a needless flash).
- **`ProductSearchOverlayViewController`** presents `.overFullScreen` with a hand-rolled
  `dimView` that has no fade-in of its own (system default cover-vertical transition
  only) — comparatively less animation care than `ShareViewController`'s badges in the
  same audit scope.
- **`PriceGraphView`** — no animation; scrubber callout show/hide is an instant
  `isHidden` toggle, and redraws are instant `setNeedsDisplay()` — reasonable for a
  `draw(_:)`-based chart.
- **`InteropPromptViewController`/`InteropPaywallViewController`** — standard system
  push/modal-sheet transitions only, nothing custom.
- **`SavedMediaCardsViewController`**'s `CircularDownloadProgressView.progress`
  (`:832-842`) uses an explicit `CABasicAnimation` on `strokeEnd` (0.2s) layered under a
  direct `progressLayer.strokeEnd = clamped` set — i.e. it sets the model value directly
  AND adds an animation from the presentation layer's current value, which is the
  correct pattern for smooth incremental updates driven by frequent notification ticks
  (`.downloaderJobProgressChanged`) without needing `CADisplayLink`. No finding — this is
  the most animation-careful code in the whole audit scope.

## 9. Test coverage note (all six modules)

| Module | Well-covered | Thin/no coverage |
| --- | --- | --- |
| `LunaShareSurface` | Interop-gate behavior (`ShareSurfaceDriverInteropTests`, 9 tests); audio-script write-on-save (`ExtensionAudioScriptWriterTests`) | **The non-interop `Outcome`-presentation behavior of `ShareSurfaceDriver.present()`** (article/video/social/document/archive routing + persistence) — only indirectly touched by the interop tests' "untouched" assertions. `SavedNonTextualViewController`'s media state machine, `ShareReaderViewController`, and `ShareViewController`'s attachment-classification cascade — **zero** direct tests (all lost in §0) |
| `LunaReadingListUI` | `ReadingListDiff` (`ReadingListDiffTests`, 8 tests) | `ReadingListSectioning` (lost 46 tests in §0; only incidental coverage now), `ReadingListSubtitle` (lost 22 tests in §0; **zero** coverage now), `ReadingListItemCell` (no dedicated file, ever, other than the deleted `ReadingListScreenTests`), `DownloaderProgressFooterView`/`MediaDownloadStatusView` (no test file) |
| `LunaPriceUI` | `PriceFetcher`/`PriceRefresher`/`ProductPageSuggestion` well tested | `ProductSearchOverlayViewController` (**zero** — including its hand-written Google-Shopping JS bridge), `PriceTrackingManager`, `AlertThresholdSlider`, `PriceGraphView`, `InAppBrowser`, `PriceUIAlerts` |
| `LunaPriceMetadata` | Package-level `ProductMetadataParsingTests` (1 case) | — |
| `LunaInterop` / `LunaInteropUI` | Extensively tested (`InteropGateTests`, `InteropEntitlementTests`, `InteropPurchaseControllerTests`, `InteropSurfaceTests`, `InteropSettingsTests`) | `InteropPaywallViewController`'s purchase-flow UI only indirectly via `InteropSettingsTests` |
| `LunaIntents` | Near-total: every non-UI file has a dedicated test file | `ScreenCaptureModelSession`/`Factory`/`FoundationModelsScreenCaptureSession` (untestable without a real device by nature; decision logic downstream is tested instead — appropriate, not a gap) |
| `Luna/Mail/Intents` | Delegated logic covered transitively via `LunaIntents` tests | The `AppIntent`/`AppEntity`/`AppShortcutsProvider` definitions themselves have no direct test (typical/expected for this type) |
| Extension targets (`LunaSafari`/`LunaShare`/`Luna Action Extension`/`LunaReaderClip`) | — | No dedicated test files for any of the four (expected — these are principal-class/link-anchor/App-Clip shells; their logic is tested through `LunaShareSurface`'s tests where it exists) |

---

## Top 10 highest-value changes (ranked)

1. **[L] Restore behavioral test coverage for the §0 regression**, prioritized:
   `ReadingListSectioningTests`-equivalent (46 cases covering section assignment, catch-up
   queue, dot logic — currently zero dedicated coverage for logic that gates a red UI
   badge users see constantly), then a `ShareSurfaceDriverTests`-equivalent restoring
   coverage of the non-interop `Outcome` → presentation/persistence behavior (the
   current `ShareSurfaceDriverInteropTests` only covers the gate wrapped around it), then
   `ReadingListSubtitleTests` (22 cases, currently zero coverage) and a
   `SurfaceParityTests`-equivalent (the class of regression it existed specifically to
   catch — cross-surface divergence — is exactly what a strictly-behavior-preserving
   refactor of this exact scope could introduce without anyone noticing).
2. **[M] Convert `ProductSearchOverlayViewController.onUseThisPage` to a delegate
   protocol** — the clearest stored-callback-to-protocol conversion candidate found (§2
   #3): a 3-argument closure with a nested completion callback, functioning as a
   delegate method in disguise.
3. **[S] Route `ShareReaderViewController`'s `.product` case through
   `ShareSurfaceDriver.persistTracker` instead of re-deriving the `PriceTracker`
   construction** (§4 #1) — removes the exact category of silent divergence
   `SurfaceParityTests` used to catch, in the one place this audit found it already
   happening.
4. **[S] Replace `SavedNonTextualViewController.downsampledImage` with
   `LunaDesignSystem.ImageDownsampling.decode`** (§4 #2) — not just deduplication: the
   hand-rolled copy silently omits the display-scale argument the shared helper takes,
   a real (if minor) rendering-fidelity bug in the extension's inline preview.
5. **[M] Consolidate the "save-to-Photos-then-transition" and "delete" sequences shared
   by `SavedNonTextualViewController` and `SavedMediaCardsViewController`** (§4 #3/#4) —
   two independently-written, slightly-inconsistent copies of security/data-integrity-
   relevant logic (defensive temp-copy present in one, absent in the other; operation
   ordering differs) are a natural source of a future real bug, not just style debt.
6. **[S] Delete the orphaned `// MARK: - Threshold footer` empty section**
   (`PriceTrackingViewController.swift:320`) and relocate the threshold-footer code under
   it, or remove the marker.
7. **[S] Fix the 9 comment-hygiene items in §7** — all are one-line rewrites/deletions,
   zero risk, immediate readability win (especially #1/#2, which are the clearest
   "narrates a diff, not the code" instances in the whole audit).
8. **[S] Unify `AlertThresholdSlider`'s pill chrome with
   `CatchUpPriceTrackerCardBody.makeThresholdReadout`'s read-only mirror** (flagged by
   the sub-audit) — ~35 lines of near-identical layout code across two files, already
   self-acknowledged as mirrored in both files' comments.
9. **[M] Add test coverage for `ProductSearchOverlayViewController`**, at minimum the
   Google-Shopping JS-bridge message handler and the auto-detection debounce — currently
   the only piece of hand-written JavaScript-bridge logic in the two price/share modules
   with zero verification of any kind.
10. **[S] Collapse `PriceTrackingManaging`/`PriceTrackingManager` into direct
    `PriceFetching` usage** — removes an 18-line indirection with one call site and no
    behavioral difference from the protocol it wraps.
