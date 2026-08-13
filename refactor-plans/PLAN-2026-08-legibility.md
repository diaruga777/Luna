# Luna legibility refactor — master plan (2026-08-13)

Goal: apply the findings of the 2026-08-13 six-agent architecture survey. Reduce
duplication, delete dead seams, fix verified bugs, and unify divergent patterns —
with **zero unintended behavior change**. UI stays pixel-identical. Snapshot
references are never re-recorded.

Inputs: the survey reports (archived in the session scratchpad) and
`proposed-changes` (sent to the user). Every claim in this plan carries file:line
evidence from those reports. **Executors must verify each claim against the tree
before editing; if a claim does not hold, skip the item and say so in the report.**

## Hard rules for every executor

1. **Behavior-preserving by default.** A few items are explicit, authorized bug
   fixes; each is marked `[BUGFIX]` and needs a test that pins the fixed behavior.
   Anything else that would change observable behavior (pixels, matching results,
   ordering, persisted bytes): do NOT do it — flag it in your report.
2. **Parity is sacred.** The `LunaSafari` parity suites must pass un-re-recorded.
   When a hand-copy is deleted in favor of the linked original, the order is:
   swap call sites → compile → run the parity suite → THEN retire the pin, in a
   separate commit. Never delete a parity test in the same commit as the code it
   pins.
3. **No concurrency-annotation churn.** A separate agent is fixing Swift 6
   concurrency warnings on branch `fix/concurrency-warnings` (44 files — list in
   the plan appendix). Do not add/remove `Sendable`, `@MainActor`, locks, or
   `nonisolated` beyond what your item strictly requires. In those 44 files keep
   diffs minimal.
4. **Small logical commits as you go**, one per item or tight cluster. Compile
   check per commit cluster:
   `xcodebuild build-for-testing -scheme Luna -destination 'generic/platform=iOS Simulator' -derivedDataPath build/dd DIAGNOSE_MISSING_TARGET_DEPENDENCIES=NO`
   Do NOT run the full test suite (the coordinator runs it after each wave).
5. **Membership exceptions**: deleting or adding a file that carries a
   per-target membership exception means editing `project.pbxproj` in the same
   commit. After any pbxproj edit, verify with a build from an EMPTY
   `-derivedDataPath` (a warm build does not catch dangling references).
6. Swift 5 language mode; iOS 18 target; `public` + explicit `public init` only
   for API that crosses a module boundary. No new SwiftPM dependencies.
7. Comments: describe what the code does now. Never narrate the refactor
   ("moved from", "was previously"). Match surrounding voice.
8. Do not touch `/Users/hsp/Desktop/luna-warnings` (another agent's worktree),
   `build/`, `artifacts/`, `site/dist/`.
9. First action in your worktree: `git log -1 --format=%H` must equal the base
   SHA in your brief. If not, stop and report.

## Waves

Waves run sequentially; agents inside a wave run in parallel on disjoint files.
The coordinator merges each wave into `main` and runs the full suite before the
next wave starts.

### Wave 1 — small, verified, self-contained

**W1-A. Dead code, dead seams, rescue-media parity** (LunaURLRescue, LunaMediaResolve, LunaPriceUI, LunaStorage, LunaModels, LunaDesignSystem, LunaMediaDownload, Luna/Reader/Onboarding, Luna/Diagnostics)
1. Delete five dead `…ForTesting` seams (no test reads them):
   `AppOnboardingViewController.swift:208` (`completeOnboardingWithRealSaveForTesting`),
   `:243` (`safariSetupScrimForTesting`),
   `OnboardingSafariSetupPopupView.swift:306` (`isPulsingForTesting`),
   `OnboardingVideoDownloadLesson.swift:538` (`downloadAlphaForTesting`),
   `OnboardingActionButtonEffects.swift:223` (`hasActiveActionButtonSaveEffectForTesting`).
2. Delete `SellerComparisonRunner.snapshotStore` (`LunaPriceUI/SellerComparisonRunner.swift:57`),
   inline `.shared`, drop the now-constant guard at `:75`.
3. Delete the `DiagnosticLogging` protocol (`LunaStorage/DiagnosticLog.swift:16-25`);
   `DiagnosticsViewController` takes the concrete `DiagnosticLog`.
4. Delete `SaveDiagnostics.withRecorder` (`LunaModels/SaveDiagnostics.swift:173`),
   `ReaderSettings.useSerifFont` (`LunaDesignSystem/ReaderSettings.swift:121`),
   `MediaDownloadService.downloadFirstMediaToPhotos` (`LunaMediaDownload/MediaDownloadService.swift:29-70`).
5. Make `OpenGraphMediaParser` public (`LunaMediaResolve/SocialMediaResolver.swift:393-410`)
   and delete the verbatim copy at `LunaURLRescue/RescueDirectiveApplier.swift:145-158`.
6. `[BUGFIX]` Replace `RescueDirectiveApplier.directAsset` (`:160-173`) with the
   canonical `DirectMediaURL`/`MediaAsset.direct(url:)` mapping. Today the copy
   accepts `m3u8`/`webm` the download pipeline cannot handle and rejects
   `heic`/`heif`/`avif`/`m4v` and five audio types it can. Add a test pinning the
   two tables to each other.

**W1-B. Small dedups** (LunaTests, LunaPriceUI, Luna/Settings, Luna/UtilCard, Luna/Mail, LunaReaderUI, LunaFetch, LunaHTMLClassification, LunaDesignSystem, Luna/Downloader, Luna/PriceTracker, LunaReadingList)
1. One shared `waitUntil(_:timeout:)` in `LunaTests/PollingSupport.swift`; retire
   the 15 private copies (poll the condition; never a fixed-duration pump).
2. Day-formatter dedup: delete `ProductTrackerMerge.utcDayDate` (`:154-160`,
   builds a `DateFormatter` per call) in favor of the public
   `ProductSnapshotStore.date(forDay:)`; point `PriceHistoryIndexWriter`'s
   private formatter (`:78-84`) at `ProductSnapshotStore.dayString`.
3. Adopt `resolvedAppGroupDefaults` at `AppIntentSettings.swift:14-17`,
   `Luna/UtilCard/RecentURLMatcher.swift:92-95`, `LunaInstallationMarkers.swift:19-21`.
4. Extract `PhotosPermissionAlert.present(from:openSettings:)`; adopt at
   `DownloadsSettingsScreen.swift:143-156` and
   `UtilCardContentViewController.swift:983-996` (identical alerts today).
5. `[BUGFIX-adjacent]` Adopt `HostMatching.normalizedHost` at the six
   `replacingOccurrences(of: "www.")` sites (RSVPViewController:1003,
   InlineReaderPageViewController:86, SplitWebOverlayViewController:656,
   ArticleFetcher:197, PriceGraphView:319, ProductPageDetector:850). The
   hand-rolled form strips `www.` mid-string (`shopwww.com` → `shop.com`); the
   helper strips a prefix only. Add a `HostMatching` test row for the mid-string
   case. NOTE: RSVPViewController and SplitWebOverlayViewController are on the
   concurrency branch's file list — keep the diff to exactly these lines.
6. Hoist the four identical `CardCarouselStyle` values set by both
   `MediaCardDeck.makeRoot()` (`MediaCardFactory.swift:697`) and
   `ProductCardDeck.makeRoot()` (`ProductCardContent.swift:70`) into a named
   default on `CardCarouselStyle`.
7. Merge `ReadingListIngestor.handleVideo`/`handlePlatform` (`:355-367`, same
   body). Concurrency-branch file — tight diff.

**W1-C. Verified small bug fixes** (LunaIngest, LunaReadingList, LunaShareSurface, LunaStorage, LunaMailTransport, LunaDesignSystem)
1. `[BUGFIX]` `IngestPipeline.swift:193-207`: the timeout leg's
   `try? await Task.sleep` swallows cancellation, so EVERY save's diagnostics
   log ends with a false "budget of 28s elapsed" line and the task group waits
   for the sleeper. Change to `do { try await Task.sleep } catch { return nil }`.
   Test: a fast-failing save's diagnostics must not contain the budget line.
2. `[BUGFIX]` `.unsupported` reaching a process that accepts it must mark the
   row failed instead of silently leaving it pending:
   `IngestorOutcomePresenter` (`ReadingListIngestor.swift:768-772`) and
   `ShareSurfaceDriver.swift:199-203` — mirror `missingHandlerFallback:398-405`.
   Keep the debug assertions. Test each.
3. `[BUGFIX]` `SharedReadingListAppender.insertIfNew` (`:104-118`): if the
   existing file fails to decode, it currently rewrites the list as
   `[newItem]` — data loss. Port the `safeToRewrite` guard from
   `ReadingListStore.decodeList` (`:1019-1034`): on undecodable-but-nonempty
   file, abort the append. Also apply `BackupPolicy.includeInBackups` as
   `encodeItems` does. Test with a corrupted fixture.
4. `[BUGFIX]` `StreamIMAPClient.swift:102-103`: `highestUID` is advanced before
   the `guard let raw = fetch.literals.first else { continue }`, so a message
   whose literal the server omitted is skipped forever. Advance the cursor only
   after a successful parse (or track the skip). Concurrency-branch file —
   minimal diff. Test with a stubbed fetch response missing its literal.
5. Hoist the `imageReferences.setReferences` call
   (`ReadingListStore.swift:784-786`) outside `coordinatedMutate`'s coordination
   block — nested coordinated access across two `NSFileCoordinator`s on two
   files is deadlock-prone. Same ordering, same values written.
6. `[BUGFIX]` `AppearanceSettings.observedScenes` (`AppearanceSettings.swift:81`)
   keys on `ObjectIdentifier` and never removes entries, so a recycled scene
   address is treated as already-observed and stops following the device style.
   Key on `scene.session.persistentIdentifier` (and prune on disconnect), or
   register unconditionally and drop the set. Test if feasible; otherwise
   explain verification in the report.

### Wave 2 — structural (after Wave 1 merges)

**W2-A. Per-kind shell wiring** (Luna/, project.pbxproj) — the highest-value item.
1. Extract the duplicated per-kind halves of the four `KindWiring+*.swift` into
   `Luna/ArticleShellWiring.swift`, `Luna/MediaShellWiring.swift`,
   `Luna/ProductShellWiring.swift` (names flexible), each carrying the same
   membership exceptions as the kind's existing shell files. Each
   `KindWiring+<App>` collapses to: install packs + call the legs it has.
   Evidence: `KindWiring+Luna.swift:110` "identical in the Reader variant",
   duplicated runs Luna:112↔Reader:50 (75 lines), Luna:446↔Reader:260 (52),
   Luna:192↔Downloader:57 (35), Luna:389↔Downloader:190 (35), plus
   `ArticleKindHandler`/`MediaKindHandler`/`ProductKindHandler` twins.
   Constraints: the new files must NOT call `<Kind>KindComposition.install()`
   (`KindCompositionRootTests` keys its expected map on the root files and
   fails on new unlisted roots); preserve install/call order exactly.
2. `[BUGFIX]` While unifying the article leg: the Reader archives finished
   reads in `appDidEnterBackground` (`KindWiring+Reader.swift:205`); the central
   app does not (`KindWiring+Luna.swift:347-354`), violating the invariant
   `KindDeckProvider.swift:213` documents ("at launch/background"). The unified
   article leg gives both apps the Reader's behavior. Test.
3. `[BUGFIX]` Move `ArticleSpotlightIndexWiring.install()` (today unconditional,
   `AppDelegate.swift:153`) into the article leg. Downloader/Price Tracker
   currently Spotlight-index articles they cannot open. Test: wiring installed
   iff the app handles articles.
4. Collapse `makeRootViewController` ≡ `makeCompletedRootViewController` ≡
   `makeSetupReplayRootViewController` (identical in all four variants; keep the
   public entry points that callers use, delete the pure indirections).
5. Delete `KindWiring.resumeUnfinishedMediaDownloads` (4 declarations + the one
   call at `AppDelegate.swift:349`): only reachable from the mail-fetch BGTask,
   which only Luna/Reader register — and both implement it as `{}`. Behavior is
   preserved by `LiveMediaDownloadManager.resumeLiveActivities()` (`:675-683`).
6. Delete the dead `KindWiring.onboardingContentWatch` statics
   (`+Luna:34`, `+Downloader:21` — read nowhere). Report (do not fix) the gap it
   leaves documented: a media save during setup replay does not complete
   onboarding.
7. Delete the `ReadArticleIntent.playArticle` seam (`ReadArticleIntent.swift:39`):
   the file compiles only in Luna/Reader, both of which link LunaAudioPlayback
   and install the same closure — call `AudioPlaybackCenter.shared` directly.
8. Delete `UtilCardContentViewController.setupJourneyLauncher` (`:75`): both ends
   compile in all four targets; call directly. Keep `emailSetupLauncher` (that
   one gates on files two targets exclude).
9. `[BUGFIX]` Replace the `ExternalItemOpening` protocol: its only conformer is
   `ArticleCardsViewController` (`:1982`), but the call site
   (`SceneDelegate.swift:218-224`) fires in Luna AND Downloader, whose root is a
   bare `CardCarouselHostViewController` — the degrade path silently no-ops
   there. Move `openExternally` onto `CardCarouselHostViewController`
   (`CardKindPresenting.openExternally` already exists, `CardKindPresenter.swift:265`),
   delete the protocol. Test.
10. Deduplicate `LunaShortcuts+*`: `+Luna`≡`+Reader` and `+Downloader`≡`+PriceTracker`
    byte-identical — two files serve four targets via membership exceptions.
11. Align access-control drift (`legacyOnboardingDemoSave`, private in three
    variants, not in Luna). Fix the misleading comment at `KindWiring+Luna.swift:326`
    (`SavedMediaStore.startObservingCrossProcessChanges` is installed for both
    media apps by `MediaCardPresenter:158`; the call is a guarded no-op).
12. pbxproj: add membership exceptions for the new files; verify from an empty
    `-derivedDataPath` for ALL FOUR app schemes.

**W2-B. Safari hand-copy retirement** (LunaSafari/, LunaPriceCompare, LunaPriceUI, LunaURLClassification, LunaDownloaderClip, LunaTests)
Order per hard rule 2 (swap → verify → retire pin, separate commits).
1. Delete `SafariAppGroup.swift` in favor of `AppConfig.appGroupID` (linked).
   Keep reading the id from the extension's Info.plist only if `AppConfig`
   cannot serve the appex — verify `AppConfig` resolves inside the appex first;
   if it cannot, keep the file and report why.
2. Replace `SharedSafariURL`'s key blocks with the linked LunaStorage stores
   (`SafariURLStore`, `SafariRecentHistoryStore`, `SafariContentStore`,
   `LunaSetupStatusStore`). Behavior identical: same keys, same 20-entry cap,
   same 24 h window.
3. Replace `SharedSurfaceScheme` literals with `LunaDeepLink` +
   `LunaApp.storageIdentifier`.
4. Delete `SharedProductMatching.swift:238-250` (`strippedTrackingURL` — verbatim
   dup of `LunaPriceCompare.ProductSnapshot.strippedTrackingURL`, module already
   imported in that file) and `:176-236` (dup of `ProductIdentityMatching` in
   LunaModels, already called at `ComparableSellerFinder.swift:97`).
5. Move `PriceHistoryIndexEntry` (Codable model, `PriceHistoryIndexWriter.swift:16-37`)
   and the index-matching tier (`SnapshotMatcher`'s six-tier precedence) down
   from LunaPriceUI into LunaPriceCompare (already a LunaPriceUI dependency,
   already linked by the appexes). Then `SharedProductMatching.swift` reduces to
   `historyAnswer`, and its parity tests convert from source-text pins to
   behavior tests against the one implementation.
6. Retire the superseded parity pins (`SafariSetupCelebrationTests:183-217`
   key-format tests, `SharedProductMatchingParityTests` source pins) — each in
   its own commit AFTER the swap it pinned is verified green.
7. Replace `LunaDownloaderClip/ClipLaunchURL.swift:8-37` with
   `LunaAppClipInvocationURL.sourceURL` parameterized for its two deltas
   (`/download` path requirement; "luna"-host rejection) so the fork dies
   without changing either clip's acceptance.
8. Do NOT touch: `content.js`'s color table and settings-key literals (JS cannot
   link Swift), the three generated `.js` tables, any JS heuristic mirror, or
   their fixture parity suites.

**W2-C. Storage unification** (LunaStorage, LunaSocial, LunaFetch)
1. `[BUGFIX]` Introduce a generic coordinated App-Group JSON file store (extend
   the `CoordinatedJSONIndex` pattern — it has the correct `.notRun` fallback
   semantics) and move `SaveFailureStore`, `RescueLedgerStore`,
   `RescueStatsStore` onto it. Today they load once at init and rewrite whole
   files with NO file coordination and no re-read, so an extension's writes are
   clobbered when the app resumes (`SaveFailureStore.swift:70-76,148-168`;
   same shape in the other two). Keep each store's public API. Two commits:
   the generic store + SaveFailureStore first, the two rescue stores second.
   Tests: cross-instance write visibility (two store instances on one file).
2. Fold `LunaSocial/AppGroupJSONStore`'s hand-rolled coordination (`:15-100`,
   including the duplicate `AccessorResult` enum) onto the same substrate.
3. Unify container resolution: `ImageReferenceStore.swift:34-38` and
   `PreloadStore.swift:106-111` resolve via `FileManager` +
   `ReadingListStore.appGroupID` instead of `AppConfig.sharedContainerURL`,
   which splits the container under `-LunaStage`. Route through AppConfig.
   (`PriceHistoryIndexWriter`'s copy is W2-B's to fix while it edits that file.)
4. Dedup `DuckDuckGoSearch.results`/`.entries` (`:27-42` vs `:61-76`) and the
   twice-written `result__a` regex (`:94`, `:161`) — one request/guard path,
   two parsers.

**W2-D. UI dedup** (LunaDesignSystem, LunaReaderUI, LunaPriceUI, LunaMediaDownload, Luna/Downloader, Luna/PriceTracker, Luna/Settings, Luna/Diagnostics)
1. `LunaShareSheet.present(items:from:anchor:)` in LunaDesignSystem; adopt at
   the 13 hand-rolled `UIActivityViewController` sites EXCEPT
   `SceneDelegate.swift:226` (W2-A owns that file this wave; list it in your
   report as remaining). `[BUGFIX]` This removes the two force-unwrapped
   popover anchors (`ProductCardPresenter.swift:133`,
   `MediaCardPresenter.swift:284,:327`).
2. Adopt `DownsampledImageLoader` at `ProductArtwork` (currently NO cache — a
   product chip re-decodes on every deck reload),
   `CarouselScrubPreviewController:180`, `CardCarouselViewController:1552`,
   `LinkImportPreviewLoader:106`. SKIP the snapshot-pinned
   `AudioMiniPlayerView` and `ArticleTextRenderer` (flag as follow-ups).
   Snapshot suites must pass un-re-recorded.
3. Remove the three dead `ReadingListItemCell` comment references
   (`DownsampledImageLoader.swift:9`, `AudioMiniPlayerView.swift:87`,
   `LunaTests/DownsampledImageLoaderTests.swift:13`).

### Wave 3 — consolidation (after Wave 2 merges)

**W3-A. Mail consolidation** (LunaLibraries/Package.swift, LunaMail*, LunaSend, LunaEpub)
1. Fold `LunaMail` (650 LOC parser bag; its one wire consumer is
   `StreamIMAPClient`) into `LunaMailTransport`; keep every type's name; update
   the (few) direct importers. All four apps already link all three mail
   modules, so no link graph changes. Rename the misleading
   `GmailIMAPClient.swift` (a pure parser bag; the client it names was deleted)
   to `IMAPParsing.swift`.
2. Move `MIMEMessage` out of LunaEpub (`LunaEpub/MIMEMessage.swift`) next to
   `EmailMIMEBuilder` in LunaMailAccount (two RFC-5322 assemblers, one module).
3. `[BUGFIX]` Migrate `IncomingMailSettings` (`LunaMail:19-41`) and
   `KindleSendSettings` (`LunaSend:26-40`) from `UserDefaults.standard` to the
   App-Group suite with a read-through fallback (read group; if absent, read
   standard, write group). Today Luna and Reader keep two independent import
   cursors and two Kindle addresses for one shared account. Tests for the
   migration fallback.
4. Do NOT touch `EmailTransport: Sendable` or transport concurrency — the
   concurrency agent's lane.

**W3-B. Pattern unification** (LunaReaderUI, LunaMediaDownload, LunaPriceUI, Luna/MiniPlayer, LunaAudioPlayback, LunaReadingList, Luna/)
1. Convert `AudioMiniPlayerView`'s six sibling closures (`:61-66`) to an
   `AudioMiniPlayerDelegate`; sole conformer `MiniPlayerHostViewController`.
2. Convert `SplitWebOverlayViewController`'s four control-bar closures
   (`:1006-1010`) to a delegate (the file already defines
   `InlineReaderPresentationCoordinating`). Concurrency-branch file — tight diff.
3. Delete the three pass-through `Share*Presenter` adapters
   (`ArticleKindComposition.swift:69-106`, `MediaKindComposition.swift:34-79`,
   `ProductKindComposition.swift:49-64`); conform the `Extension*Presenter`
   types to the `Share*Presenting` protocols directly (~120 lines).
4. Extract `ReadingListSweepDriver` for the three byte-identical debounced
   `.readingListChanged` sweeps (`AudioScriptPipeline`, `URLRescueCoordinator`,
   the Spotlight wiring W2-A moved). Add the missing Spotlight-sweep test.
5. Simplify `URLRescueWiring.mediaResolverFactory` (factory closure read once at
   install) to a stored `SocialMediaResolving?`.

**W3-C. Tooling, guards, visibility, docs** (scripts/, LunaTests, Luna/, project.pbxproj, claudedocs/, CLAUDE.md)
1. New guard test: every `membershipExceptions` name in `project.pbxproj` must
   exist on disk under its group (closes the dangling-exception trap CLAUDE.md
   documents; reuse `StageRegistryTests`' parser).
2. New guard test: the BGTask identifiers in Swift (`AppDelegate.swift:28,:33`,
   `WeeklyProposalBackgroundCheck.swift:19`) match
   `BGTaskSchedulerPermittedIdentifiers` in the bundled Info.plists
   (cross-artifact pin, exempt-shaped).
3. New guard test: `manifest.json` constraints (description ≤ 112 chars,
   `"persistent": false`, numeric icon keys) — ITMS-90849 is currently doc-only.
4. Retire the dead `-uiTestScreen` half: `Luna/UITestScreen.swift` (216 lines,
   3 membership exceptions → pbxproj edit + empty-DD verification), the four
   `uiTestRootViewController` members, `SceneDelegate.swift:342-356`,
   `UITestSeeder.requestedScreenName`. KEEP `-uiTestState` seeding and
   `UITestFixtures` (used by `UITestSupport:25`, `StageFixtures:33-50`).
5. Visibility sweep: demote the ~65 file-local `public` types (survey list) to
   internal; demote the public static test seams (`ShareReaderViewController`,
   `GazeTracker`, `RSVPViewController` overrides) to internal by switching their
   two test files to `@testable import`.
6. One `Logger` subsystem constant for the six `os_log` sites.
7. Doc drift: CLAUDE.md (`intelligentPriceResolver` → `ProductPriceRescue.resolver`;
   `NonArticleCardOpening`), `AudioPlaybackWiring.swift:11-24`,
   `CardDeckProvider.swift:16-19`, `claudedocs/readers.md` (ReaderKit paths),
   `reading-list.md:45,47`, `social-sharing.md:81-82`, `incoming-mail.md:14-17`,
   `ui-testing.md:35`, `visual-effects.md:60`,
   `SharedReadingListAppender:16-20,73-76` stale rationale (file now imports
   LunaModels), plus stale headers left by Waves 1–2.

## Explicitly deferred (documented, not executed — report only)

- Moving JS heuristics into the Safari handler (sync→async round-trip risk;
  needs its own carefully-measured pass).
- `LiveMediaDownloadManager` read-modify-write races → actor/`JobStore.mutate`
  (real bug, but squarely in the concurrency agent's lane; hand it over).
- Unifying the four kind registries into one; persisting `ContentKind` on
  `ReadingListItem` (product/migration decision).
- Splitting mail import out of LunaReadingList (link-graph change for
  Downloader/PriceTracker); folding LunaPlatforms into LunaMediaDownload;
  folding LunaEpub into LunaSend; LunaMediaUI peel-off.
- Shared FoundationModels session floor (new dependency edges).
- View-controller splits (RSVP engines, onboarding, ArticleCards file split).
- `ReaderCardViewportPolicy` idiom→width unification (behavior change).
- Eclipse keyframe extraction (values genuinely differ per animator).
- Share/Action entry-folder unification; `add_luna_app.rb` composition
  idempotence; fifth-app hardening.
- `CardKindPresenting.loadThumbnail` main-queue contract.
- HTML-entity decode unification (behavior change on `&#39;` etc.).
- `EmailTransport` Sendable fiction (concurrency agent).

## Wave verification (coordinator)

After each wave merges: full `scripts/run_tests.sh --fresh` on an iOS 26.x sim,
no other sims booted. Baseline 2992 / 20 skips / 0 failures — diff the failure
list, not the total. Snapshots must pass without re-recording. After Wave 3:
update CLAUDE.md and `claudedocs/` for the new structure, then the final
architecture report.

## Appendix: concurrency-branch files (keep diffs minimal there)

See `main...fix/concurrency-warnings` — 44 files, notably:
ReadingListIngestor, IncomingMailImporter, LinkImportRunner, URLUnwrapper,
StreamIMAPClient, RSVPViewController, SplitWebOverlayViewController,
PreloadCoordinator, SpeechEngine, AudioPlaybackCenter, LiveMediaDownloadManager,
MediaAutoDownloader, URLRescueEngine, RescueDigestBuilder,
PrivateCloudRescueSession, ArticleSendCoordinator, ArticleExportImages,
EmailAccount(Store), MailCredentialStorage, MailProvider, IntentIngestHelper,
SocialPostFinder, ProductTrackerIngestor, ProductPageSuggestion,
SellerComparisonDocument, CardKindPresenter, MediaCardPresenter,
LinkImportPreviewLoader, LinkImportSheetViewController, WeeklyProposalsScreen,
PresentingHostViewController, WeeklyPromotionMenu, WeeklyRowEclipseTransition,
ArchiveWebReaderViewController, UnattendedArticleUnlock, InPageAnchors,
ProductMatcher, ArticleContent+Readability, FoundationModelsScreenCaptureSession,
WebJunkBlocker, MediaVideoTrimmer, LunaApp, OneShotLatch (new).
