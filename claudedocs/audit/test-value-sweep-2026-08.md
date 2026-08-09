# Test-value sweep — August 2026 (plan)

Third trim pass over `LunaTests` (after the two Aug-2026 passes that took 2453→2253).
Criterion: a test must assert *behavior* — a test that only re-states production source
(constant echoes, table mirrors, synthesized-Codable roundtrips, stub tautologies,
duplicates of a stronger sibling) is deleted. Cross-artifact consistency pins
(`*Parity*`, `KindCompositionRootTests`, `LocalizableStringsTests`, geometry suites,
`StageRegistryTests`, `WaveKernelSourceTests`, source-text pins against the unlinked
`LunaSafari/` sources) are exempt by design and were not touched.

Every removal below was verified by an auditor with file:line evidence and the
surviving coverage named. Execute top-to-bottom; one commit per section is fine.

## 1. Whole-method deletions

ArticleExtractorTests.swift
- `testExtractsRealWorldFixtures` (:228-248) — vacuous: reads `/tmp/fixture-*.html`, `continue`s when absent; loop body never executes on any machine.

AudioPlaybackSupportTests.swift
- `testRateStepsMatchTheLegacySpeechControllerSet` (:517-519) — echo of `AudioSettings.rateSteps`; behavior covered by `testPreferredRateClampsToLegacySteps` + `AudioPlaybackCenterTests.testCycleRateWalksTheLegacyStepsInOrder`.

AudioScriptSupportTests.swift
- `testScriptRoundTripsThroughCodable` — synthesized-Codable roundtrip; real coverage `testSaveThenLoadRoundTrips`.
- `testScriptFileNameDerivesFromContentFileName` — format mirror; higher-fidelity `testSavedFileLivesAlongsideTheContentFileInTheArticlesDirectory`.

AutoDownloadSettingsTests.swift
- `testStorageOptionsListOffersPhotosFirstThenEveryDeletionAge` — restates `MediaStorageOption.allCases` / `deletionOptions` construction verbatim.

ArticleAudioEngineTests.swift (env-gated suite; internal duplicates)
- `testSchedulingBundledToneDoesNotThrow` — subsumed by `testSchedulingBundledToneCompletes`.
- `testSettingRatePersists` — subsumed by `testFollowsUserRateDoesNotChangeRate` + `testPinnedToNaturalRestoresPriorRateAfterCompletion`.

CardCarouselHostViewControllerTests.swift
- `testRecentProductArtworkSettlesIntoProductCardHeader` — echoes the `.product` literals of `UtilCardSaveTransitionGeometry.fallback` (the `.article` sibling keeps its real invariant and stays).

CardCarouselMetricsTests.swift
- `CarouselScrubberMathTests.testMiniCardsReserveSelectionAndShadowRunway` (:190) — echo of `CarouselScrubberView.preferredHeight = 64 + 32`; relational pin lives in `CardDeckGeometryTests`.
- `CardCarouselScrubberTapPagingTests.testDownloaderTapTwoCardsStagesTargetAndUsesEclipse` (:380) and `...Backward...` (:384) — byte-identical to the Reader variants (survivors).
- `testCenteredCardFrameIsCentered` (:100) — subsumed by `testEveryContainerYieldsAnExact9By16CardCenteredInTheRoom`.

CardKindStyleTests.swift
- `testEveryKindGetsTheSameCardFrame` (:56) — never touches a kind; duplicate of the metrics loop test above.

CardPlaybackSpeedTests.swift
- `testVideoPlayerDoesNotWaitToMinimizeStalling` (:245) — config-flag assertion through a test-only getter; frees the `VideoCardContentViewController.playerForTesting` seam (delete it too, §4).

DuckDuckGoSearchTests.swift
- `testAnomalyStatusCodeIsTheMeasuredTwoOhTwo` (:71) — echo of `anomalyStatusCode = 202`; behavior covered by `testAnomalyPageIsRecognizedRegardlessOfStatusCode`.

EmailAccountTests.swift
- `testKeychainCredentialStorageIsTheDefault` (:243) — vacuous (passes for any default).
- `testSecondStoreOverDifferentSuiteIsUnaffected` (:221) — asserts UserDefaults suite isolation, not our code.

EpubBuilderTests.swift
- `testMissingImageFileIsSkippedEntirely` (:85) — subsumed by `EpubBuilderImageTests.testMissingFileIsSkippedEverywhere`.
- `testDownloadedImageIsEmbeddedAndReferenced` (:66) — subsumed by `EpubBuilderImageTests.testEmbedsDownloadedImage`; FIRST fold its unique `media-type="image/jpeg"` assertion into that survivor.

FailedSaveTests.swift
- `SaveFailureReasonTests.testReasonSurvivesACodableRoundTrip` (:74) — synthesized-Codable roundtrip.

HighlightShareTextTests.swift
- `testCopyFallsThroughWhenTheReaderDeclines` — zero assertions; branch observed by `testCopyWithoutASelectionFallsThroughToTheSystem`.

HorizonSpinnerViewTests.swift
- `testColorCanBeChanged`, `testStaticRingIsLayerBacked` — property echo / duplicate of `testBuildsTrackAndOrbitLayers` + `testStaysVisibleWhenHidesWhenStoppedIsFalse`.

IntentProgressReporterTests.swift
- `testStandardBudgetLeavesRoomForTheRestOfTheIntent` (:154-159) — `== 12` mirror.
- `testProvideContextUsesTwentySecondsOfTheNormalBudget` (:161-164) — `== 20` mirror.
- `testSystemProgressIsOnlyClaimedWhereTheRuntimeExistsToDriveIt` (:185-199) — re-types the body of `CaptureIntentExtendedRuntime.isAvailable`.

LiveMediaDownloadActivityStateTests.swift
- `testEndActivityDismissalDelayDefaultIsUnchanged` (:59-64) — source-text grep of a prod default; delete its now-unused `source(_:)` helper (:66-71) with it.

LiveMediaDownloadJobTests.swift
- `testDownloaderOwnershipRoundTrips` — synthesized-Codable roundtrip; the real risk is covered by `testLegacyJobWithoutOwnershipStillDecodes`.

LunaAppTests.swift
- `testStorageIdentifiers` — switch-literal mirror; superseded by `testInstalledMarkerKeys` (which has an independent hand-written duplicate to catch drift). KEEP `testDisplayNames` and `testDeepLinkSchemes` (cross-artifact).

LunaSurfacePaletteTests.swift
- `testSuppliedBaseColorsArePreservedExactly` (:14-18) — brand-RGB mirror; delete its `assertRGB` helper (:20-35) too. `testSurfaceResolutionIncludesHostAppExtensions` stays.

MoonHorizonProgressTests.swift
- `testActivityPulseDefaultsOnAndCanBeDisabled` (:118-123) — property echo; `didSet` side effects unobserved.

NotificationAuthorizationCallSiteTests.swift
- `testDefinitionSkipsExtensionProcesses` — source-text echo of two lines of `NotificationManager`; keep the call-site scan and its anti-false-green guard.

OnboardingSaveDemoTests.swift
- `testReachabilityAnswersOnlineBeforeItKnowsAnything` — cannot reach the branch it names (singleton's monitor resolves before the test runs).

OriginalPageViewControllerTests.swift
- `testWebArchiveReplayDisablesContentJavaScript` — duplicate of the real-web-view assertion in `testMissingArchiveLoadsLocalSnapshotInsteadOfPublisherURL`; frees `allowsContentJavaScriptForTesting` (§4).

PlatformFieldSaveTests.swift
- `testResultRetainsResolvedURLWhenSaveOutcomeHasNoURL` — memberwise-init trivia.

PriceHistoryIndexWriterTests.swift
- `testWriteThenLoadRoundTrips` — synthesized-Codable roundtrip.
- `testIngestRegeneratesTheIndex` — greps a string that lives inside a *default value*, not the call site; deleting the real call leaves it green. (Keep the two source-text tests whose string IS the call site.)

ProductIdentifiersTests.swift
- `testCodableRoundTrip` — synthesized-Codable; additive-key risk covered by `PriceTrackerTests.testPayloadWithoutKeyedIdentifiersDecodesAsEmpty`.

ProductMetadataExtractorTests.swift
- `testAmazonStorefrontRegistryIncludesInternationalMarkets` — 12-row mirror of `AmazonStorefronts.storefronts`.

ProductPageDetectorTests.swift
- `testAmazonTLDCurrencyMap` — the second mirror of the same table; mechanism covered by `testAmazonDPStaticPriceIsAUDViaTLD`.

PriceRefresherTests.swift
- `testRefreshTrackerByIDDetectsNewlyAlerting` — identical fixture to two survivors; FIRST fold its two `newlyAlerting` assertions into `testRefreshTrackerByIDRefreshesExactlyOneTracker`.

PriceTrackingScreenTests.swift
- `testExistingModeBackPops` — FIRST move its unique "back must not delete the tracker" assertion into `testExtensionHostExitsByFloatingGlassButtonInAppByBack`, then delete.

ProvideContextDecisionTests.swift
- `testPlatformAppNotInstalledIsUnsupported`, `testPlatformAppInstalledWithVisionNeedsScreenshot` — halves of the loop test `testEveryRecognizedPlatformTakesTheSameRoute`. (`testPlatformAppInstalledWithoutVisionIsUnsupported` stays — not in the loop.)

ReaderOnboardingTests.swift
- `testIntroActionsAreMountedAndHittable` (:374-412) — strict subset of `testIntroStagesTheSameRevealAcrossEveryFragment`.
- `testOnboardingLayoutStartsAtOneThirdOfItsContainer` (:321-324) — hand-evaluation of `AppOnboardingLayout.contentTop`; behavioral pin exists at :851-855.

ReadingListSectioningTests.swift
- `testArticleRendersAsReader`, `testPlatformItemDoesNotRenderAsReader` — duplicates of `testReaderShowsOnlyItemsThatReadAsText`.
- `testCapabilityFlagsMatchTheKindSplit` (:256-264) — restates `LunaApp.handles*` verbatim.

SurfaceSupportTests.swift
- `testFullMatrix` — re-implements the prod rule verbatim; declarative siblings cover every cell.

ToneAssetTests.swift
- `testFinalChimeIsLongerThanTransitionChime` — implied by the two duration pins above it.

WeeklySaveTests.swift
- `testPerAppKindOwnership` — mirror of `WeeklySave.swift:20-32`; behavior covered by `testEachAppAsksOnlyForItsOwnKinds` + `testASeededStoreProducesOneRowPerLiveKind`.
- `testPerAppLabelsRenameTheNounButNotTheTier` — strings-file echo; mechanism guarded by `LocalizableStringsTests`.

URLRescueTests.swift
- `testActionExtensionFailedPresentsRescueCardAndMarksFailed` — subsumed by `ShareSurfaceDriverTests.testFailedPresentsRescueCardInActionAndQuietCompleteInShare`.
- `testShareExtensionFailedCompletesSilentlyNoCard` — FIRST fold its "no RescueFailureViewController in the share leg" assertion into that survivor, then delete.

SellerComparisonTests.swift
- `testARefreshCycleFinishesPendingComparisonsBeforeItRefreshes` (:403-417) — stub tautology that never asserts the ordering it names; frees `PriceRefreshCoordinator.pendingComparisonCompletion` (§4).

## 2. Line/partial trims (keep the method)

- DoubleSaveTests.testExportFormats:80 — drop the `displayName == "View immediately"` localized-string echo.
- FactoryResetTests.testTheSummaryNamesFailures…:89 — drop `XCTAssertEqual(clean.summary, "erased 2 item(s)")`; keep the `contains("1 failure(s)")` half.
- GazeScreenProjectionTests.testPointDensityFollowsTheIdiom:128 — drop the `163 / 0.0254` line; keep `.pad < .phone`.
- RSVPEngineTests.testWordDurationsAtStandardWPM — drop the three pauseFactor-echo rows (1.8/1.3/2.5); keep the two base-WPM rows.
- RSVPFocusReticuleMetricsTests.testTheReticuleIsCenteredOnTheFocalColumn — drop the width re-derivation line; keep `midX == focalX`.
- IntentProgressReporterTests.testSaveIntentTakesTheRuntimesBudgetNotTheDefault — drop the `CaptureIntentExtendedRuntime.saveTimeout` mirror line; keep the `SaveIntent().captureSaveTimeout` half.
- LiveMediaDownloadJobTests.testStoragePolicyIncludesReserveAndTransferOverhead — drop the first `XCTAssertEqual` (restates `requiredByteCount`'s formula); keep the `hasCapacity` boundary assertions.
- SellerFanOutTests.testShippedProfiles — trim the field-by-field profile copy (:363-373); keep the relational invariants (:375-382).
- XPostExtractorTests.swift:77 — drop the `> 280` literal assertion; keep the threshold-relative one at :85.

## 3. Small improvements found in passing

- ZipArchiveWriterTests.testArchiveRoundTripsThroughSystemUnzipStructures — rename (name promises a system unzip it doesn't do); the CRC header-offset pin is unique coverage.
- NewSaveCenteringTests.testPriceDeckMovesToATrackerSavedElsewhere — center at 2 and assert 1 (match the article/media siblings' stronger shape).
- IntentQueryTests — remove duplicated `import LunaIntents`.
- LinkImportSheetTests:140 — replace hardcoded "All links imported." with the `L10n` lookup.

## 4. Production seams freed by §1 (delete with their tests)

- `VideoCardContentViewController.playerForTesting` — LunaDesignSystem/CardCarousel/VideoCardContentViewController.swift:140
- `OriginalPageViewController.allowsContentJavaScriptForTesting` — LunaArchiveReader/OriginalPageViewController.swift:62-65 (`loadedDocumentForTesting` stays)
- `PriceRefreshCoordinator.pendingComparisonCompletion` — LunaPriceUI/PriceRefreshCoordinator.swift:69
- `ArchiveTrayController.arcLayoutForTesting` — Luna/CardCarouselHost/ArchiveTrayController.swift:354 (already orphaned; its test builds its own `ArchiveArcLayout`)

All other `…ForTesting` hooks, `testDefaultsOverride` slots, `gazeClockOverride`,
`imagePreparationTimeout`, `settleFirstTurn`/`settlePollInterval`, and the
`WeeklySaveRefresher` signing seams back tests that assert real behavior — they stay.

## 5. `LunaLibraries/Tests/` retirement

The SwiftPM test targets NEVER run (only the `LunaTests` bundle hosted on the central
app executes; nothing invokes `swift test`). 10 files, 7 `.testTarget` declarations —
one of which (`LunaURLClassificationTests`) has no directory at all, which is the
long-standing fresh-worktree `mkdir -p` footgun.

1. PORT into `LunaTests` (convert `@Test`/`#expect` → XCTest to match the harness),
   as a single new file each or folded into the closest existing suite:
   - `LunaModelsTests/ArticleBlockRenderingTests.swift`
   - `LunaPriceMetadataTests/ProductMetadataParsingTests.swift`
   - `LunaHTMLClassificationTests/HTMLClassificationTests.swift` — retarget the
     `declaresPaywall` assertions at `PaywallDetector.htmlDeclaresLocked` (the
     `HTMLClassification` wrapper is deleted by the tree-shake plan).
   - `LunaMailAccountTests/{EmailBodyTests,LunaShareMarkerTests,ProviderInferenceTests,MicrosoftOAuthTests,FilterGuideTests}.swift`
     — FilterGuideTests: align with the tree-shake plan's `FilterGuide.isAutomatic`
     simplification; drop assertions that only mirror the deleted `filterSupport` field.
   - `LunaPaywallBypassTests/BypassScenarioTests.swift` — fold into `BypassTests`;
     adjust for the tree-shake plan's `BypassGate` Signal collapse (assert `.attempt`).
2. DROP without porting: `LunaAppConfigTests/AppConfigTests.swift` — it asserts the
   no-Info.plist fallback, which is only reachable under unhosted `swift test`; inside
   the hosted LunaTests bundle the plist is always present.
3. DELETE `LunaLibraries/Tests/` and all 7 `.testTarget` entries in
   `LunaLibraries/Package.swift`.
4. Update docs/memories that prescribe the `mkdir -p LunaLibraries/Tests/LunaURLClassificationTests`
   fresh-worktree workaround — it becomes obsolete with the testTarget removal
   (claudedocs/save-of-the-week-plan.md:532, claudedocs/safari-product-snapshots-plan.md:389,
   CLAUDE.md if referenced).

## 6. Cleanup after all deletions

- `scripts/select_changed_tests.py` — prune deleted class names from the path table;
  also prune already-stale names (`SafariJSParityTests`, `SafariUnlockHeuristicTests`).
- Verify no test-support file became orphaned (auditors expect none).
- Full `scripts/run_tests.sh --fresh` must end 0 failures; the executed count will
  drop by roughly 60–70 — that is the point, not a regression.
