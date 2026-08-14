# Tree-shake & impossible-states pass — August 2026 (plan)

Companion to `test-value-sweep-2026-08.md`. Two forces:
- **Tree-shake**: code with zero production references is deleted, not kept "in case".
  "Test-retained" code (prod decl whose only callers are tests) goes with its tests.
- **Make impossible states unrepresentable / parse, don't validate** (Lexi Lambda):
  raw values are parsed ONCE at the boundary into a type that cannot express the
  invalid combinations, instead of being re-validated at every use.

Every item was verified by grep across all prod targets (LunaLibraries, Luna/,
LunaShare, LunaAction, LunaSafari, both Clips, the Live Activity) and LunaTests.
Deliberately untouched: KindWiring/kind-pack composition machinery, documented
cross-tier injection closures, UI delegate protocols, `-LunaStage` seams,
`@available(iOS 26)` code, the LunaSafari hand-copy parity anchors.

## Phase B — dead code deletions (zero risk, commit as one or two chunks)

Whole files:
- `LunaModels/AppEnvironment.swift` — 0 refs repo-wide; real gates use `#if targetEnvironment(simulator)`.
- `LunaMediaDownload/MediaItemProvider.swift` (95 lines) — the feature that used it was removed; update `claudedocs/media-download.md` §"Pasteboard providers" + :533.
- `LunaMediaDownload/MediaPreviewFetcher.swift` (36 lines) — 0 refs.
- `LunaPaywallBypass/BypassRuleTable.swift` — test-retained (4 BypassTests funcs go with it; behavior lives in `Classifier.isHardPaywallHost`).

Members (0 refs each unless noted):
- `ProductIdentifiers.normalizedSKU` (LunaModels:53); `ReadingListItem.canShareToFriends` (:207)
- `SaveFailureReason.unsupportedDocument` — unconstructable case (+4 switch arms; + its row in FailedSaveTests:78)
- `ReadingListStore.setLastScrollOffset`/`setReadingProgress`/`deleteItems(ids:)` (LunaStorage:411/435/480)
- `LunaColors.tertiaryGroupedBackground`/`opaqueSeparator` (LunaDesignSystem:29/41)
- `LinkListCSV.archiveSectionValue` (LunaURLClassification:20)
- `BypassStrategy.runsSilently` (LunaPaywallBypass:65-72) + fix stale type doc; clean stale prose in claudedocs/readers.md:888, claudedocs/audit/06-paywall-bypass.md
- `FailedSaveNaming.displaySiteName` (LunaFetch:36-41) + FailedSaveTests:126-129 (the `PageMetadata.siteName` fetcher leg STAYS — it has real consumers)
- `FailedSaveNaming.displayURL` forwarder (:45-51) — point `FailedSaveCardFactory.swift:53` at `FailedSaveCopy.displayURL`; drop FailedSaveTests:136-141
- `LiveMediaDownloadManager.currentDownloadProgress(forSourceURLString:)` (:709-711)
- `NotificationManager.hasEverRequestedAuthorization` (LunaSocial:61-68) + fix its doc
- `FriendsStore.isFriend(_:)` (:116) + its one FriendsStoreTests assertion
- `Array<MediaAsset>.firstDirectlyPlayable` (LunaMediaResolve/MediaAsset+InlinePlayback.swift:33-38) + SafariVideoOverlayTests:646-647
- `PlatformRegistry.detect(_:)` (LunaPlatforms:33-36) + `testRegistryDispatchesAcrossPlatforms` + `testRegistryClassifiesBluesky`; update claudedocs/url-pipeline.md:256. Also `init(modules:)` → plain `init()` (no caller passes modules).
- `WeeklySaveRefresher.proposalsDidChange` (LunaWeekly:31-32,:194) — posted, never observed (the proposals screen reloads in viewWillAppear).
- `SellerComparison.runAndAttach` (LunaPriceUI:214) — test-retained; delete + its 7 SellerComparisonTests refs (`begin`/`complete` are the live API).
- `ProvideContextOnScreenURL.collapse`/`.collapseText` (LunaIntents/ProvideContextDecision.swift:39/:50) — retarget ProvideContextOnScreenURLTests at `resolveText`/`resolve`.
- `MailAuthKind` + `MailProvider.authKind` (LunaMailAccount:10/:68 + 5 write sites) — written, never read. Also `FilterSupport` + `filterSupport` (:19/:69): the one read is `filterSupport == .automatic && id == .outlook`, where the second conjunct subsumes the first → `FilterGuide.isAutomatic` becomes `id == .outlook`. Align the ported FilterGuideTests.
- `PasteboardSuggesting` protocol (LunaReadingList/PasteboardSuggester.swift:46) — one conformer, type never used.
- `PriceTrackerTagIcon` (LunaPriceUI/ProductArtwork.swift:108-152) — 0 refs.
- `ReadingListIngestor.saveAsArticle` (:633) + stale doc ref at :85 — the "Read instead" button it backed is gone.
- `PriceRefreshOutcome.previousBest` (LunaPriceUI/PriceRefresher.swift:35,:134) — write-only; + its one test line.
- `AudioSessionCoordinator.Action.none` (LunaAudioPlayback:26) — replace the one producer with `if options.contains(.shouldResume) { actionHandler?(.resume) }`; rewrite the one AudioPlaybackSupportTests assertion as "no action emitted".
- `ArticleEmailSending` protocol + `sender:` param (LunaSend/ArticleSendCoordinator.swift:35/:49/:83) — 0 external refs; `KindleDestination` holds concrete `AccountEmailSender`.
- `ArticleExportService.writeEPUB` (:162) + `.itemProvider` (:169) — test-retained; delete + their 5 ArticleExportServiceTests lines.
- `FinishedReadingBadgeView` DEBUG block (LunaReaderUI:246-261) — 7 `…ForTesting` members, zero readers.
- `ReaderAudioLauncher.ownsPlayback(of:)` (:38); `GazeCalibration.isEstablished` (:60); `RabbitHoleLayerViewController.isSavedInLibrary` (:139)
- `LiveNetworkPolicy.legacyOptInEnvironmentKeys` (LunaModels:43) — 0 refs even in tests.
- App shell: `UITestSeeder.isUITestLaunch` (:45); `CardKindPresenter.isSurfaced(_:)` (:363); `InstalledAppMarkers.isInstalled(_:)` (:29); `EmailLoginShared.setLoading(_:)` (:134); `ArchiveTrayController.arcLayoutForTesting` (:354).
- Dead write-only feature: the `pendingSendFailureNotices` path — `SendFailureNotice` + `consumePendingSendFailureNotices` (ReadingListStore.swift:562-592, consumer has 0 callers), the 3 write sites (:510,:538,:557), the persisted field on `ReadingListItem` (:135,:243,:304,:407), and the 2 ArticleSendCoordinatorTests assertions (:164,:265). (Product-leaning call: the toast it fed was never built; decode of old JSON is unaffected — unknown keys are ignored.)
- `LunaDeepLink.readLink` (:53-61) + `resolvedMediaLink` builder (:99-104) — only JS builds these links (content.js:2373/:2295); Swift only parses. Rewrite LunaDeepLinkTests:28-29 and SafariVideoOverlayTests:559 to parse literal URL strings shaped exactly like the JS output (a better pin). Keep `resolvedMediaHost` + all parsers. Fix stale claim in claudedocs/readers.md:571.
- `WrapperKind`, `UnwrapResult.wrapper`, `WrapperHandler.kind` (LunaURLClassification/URLUnwrapper.swift:11-18,:32,:50 + kind: args) — telemetry payload with no telemetry; prod reads only `didUnwrap`. Rewrite the ~12 URLUnwrapperTests assertions to assert the unwrapped URL.

Seam bridges:
- `ProductTrackerMerge.snapshotProvider` global (LunaPriceUI:26) — prod mutates a global on every ingest purely to bridge a test seam (`ProductTrackerIngestor.swift:59`). Make it a parameter: `mergeIfPossible(..., snapshots: [ProductSnapshot] = ProductSnapshotStore.shared.load())`; both prod call sites pass through; delete the global + the :59 assignment; update the 3 test files.
- `PriceGraphView.thresholdDragGestureRecognizer` (:81) — wrap in `#if DEBUG` (one test reader, zero prod).

INVESTIGATE (decision rule, don't guess): `ProductSnapshotStore.makeSnapshot` (LunaPriceUI:78)
mirrors `LunaSafari/SharedProductSnapshots.makeRecord` and has 0 prod callers. If the
LunaSafari file is already compiled into the LunaTests target (check how the other
`Shared*.swift` parity suites reference it), retarget SharedProductSnapshotsTests /
FreshComparablePricesTests at the real `makeRecord` and delete `makeSnapshot` +
`decimalString` (keep `dayString`, it is live). If it is NOT visible to tests, leave
everything as is — the copy is then the parity anchor, per the documented hand-copy pattern.

## Phase D — impossible states / parse-don't-validate refactors

Each is contained; do one commit per item. If one snowballs, stop, leave it, note it.

D1. `ArticleContent.Block.imageWidth/imageHeight: Int?` pair → `imageSize: BlockImageSize?`
    (`struct BlockImageSize: Codable, Equatable { let width: Int; let height: Int }`),
    custom decode reads the two legacy keys (on-disk back-compat), encode may emit the
    new nested shape. Call sites: ArticleExtractor.swift:1084, ArticleTextRenderer.swift:220,
    ArticleImageDownloader.swift:46/62, ShareReaderViewController.swift:126,
    ArticleDOCXBuilder.swift:265/273 — the four `== nil ||` disjunctions become `if let`.

D2. `SavePressPolicy.decide` — `intentAction: IntentAction?` + `doubleSaveDestinationIDs`
    are mutually exclusive → `enum SavePressRegime { case inApp(doubleSaveDestinationIDs: [String]); case actionButton(IntentAction) }`;
    consolidate the three `.isEmpty → .ignore` guards to one place. Callers:
    ReadingListIngestor.swift:436-600, DoubleSaveTests. (No NonEmpty wrapper type.)

D3. `PreloadStore`: delete `PreloadState`/`state` (fully derived from `kind`) and
    `PreloadPlatform`/`platform` (write-only). Preferred full form:
    `enum PreloadPayload: Codable { case article(contentFile: String, children: [String]); case skipped }`
    replacing `kind`/`contentFile` — the store is a rebuildable cache, decode drops
    unparseable entries. Fall back to the two plain deletions if it snowballs.
    Touch: PreloadStore.swift, PreloadCoordinator.swift:259-260, PreloadStoreTests.

D4. `ReadingListStore.saveReaderExitPosition(scrollOffset: Double?, clearScrollOffset: Bool)`
    → single `scrollOffset: ScrollOffsetEdit = .unchanged` with
    `enum ScrollOffsetEdit { case unchanged, clear, set(Double) }`. Callers:
    RSVPViewController.swift:1854, LinkRSVPPreview.swift:760,
    RabbitHoleReaderViewController.swift:552 (currently derives the bool from the
    payload — the tell), ScrollReaderViewController, OriginalPageViewController.

D5. `SiteUnlockRule` (LunaPaywallBypass): delete the 9 decoded-never-read fields
    (headersCustom, randomIP, removeCookiesSelectHold, ldJson, ldJsonNext, ldJsonSource,
    ldJsonUrl, ampUnhide, ampRedirect) + `csDompurify` (drop its SiteUnlockTests:109
    assertion). Then replace the `useragent`/`useragentCustom` + `referer`/`refererCustom`
    optional pairs with enums parsed once at the JSON boundary:
    `enum UserAgentSpoof { case crawler(CrawlerAgent); case custom(String) }`,
    `enum RefererSpoof { case origin(RefererOrigin); case custom(String) }` —
    `SiteUnlockSilent.crawler(for:)` disappears; `fetchKind` becomes a two-case switch.
    Touch: SiteUnlockRules.swift, SiteUnlockSilent.swift, ArchiveWebReaderViewController.swift:363, SiteUnlockTests.

D6. `BypassGate` decision — collapse the write-only `Signal` payload (BypassGate.swift:40-55)
    to what consumers read: `case attempt; case block(reason)` (keep `allowsBypass`,
    `== .block(.notPaywalled)` working). Ported BypassScenarioTests asserts `.attempt`.

D7. `ArchiveWebReaderViewController.decideStage(_ stage: String, …)` → parse the probe
    result once: `enum ProbedStage { case error, blocked, homepage, challenge, contentRoot,
    waiting, text(String); init(rawProbe: String) }` — the ONE place the JS literals live;
    raw-string comparisons at :638-655 and :814-853 become enum switches.
    ArchiveStageDecisionTests converts mechanically. Also inline
    `uncoversPageAfterExtraction(hasExtractedHandler:)` (:1048-1050, body = `!arg`) at :1013
    (keep the comment) and delete its 2 assertions (ArchiveStageDecisionTests:129,134).
    Also simplify `onGaveUp: (GiveUpReason) -> Void` → `() -> Void` (sole subscriber
    discards the payload; delete `GiveUpReason` :47-52).

D8. Drop the `render:` closure threaded through the ingest pipeline
    (IngestPipeline.swift process/processResolved/runUnbounded/processWeb;
    IngestKindProcessors.swift:32; ProductIngestProcessor.swift:24/27) — production
    callers all leave it nil (the doc says so) and no pipeline test uses it.
    `ProductMetadataExtractor.extract(url:html:render:)` KEEPS its parameter (directly tested).

D9. `LiveMediaDownloadJob.mediaKind: String` → `mediaKind: MediaAsset.Kind?` — fixes a
    real latent defect: three producers write three incompatible encodings ("gif" vs
    "animatedImage" vs "unknown"), so a rescue-path GIF round-trips as `.image` and
    badges as `.unknown`. Decode with `decodeIfPresent` + legacy map
    ("animatedImage"/"gif" → .gif, "unknown" → nil). Delete `mediaAssetKind` and
    `MediaAsset.Kind.liveActivityKind`; `LiveMediaDownloadAttributes.MediaKind` gains
    `init(_ kind: MediaAsset.Kind?)`. The widget's own enum keeps its cases — the
    Live Activity target must still compile. Touch: LiveMediaDownloadJob.swift,
    LiveMediaDownloadManager.swift, +ActivityKit.swift, LiveMediaDownloadActivity.swift,
    3 test files.

D10. `LiveMediaDownloadJob.rangeStartSeconds/rangeEndSeconds` → `timeRange: MediaTimeRange?`
    (existing LunaModels type). The four `!= nil ||` sites collapse to
    `job.timeRange?.isEffective == true`, matching the asset-side predicate. Decode the
    two legacy keys into the new field so in-flight jobs survive an update.

D11. `LiveMediaDownloadJob.resolveKind: String?` → `resolveKind: ResolveKind?` — make
    `ResolveKind` Codable and ADD the two cases the hand-written literals smuggle in
    ("rescue" at :387, "direct" at :446 — today they parse back to nil). Legacy decode
    via `init(rawValue:)`.

D12. `AutoDownloadSettings` backing prefs (`wifiOnlyDownloads`, `autoSaveDownloadsToPhotos`,
    `autoDownloadMediaInPreview`) → setters non-public so `AutoDownloadSettings.policy`
    and `MediaStorageSettings.option` are the only mutators (the `-LunaStage` seam at
    StageCatalog+Media.swift:201 keeps whatever access it needs); the now-unreachable
    `.never` re-normalizations at MediaStorageSettings.swift:80/:90 are deleted.
    Tests write through `policy`/`option`.

D13. `ReaderShareSheet.Row`: delete `isPrimary` (false at all 8 construction sites; its
    true-arm is unreachable; ReaderShareSheetTests even asserts it's always false —
    remove that assertion). Then `children` + `action` (documented "when non-empty,
    action is not used") → `enum Behavior { case tap(() -> Void); case submenu([Row]) }`
    with `Row.action(...)`/`Row.submenu(...)` factories; both consumers become total
    switches. Touch: ReaderShareSheet.swift, MediaCardFactory.swift,
    AppReaderProviders.swift, ReaderShareSheetTests; one-line edit in
    claudedocs/article-export.md:166.

D14. `MailCursor` — struct with two mutually exclusive halves shredded into 3 defaults
    keys → `enum MailCursor: Codable, Equatable { case fresh; case imap(uid: Int, validity: Int); case graph(token: String) }`;
    drop the optional at the `EmailTransport.fetchShares` boundary (`.fresh` is the zero);
    persist as ONE JSON blob under a new `incomingMailCursor` key in IncomingMailSettings,
    migrating from the three legacy keys on first read. Touch: EmailTransport.swift,
    IncomingMailSettings.swift, IncomingMailImporter.swift, StreamIMAPClient.swift,
    GraphMailTransport.swift, IMAPSMTPTransport.swift, EmailAccountTests:554/559.

D15. `FailedSaveCardModel` — `isRescuing`+`progress`+`canRescue`+`hasSpentAIAttempt`
    → `enum RescueState { case idle, running(progress: Double), spent, unavailable }`.
    Touch: FailedSaveCardViewController.swift:31-41, FailedSaveCardFactory.swift:50-61,
    StageCatalog+Shared.swift:319-371 (whose three bool overrides become three states),
    FailedSaveTests:343.

D16. `PasteboardCandidate` — `content?`/`platform?`/`requiresUnlock` (16 combos, 3 reachable)
    → `enum Kind { case platform(ContentPlatform); case article(ArticleContent); case lockedArticle }`
    alongside shared urlString/title/thumbnail. Grep consumers in Luna/UtilCard first;
    if destructuring spreads beyond ~3 files, stop and note.

D17. `doubleSaveActionSurface: String?` threaded through LunaReadingList/LunaIntents →
    `enum DoubleSaveSurface { case luna, reader }` parsed once (single `LunaApp →
    DoubleSaveSurface?` mapping replaces the duplicated switches at
    ProvideContextIntent.swift:409-414 and SettingsViewController.swift:219-224);
    `rawValue` only at the DoubleSaveActionStore defaults-key edge.

D18. `AudioScriptCacheEnvelope` — `refined: Bool` + `llmPermanentlyFailed: Bool` (the
    both-true state is meaningless) → `enum RefinementState: String, Codable
    { case heuristicOnly, refined, permanentlyFailed }`. No migration: bump
    `AudioScriptStore.currentBuilderVersion` and stale envelopes rebuild.
    Touch: AudioScriptStore.swift, AudioScriptPipeline.swift, AudioScriptSupportTests.

D19. `AudioPlaybackCenter.stateBeforePause: AudioPlaybackState?` (can only ever be
    playing/announcing) → `private enum ResumeTarget { case playing, announcing }`.

D20. `RSVPViewController` chunk-timer trio (`timer?`/`intervalStart?`/`intervalDuration?`,
    cleared inconsistently at :1488/:1770) → `private struct ChunkTimer { let timer: Timer;
    let start: Date; let duration: TimeInterval }`, one optional, invalidate+clear in one place.

D21. `RabbitHoleLayerDescriptor.url` — store `URL`, Codable through `urlString`; the 8
    re-parse `guard let` sites disappear. (The reading-anchor enum and non-empty stack
    are deferred — persisted-JSON migration.)

D22. `ScrollReaderViewController` progressive-load bools (`didLoadFullContent` +
    `didBeginFullContentLoad`) → `private enum FullContentLoad { case pending, inFlight, done }`.

D23. `DocumentParser` — extension string switched twice against two inline lists + a
    third (`readableExtensions`) + a fourth (ShareAttachmentRouter UTTypes) →
    `enum ReadableDocumentFormat: String, CaseIterable { case pdf, epub, docx, rtf, html,
    htm, xhtml, md, markdown, txt, text; init?(extension:) }`; `parse` takes the enum,
    switch becomes exhaustive; `readableExtensions` becomes derived
    (`Set(allCases.map(\.rawValue))`) so the lists cannot drift.
    `sanitizedDocumentType` (ArticleIngestHandler.swift:91) is the parse boundary.
    EbookDocumentImportTests' list-pin becomes structural.

D24. `WeeklySaveStore.Payload.displays: [String: WeeklySaveDisplay]` → keyed by
    `WeeklySaveKind` (String-raw ⇒ identical JSON on disk; unknown future keys fall to
    the existing `try?` fallback).

D25. `Friend.normalizedValid(_ raw: [String]) -> [String]` helper collapsing the two
    identical `.map(normalize).filter(isValidEmail)` pairs
    (RecentFriendRecipientsStore.swift:47-49, EmailShareCenter.swift:79-80).
    (The full `FriendEmail` parse-once type is deferred — 7 files across 3 modules.)

D26. `LiveNetworkPolicy` — wrap everything except `allows`/`check` in `#if DEBUG`;
    in release the decision is constant-true and the refusal machinery dead-strips.
    (Tests run DEBUG; unaffected.)

D27. Adopt `AppConfig.resolvedFromInfoPlist`: one DEBUG `assert` in the shared
    AppDelegate launch path (covers all four apps) — the misconfiguration it detects
    (App-Group container split) is otherwise silent.

D28. `AudioPlaybackCenter`: expose `public var isAudiblyPlaying` and switch the 12
    LunaReaderUI call sites that build a full snapshot only to read that one bit.

## Phase E — visibility demotions (public → internal/private; zero call-site churn)

Verify each with grep before demoting (tests may need `@testable import`, which most files already use):
- LunaFetch: `SiteIconCache.decodedIcon`; `FaviconFetcher.maxIconBytes`/`minimumPixelSize`/`isDecodableIcon`; `DuckDuckGoSearch.anomalyStatusCode`
- LunaHTMLClassification: `Classifier.{shopSites,freeNewsSites,newsSites,contentKind,heuristicKind,productSignal}` (KEEP `knownSites` public — documented extension point); `ProductPageDetector.{priceFromEmbeddedJSON,firstJSONObjectLiteral}`; `PaywallDetector.{weakMarkers,htmlShowsTruncationGate}`; `ListingPage.declaresArticle(html:baseURL:)` String overload. Also fold the one-function `HTMLClassification.swift` into `PaywallDetector.htmlDeclaresLocked` and delete the file (update TruncationGateDetector.swift:15 doc ref).
- LunaModels: `PriceGraphBucket`, `calendarComponent`, `bucket(forSpanDays:)` → internal.
- LunaURLClassification batch: `ProductSearchURL.googleWebSearchURL`, `URLUnwrapper.redirectShortenerHosts`/`amazonShortLinkHosts`, `NewsAggregatorUnwrapper.base64URLDecode`, `ShareTextURL.shortTextLimit`, `LinkListMarkdown.HeadingKind`/`FoundLink`, `PlatformURLParts`.
- LunaReaderEngine: `ReadingHeuristics.{leadingBinders,phraseStarters,functionWords}`, `RSVPEngine.{sourceTokenIndices,firstFrameIndexByToken}`, `ChunkPlanner.{maxWordsPerChunk,maxCharactersPerChunk,minimumDisplay}`.
- LunaSend: `ArticleExportService.writePreparingImages`.
- LunaAudioPlayback: `AudioWordIndexing` → internal.
- LunaEpub: `EpubBuilder.escapeXML` → private.
- LunaMediaDownload: `MediaPhotosPreflight.couldBeDownloadable`, `SavedMediaStore.discardSaveWithDeletedPhotosBacking`, `LiveMediaDownloadManager.reapExpiredSuspensions`.
- LunaMediaResolve: delete the `SocialMediaResolver.unescape` public wrapper (call the module function); `YouTubePlayerResponseParser.androidVRClientVersion` → internal.
- LunaSocial: `NotificationManager.typeShareReceived` → private.
- LunaSocialUI: `SendToFriendSheet.{copyToPasteboard,presentCopiedConfirmation}` → private.
- LunaWeekly: `WeeklyCloudSchema` (+6 statics) → internal; `WeeklySigning.publicKeyBase64`, `WeeklySave.{expiryInterval,monthTierInterval}` → internal.
- LunaPlatforms: fix the redundant `public` on `PlatformModule.swift:57` (inside a public extension).
- LunaStorage: `LunaSetupStatusStore.{safariHasRun,shortcutHasRun,shortcutInstallWasPressed}` → non-public; DELETE `anyShortcutHasRun` (:130, test-retained) + its UtilCardStorageTests read. KEEP the celebration readers (:178-212) — parity anchor for SafariSetupCelebrationTests; KEEP `shareActionHasRun`/`recordShareActionRun`.
- LunaMediaDownload single-conformer protocol: delete `MediaDownloading` (MediaDownload.swift:158-183; move doc comments onto `MediaDownloadService`); drop `service:` param from `MediaAutoDownloader.runIfEnabledAwaiting`; clip's `let service` becomes concrete.

## Deferred (flagged, deliberately NOT in this pass)

- `ProductInfo.productID` vs `identifiers` unification — 124 call sites.
- `XPostPayload` → XThread boundary type — parse already centralized; churn > payout.
- `LiveMediaDownloadJob` phase-conditional payloads (`Phase.failed(message:kind:)` etc.) — persisted SQL-row compatibility + 1836-line manager.
- `AudioPlaybackCenter` per-session state → `RenderSession` struct — real payout, do alongside other work in that file.
- `RSVPWord` boundary bools → enum — 8+ test files.
- Full `FriendEmail` parse-once type (see D25 for the contained subset).
- `ArticleDestinationID` stringly-typed — single destination today; revisit when a second lands.
- `MediaRetentionOption.never` split — load-bearing legacy `disabledKey` migration.
- `testDefaultsOverride` static family → `init(defaults:)` instance pattern — consistency win only.
- `@_spi(Testing)` demotion of the `…ForTesting` public surface (LunaReaderUI etc.).
- `RabbitHoleLayerDescriptor` reading-anchor enum + non-empty `RabbitHoleStack.layers`.
- `MediaAsset.direct` ↔ `DirectMediaURL.Kind` mapping unification — layering question.
- `PreparedSavePress.isDoubleSave` folding — `.ignore` carries two meanings; needs product clarity.
- `Notification.Name.recentFriendRecipientsChanged` — `AppGroupJSONStore` requires the param.
