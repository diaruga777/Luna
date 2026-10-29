//
//  AudioPlaybackCenterTests.swift
//  LunaTests
//

import AVFoundation
import LunaModels
import XCTest
@testable import LunaAudioPlayback

/// `AudioPlaybackCenter` behavior tests over the seam fakes
/// (`AudioPlaybackTestFakes.swift`): state machine, look-ahead render window,
/// autoplay boundary decisions, rate-pinned announcements, skip/seek math,
/// resume, and position persistence. `AVAudioSession`/`MPRemoteCommandCenter`
/// specifics live behind their own seams and are tested elsewhere.
final class AudioPlaybackCenterTests: XCTestCase {

    private var store: FakePlaybackStore!
    private var renderer: FakeRenderer!
    private var engine: FakeAudioEngine!
    private var session: FakeSessionCoordinator!
    private var positionDefaults: UserDefaults!
    private var positionSuiteName: String!
    private var positionStore: AudioPlaybackPositionStore!
    private var center: AudioPlaybackCenter!

    private var savedAutoplay: Bool!
    private var savedRate: Float!

    override func setUp() {
        super.setUp()
        store = FakePlaybackStore()
        renderer = FakeRenderer()
        engine = FakeAudioEngine()
        session = FakeSessionCoordinator()
        positionSuiteName = "AudioPlaybackCenterTests.\(UUID().uuidString)"
        positionDefaults = UserDefaults(suiteName: positionSuiteName)
        positionStore = AudioPlaybackPositionStore(defaults: positionDefaults)
        center = makeCenter()

        // AudioSettings is App-Group-global; pin the flags the center reads
        // and restore them in tearDown.
        savedAutoplay = AudioSettings.isAutoplayEnabled
        savedRate = AudioSettings.preferredRate
        AudioSettings.isAutoplayEnabled = true
        AudioSettings.preferredRate = 1.0
    }

    override func tearDown() {
        AudioSettings.isAutoplayEnabled = savedAutoplay
        AudioSettings.preferredRate = savedRate
        positionDefaults.removePersistentDomain(forName: positionSuiteName)
        center = nil
        super.tearDown()
    }

    private func makeCenter() -> AudioPlaybackCenter {
        AudioPlaybackCenter(
            store: store, renderer: renderer, positionStore: positionStore,
            sessionCoordinator: session, engines: FixedAudioEngineMaker(engine!))
    }

    /// Starts playback of a fixture article and waits for the first block to
    /// be rendered + scheduled.
    @discardableResult
    private func startPlayback(
        blockCount: Int = 4, wordsPerBlock: Int = 4, fromWordIndex: Int? = nil
    ) -> (item: SavedItem, content: ArticleContent) {
        let item = AudioPlaybackFixtures.item(seed: "playing")
        let content = AudioPlaybackFixtures.content(blockCount: blockCount, wordsPerBlock: wordsPerBlock)
        store.seed(item, content: content)
        center.play(item: item, content: content, fromWordIndex: fromWordIndex)
        waitUntil(self.engine.scheduledSegments.count >= 1, message: "first segment never scheduled")
        return (item, content)
    }

    /// Drives the whole article to completion (schedules + completes every
    /// remaining segment).
    private func finishArticle(totalBlocks: Int) {
        var completed = 0
        while completed < totalBlocks {
            waitUntil(self.engine.scheduledSegments.count > completed, message: "segment \(completed) never scheduled")
            engine.completeSegment(at: completed)
            completed += 1
            // Let the completion's follow-on pump run.
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
    }

    func testArticleRendererReceivesExtractedAuthor() {
        let item = AudioPlaybackFixtures.item(seed: "author")
        var content = AudioPlaybackFixtures.content(blockCount: 1)
        content.author = "Jane Smith"
        store.seed(item, content: content)
        var receivedAuthor: String?
        center.articleRendererProvider = { id, _, author, allowed in
            XCTAssertEqual(id, item.id)
            XCTAssertTrue(allowed)
            receivedAuthor = author
            return nil
        }
        center.play(item: item, content: content)
        waitUntil(self.engine.scheduledSegments.count >= 1)
        XCTAssertEqual(receivedAuthor, "Jane Smith")
    }

    func testProgressivePlaybackSchedulesEarlyButWaitsForProviderCompletionToMarkRead() {
        AudioSettings.isAutoplayEnabled = false
        let gate = ProgressiveTestGate()
        center.articleRendererProvider = { _, _, _, _ in ProgressiveTestRenderer(gate: gate) }
        let (item, _) = startPlayback(blockCount: 1)
        waitUntil(self.engine.scheduledSegments.count == 2)
        center.reportArticlePreparationProgress(itemID: item.id, fraction: 0.4)
        XCTAssertEqual(center.articlePreparationProgress, 0.4)
        XCTAssertTrue(center.isGeneratingArticleAudio)
        engine.completeSegment(at: 0); engine.completeSegment(at: 1)
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        XCTAssertTrue(store.finishedIDs.isEmpty, "Audio EOF alone cannot mark an incomplete stream read")
        Task { await gate.finish() }
        waitUntil(self.store.finishedIDs == [item.id])
        XCTAssertEqual(engine.scheduledSegments.count, 2)
        center.reportArticlePreparationProgress(itemID: item.id, fraction: 1)
        XCTAssertFalse(center.isGeneratingArticleAudio)
    }

    func testProgressiveFailureAfterAudibleBuffersPausesWithoutMarkingRead() {
        let gate = ProgressiveTestGate()
        center.articleRendererProvider = { _, _, _, _ in ProgressiveTestRenderer(gate: gate) }
        let (item, _) = startPlayback(blockCount: 3)
        waitUntil(self.engine.scheduledSegments.count == 2)
        engine.currentTime = 1.5 // Four words at the initial 0.35 s/word estimate.
        engine.completeSegment(at: 0); engine.completeSegment(at: 1)
        Task { await gate.finish(error: GeminiSpeechError.incomplete) }
        waitUntil(self.center.state == .paused(itemID: item.id))
        XCTAssertTrue(store.finishedIDs.isEmpty)
        XCTAssertNotNil(center.articlePreparationError)
        XCTAssertTrue(renderer.renderedBlocks.isEmpty, "Cloud failure must not silently switch voice")
        center.useDeviceVoiceForCurrentArticle()
        waitUntil(!self.renderer.renderedBlocks.isEmpty)
        XCTAssertEqual(renderer.renderedBlocks.first?.blockIndex, 1, "Explicit recovery resumes near the audible position")
    }

    func testArticlePreparationFailurePausesWithoutSkippingOrMarkingFinishedAndResumeRetries() {
        var attempts = 0
        let cloud = FakeRenderer()
        center.articleRendererProvider = { _, _, _, _ in
            attempts += 1
            if attempts == 1 { throw GeminiSpeechError.quota }
            return cloud
        }
        let item = AudioPlaybackFixtures.item(seed: "quota")
        let content = AudioPlaybackFixtures.content(blockCount: 3)
        store.seed(item, content: content)
        center.play(item: item, content: content)
        waitUntil(self.center.state == .paused(itemID: item.id))
        XCTAssertTrue(engine.scheduledSegments.isEmpty)
        XCTAssertTrue(store.finishedIDs.isEmpty)
        XCTAssertFalse(center.isPreparingArticleAudio)
        center.resume()
        waitUntil(self.engine.scheduledSegments.count == 2)
        XCTAssertEqual(attempts, 2)
        XCTAssertTrue(renderer.renderedBlocks.isEmpty)
        XCTAssertEqual(cloud.renderedBlocks.count, 2)
    }

    func testProgressiveRetryHandsAudibleFrameToReplacementRenderer() {
        let gate = ProgressiveTestGate(), retryGate = ProgressiveTestGate()
        let original = ProgressiveTestRenderer(gate: gate), retry = ProgressiveTestRenderer(gate: retryGate)
        let point = ProgressiveSpeechPosition(chunk: 2, frame: 36_000)
        original.recoveryPosition = point
        var attempts = 0
        center.articleRendererProvider = { _, _, _, _ in
            attempts += 1
            return attempts == 1 ? original : retry
        }
        let (item, _) = startPlayback(blockCount: 3)
        waitUntil(self.engine.scheduledSegments.count == 2)
        engine.currentTime = 1.5
        engine.completeSegment(at: 0); engine.completeSegment(at: 1)
        Task { await gate.finish(error: GeminiSpeechError.incomplete) }
        waitUntil(original.requestedSeconds != nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        XCTAssertEqual(center.state, .paused(itemID: item.id))
        XCTAssertEqual(original.requestedSeconds, 1.5)
        center.resume()
        waitUntil(retry.resumedPosition != nil)
        XCTAssertEqual(retry.resumedPosition, point)
        XCTAssertEqual(attempts, 2)
        XCTAssertTrue(store.finishedIDs.isEmpty)
        Task { await retryGate.finish() }
    }

    func testPauseCancelsPendingCloudPreparationAndResumeCanRetry() {
        var attempts = 0
        center.articleRendererProvider = { _, _, _, _ in
            attempts += 1
            if attempts == 1 { try await Task.sleep(nanoseconds: 5_000_000_000) }
            return FakeRenderer()
        }
        let item = AudioPlaybackFixtures.item(seed: "cancel-preparation")
        let content = AudioPlaybackFixtures.content(blockCount: 3)
        store.seed(item, content: content)
        center.play(item: item, content: content)
        waitUntil(attempts == 1)
        XCTAssertTrue(center.isPreparingArticleAudio)
        center.pause()
        XCTAssertFalse(center.isPreparingArticleAudio)
        XCTAssertEqual(center.state, .paused(itemID: item.id))
        center.resume()
        waitUntil(self.engine.scheduledSegments.count == 2)
        XCTAssertEqual(attempts, 2)
        XCTAssertNil(center.articlePreparationError)
    }

    func testCloudErrorCanUseDeviceVoiceWithoutRetryingCloud() {
        var attempts = 0
        center.articleRendererProvider = { _, _, _, _ in attempts += 1; throw GeminiSpeechError.quota }
        let item = AudioPlaybackFixtures.item(seed: "fallback")
        let content = AudioPlaybackFixtures.content(blockCount: 3)
        store.seed(item, content: content)
        center.play(item: item, content: content)
        waitUntil(self.center.state == .paused(itemID: item.id))
        center.useDeviceVoiceForCurrentArticle()
        waitUntil(self.engine.scheduledSegments.count == 2)
        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(renderer.renderedBlocks.count, 2)
        XCTAssertEqual(center.state, .playing(itemID: item.id))
    }

    func testSeekReusesPreparedArticleRendererAndMarkerlessPlaybackPersistsParagraph() {
        var preparations = 0
        let cloud = FakeRenderer()
        center.articleRendererProvider = { _, _, _, _ in preparations += 1; return cloud }
        let (item, _) = startPlayback(blockCount: 4)
        waitUntil(self.engine.scheduledSegments.count == 2)
        engine.currentTime = 1.1 // Second four-word paragraph, at 0.25 seconds per word.
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))
        center.pause()
        XCTAssertEqual(positionStore.load()?.wordIndex, 4)
        center.seek(toFraction: 0.75)
        waitUntil(self.cloudHasRendered(cloud, count: 3))
        XCTAssertEqual(preparations, 1)
        XCTAssertEqual(center.state, .paused(itemID: item.id))
    }

    private func cloudHasRendered(_ cloud: FakeRenderer, count: Int) -> Bool {
        cloud.renderedBlocks.count >= count
    }

    // MARK: - State machine

    func testPlayEntersPlayingStateAndMarksOpened() {
        let (item, _) = startPlayback()
        XCTAssertEqual(center.state, .playing(itemID: item.id))
        XCTAssertTrue(store.markedReadStates.contains { $0.itemID == item.id && $0.state == .opened })
        XCTAssertEqual(session.activateCount, 1)
        XCTAssertEqual(center.currentItemInfo?.title, "Fixture Article")
    }

    func testPauseAndResumeTransitions() {
        let (item, _) = startPlayback()
        center.pause()
        XCTAssertEqual(center.state, .paused(itemID: item.id))
        XCTAssertFalse(engine.isPlaying)
        XCTAssertEqual(session.deactivationsScheduled, 1, "user pause deactivates after the grace period")

        center.resume()
        XCTAssertEqual(center.state, .playing(itemID: item.id))
        XCTAssertTrue(engine.isPlaying)
        XCTAssertEqual(session.activateCount, 2, "resume reactivates the session")
    }

    func testTogglePlayPauseFlipsBetweenPlayingAndPaused() {
        let (item, _) = startPlayback()
        center.togglePlayPause()
        XCTAssertEqual(center.state, .paused(itemID: item.id))
        center.togglePlayPause()
        XCTAssertEqual(center.state, .playing(itemID: item.id))
    }

    func testToggleWhileIdleDoesNothing() {
        center.togglePlayPause()
        XCTAssertEqual(center.state, .idle)
    }

    func testPauseMirrorsWordIndexToStoreExactlyOnce() {
        let (item, _) = startPlayback()
        XCTAssertTrue(store.spokenWordIndexWrites.isEmpty, "no store writes while just playing")
        center.pause()
        XCTAssertEqual(store.spokenWordIndexWrites.count, 1)
        XCTAssertEqual(store.spokenWordIndexWrites.first?.itemID, item.id)
    }

    func testInterruptionPausesWithoutSessionDeactivationAndShouldResumeResumes() {
        let (item, _) = startPlayback()
        session.request(.pause)
        XCTAssertEqual(center.state, .paused(itemID: item.id))
        XCTAssertEqual(session.deactivationsScheduled, 0, "interruption pause must NOT deactivate the session")

        session.request(.resume)
        XCTAssertEqual(center.state, .playing(itemID: item.id))
    }

    // MARK: - Render window

    func testLookAheadSchedulesAtMostTwoBlocksAhead() {
        startPlayback(blockCount: 5)
        waitUntil(self.engine.scheduledSegments.count == 2, message: "look-ahead never filled")
        // Give the pipeline a moment to (incorrectly) over-schedule.
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(engine.scheduledSegments.count, 2, "render window is ~2 blocks ahead")

        engine.completeSegment(at: 0)
        waitUntil(self.engine.scheduledSegments.count == 3, message: "window never advanced after completion")
    }

    func testNeedsMoreAudioSignalPumpsTheWindow() {
        startPlayback(blockCount: 5)
        waitUntil(self.engine.scheduledSegments.count == 2)
        // A completion frees the window; the low-water signal alone must also
        // be able to trigger a pump attempt without erroring.
        engine.signalNeedsMoreAudio()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(engine.scheduledSegments.count, 2, "window cap still respected on low-water signal")
    }

    func testBodySegmentsFollowUserRate() {
        startPlayback()
        XCTAssertEqual(engine.scheduledSegments.first?.rateMode, .followsUserRate)
    }

    // MARK: - Autoplay boundaries

    func testFinishWithAutoplayDisabledPlaysFinalChimeAndIdles() {
        AudioSettings.isAutoplayEnabled = false
        let (item, _) = startPlayback(blockCount: 2)
        finishArticle(totalBlocks: 2)

        XCTAssertEqual(store.finishedIDs, [item.id])
        XCTAssertEqual(engine.scheduledTones.map(\.asset), [.final])
        engine.completeTone(at: 0)
        XCTAssertEqual(center.state, .idle)
        XCTAssertNil(positionStore.load(), "reaching idle clears the persisted position")
        XCTAssertNil(center.currentItemInfo)
    }

    func testFinishWithEmptyQueuePlaysFinalChimeAndIdles() {
        let dataSource = FakeAudioPlaybackDataSource()
        center.dataSource = dataSource
        startPlayback(blockCount: 2)
        finishArticle(totalBlocks: 2)

        XCTAssertEqual(engine.scheduledTones.map(\.asset), [.final])
        engine.completeTone(at: 0)
        XCTAssertEqual(center.state, .idle)
    }

    func testAutoplayChainAnnouncesRatePinnedThenStartsNextArticle() {
        let nextItem = AudioPlaybackFixtures.item(seed: "next", title: "The Next One")
        let nextContent = AudioPlaybackFixtures.content(title: "The Next One", blockCount: 3)
        store.seed(nextItem, content: nextContent)
        let dataSource = FakeAudioPlaybackDataSource()
        dataSource.nextCandidateResult = QueueCandidate(item: nextItem, content: nextContent)
        center.dataSource = dataSource

        var generationPermissions: [Bool] = []
        center.articleRendererProvider = { _, _, _, allow in
            generationPermissions.append(allow)
            return nil
        }
        let (item, _) = startPlayback(blockCount: 2)
        finishArticle(totalBlocks: 2)

        XCTAssertEqual(store.finishedIDs, [item.id])
        XCTAssertEqual(engine.scheduledTones.map(\.asset), [.transition])
        engine.completeTone(at: 0)

        // The announcement renders async, then schedules rate-PINNED.
        waitUntil(self.engine.scheduledSegments.count == 3, message: "announcement never scheduled")
        let announcement = engine.scheduledSegments[2]
        XCTAssertEqual(announcement.rateMode, .pinnedToNatural,
                       "announcements always play at 1.0x regardless of the user rate")
        XCTAssertEqual(renderer.renderedBlocks.last?.text, "Now Reading — The Next One")
        XCTAssertEqual(center.state, .announcing(nextItemID: nextItem.id))

        engine.completeSegment(at: 2)
        XCTAssertEqual(engine.scheduledTones.map(\.asset), [.transition, .transition])
        engine.completeTone(at: 1)

        waitUntil(self.center.state == .playing(itemID: nextItem.id), message: "next article never started")
        XCTAssertTrue(store.markedReadStates.contains { $0.itemID == nextItem.id && $0.state == .opened })
        // 2 body segments + 1 announcement + the next article's 2-block
        // look-ahead = 5 scheduled segments in total.
        waitUntil(self.engine.scheduledSegments.count == 5, message: "next article's look-ahead never rendered")
        XCTAssertEqual(engine.scheduledSegments[3].segment.blockIndex, 0)
        XCTAssertEqual(engine.scheduledSegments[3].rateMode, .followsUserRate)
        XCTAssertEqual(generationPermissions, [true, false], "Only an explicit article play may generate cloud speech")
    }

    func testAutoplayToggledOffDuringAnnouncementFallsBackToFinalChime() {
        let nextItem = AudioPlaybackFixtures.item(seed: "next")
        let nextContent = AudioPlaybackFixtures.content(blockCount: 2)
        let dataSource = FakeAudioPlaybackDataSource()
        dataSource.nextCandidateResult = QueueCandidate(item: nextItem, content: nextContent)
        center.dataSource = dataSource

        startPlayback(blockCount: 1)
        finishArticle(totalBlocks: 1)
        engine.completeTone(at: 0) // transition chime
        waitUntil(self.engine.scheduledSegments.count == 2, message: "announcement never scheduled")

        // The user turns autoplay off while the announcement is playing:
        // the boundary re-check must abort the chain.
        AudioSettings.isAutoplayEnabled = false
        engine.completeSegment(at: 1) // announcement heard
        engine.completeTone(at: 1) // second transition chime heard

        XCTAssertEqual(engine.scheduledTones.map(\.asset), [.transition, .transition, .final])
        engine.completeTone(at: 2)
        XCTAssertEqual(center.state, .idle)
    }

    // MARK: - Resume & persistence

    func testPlayResumesFromPersistedPositionForSameItem() {
        let item = AudioPlaybackFixtures.item(seed: "resume")
        let content = AudioPlaybackFixtures.content(blockCount: 4, wordsPerBlock: 4)
        store.seed(item, content: content)
        // Word 6 sits in block 1 (blocks start at 0, 4, 8, 12).
        positionStore.save(.init(itemID: item.id, wordIndex: 6, elapsed: 2, title: "x"))

        center.play(item: item, content: content, fromWordIndex: nil)
        waitUntil(!self.renderer.renderedBlocks.isEmpty)
        XCTAssertEqual(renderer.renderedBlocks.first?.blockIndex, 1,
                       "resume snaps to the start of the block containing the saved word")
    }

    func testPersistedPositionForDifferentItemIsIgnored() {
        positionStore.save(.init(itemID: UUID(), wordIndex: 6, elapsed: 2, title: "other"))
        startPlayback()
        XCTAssertEqual(renderer.renderedBlocks.first?.blockIndex, 0)
    }

    func testExplicitFromWordIndexBeatsPersistedPosition() {
        let item = AudioPlaybackFixtures.item(seed: "explicit")
        let content = AudioPlaybackFixtures.content(blockCount: 4, wordsPerBlock: 4)
        store.seed(item, content: content)
        positionStore.save(.init(itemID: item.id, wordIndex: 6, elapsed: 2, title: "x"))

        center.play(item: item, content: content, fromWordIndex: 0)
        waitUntil(!self.renderer.renderedBlocks.isEmpty)
        XCTAssertEqual(renderer.renderedBlocks.first?.blockIndex, 0)
    }

    func testPausePersistsPositionToAppGroupDefaults() {
        let (item, _) = startPlayback()
        center.pause()
        let position = positionStore.load()
        XCTAssertEqual(position?.itemID, item.id)
        XCTAssertEqual(position?.title, "Fixture Article")
    }

    // MARK: - Cold-relaunch restore

    func testRestorePersistedSessionRebuildsPlaybackFromStore() {
        let item = AudioPlaybackFixtures.item(seed: "cold")
        let content = AudioPlaybackFixtures.content(blockCount: 4, wordsPerBlock: 4)
        store.seed(item, content: content)
        positionStore.save(.init(itemID: item.id, wordIndex: 9, elapsed: 3, title: "t"))

        XCTAssertTrue(center.restorePersistedSessionIfAvailable())
        XCTAssertEqual(center.state, .playing(itemID: item.id))
        waitUntil(!self.renderer.renderedBlocks.isEmpty)
        XCTAssertEqual(renderer.renderedBlocks.first?.blockIndex, 2,
                       "restored playback resumes from the persisted word's block (word 9 -> block 2)")
    }

    func testRestoreFailsWithoutPersistedState() {
        XCTAssertFalse(center.restorePersistedSessionIfAvailable())
        XCTAssertEqual(center.state, .idle)
    }

    func testRestoreFailsWhenItemIsGoneFromStore() {
        positionStore.save(.init(itemID: UUID(), wordIndex: 3, elapsed: 1, title: "gone"))
        XCTAssertFalse(center.restorePersistedSessionIfAvailable())
        XCTAssertEqual(center.state, .idle)
    }

    func testRestoreIsANoOpWhileAlreadyPlaying() {
        let (item, _) = startPlayback()
        XCTAssertFalse(center.restorePersistedSessionIfAvailable())
        XCTAssertEqual(center.state, .playing(itemID: item.id))
    }

    // MARK: - Skips & seeks

    func testSkipBySecondsMapsSecondsToWordsViaRunningAverage() {
        // 4 words per block at 0.25 s/word -> after the first two blocks are
        // rendered the running average is exactly 0.25 s/word.
        startPlayback(blockCount: 5, wordsPerBlock: 4)
        waitUntil(self.engine.scheduledSegments.count == 2)

        // +2s at 0.25 s/word = +8 words from word 0 -> word 8 = block 2 start.
        center.skip(bySeconds: 2)
        XCTAssertEqual(positionStore.load()?.wordIndex, 8)
        waitUntil(
            self.renderer.renderedBlocks.contains { $0.blockIndex == 2 },
            message: "post-skip render never happened")
    }

    func testSkipBySecondsUsesLiveEngineClockWhenWordMarkersAreStale() {
        startPlayback(blockCount: 5, wordsPerBlock: 4)
        waitUntil(self.engine.scheduledSegments.count == 2)
        engine.currentTime = 1.0 // word 4, even though no marker event updated lastKnownWordIndex

        // +1.25s at 0.25 s/word = +5 words from live word 4 -> word 9,
        // which snaps to block 2's start (word 8). The stale base was word 0.
        center.skip(bySeconds: 1.25)

        XCTAssertEqual(positionStore.load()?.wordIndex, 8)
    }

    func testSkipBackwardBySecondsClampsAtZero() {
        startPlayback(blockCount: 3)
        waitUntil(self.engine.scheduledSegments.count == 2)
        center.skip(bySeconds: -300)
        XCTAssertEqual(positionStore.load()?.wordIndex, 0)
    }

    func testSkipForwardParagraphJumpsToNextBlockStart() {
        startPlayback(blockCount: 4, wordsPerBlock: 4)
        center.skipForwardParagraph()
        XCTAssertEqual(positionStore.load()?.wordIndex, 4, "next paragraph = block 1 = word 4")
    }

    func testSkipForwardParagraphUsesLiveEngineClockWhenWordMarkersAreStale() {
        startPlayback(blockCount: 5, wordsPerBlock: 4)
        waitUntil(self.engine.scheduledSegments.count == 2)
        engine.currentTime = 2.0 // word 8 / block 2

        center.skipForwardParagraph()

        XCTAssertEqual(positionStore.load()?.wordIndex, 12, "next paragraph from live block 2 = block 3 = word 12")
    }

    func testSkipBackwardParagraphUsesLiveEngineClockWhenWordMarkersAreStale() {
        startPlayback(blockCount: 5, wordsPerBlock: 4)
        waitUntil(self.engine.scheduledSegments.count == 2)
        engine.currentTime = 2.25 // word 9, inside block 2

        center.skipBackwardParagraph()

        XCTAssertEqual(positionStore.load()?.wordIndex, 8, "back from inside live block 2 restarts block 2")
    }

    func testSkipBackwardParagraphAtBlockStartStaysAtArticleStart() {
        startPlayback(blockCount: 4)
        center.skipBackwardParagraph()
        XCTAssertEqual(positionStore.load()?.wordIndex, 0)
    }

    func testSeekToFractionSnapsToContainingBlockStart() {
        startPlayback(blockCount: 4, wordsPerBlock: 4) // 16 words total
        center.seek(toFraction: 1.0)
        // word 15 -> block 3 -> block start 12.
        XCTAssertEqual(positionStore.load()?.wordIndex, 12)
    }

    func testSeekMirrorsWordIndexToStore() {
        let (item, _) = startPlayback(blockCount: 4, wordsPerBlock: 4)
        center.seek(toFraction: 0.5)
        XCTAssertEqual(store.spokenWordIndexWrites.count, 1)
        XCTAssertEqual(store.spokenWordIndexWrites.first?.itemID, item.id)
    }

    func testSkipWhilePausedKeepsEnginePaused() {
        startPlayback(blockCount: 4)
        center.pause()
        center.skipForwardParagraph()
        XCTAssertFalse(engine.isPlaying)
        if case .paused = center.state {} else {
            XCTFail("skip while paused must stay paused, got \(center.state)")
        }
    }

    // MARK: - Rate

    func testSetRatePersistsClampedToLegacySteps() {
        startPlayback()
        center.setRate(1.34)
        XCTAssertEqual(AudioSettings.preferredRate, 1.2, "clamps to the nearest legacy step")
        XCTAssertEqual(engine.rate, 1.2)
    }

    func testCycleRateWalksTheLegacyStepsInOrder() {
        startPlayback()
        XCTAssertEqual(AudioSettings.preferredRate, 1.0)
        center.cycleRate()
        XCTAssertEqual(AudioSettings.preferredRate, 1.2)
        center.cycleRate()
        XCTAssertEqual(AudioSettings.preferredRate, 1.5)
        center.cycleRate()
        XCTAssertEqual(AudioSettings.preferredRate, 0.8)
        center.cycleRate()
        XCTAssertEqual(AudioSettings.preferredRate, 1.0)
    }

    func testPlayAppliesPersistedRateToEngine() {
        AudioSettings.preferredRate = 1.5
        startPlayback()
        XCTAssertEqual(engine.rate, 1.5)
    }

    // MARK: - Observers

    private final class RecordingObserver: AudioPlaybackObserver {
        var states: [AudioPlaybackState] = []
        var itemInfos: [AudioPlaybackItemInfo?] = []
        func audioPlaybackCenter(_ center: AudioPlaybackCenter, didChangeState state: AudioPlaybackState) {
            states.append(state)
        }
        func audioPlaybackCenter(_ center: AudioPlaybackCenter, didUpdateItem info: AudioPlaybackItemInfo?) {
            itemInfos.append(info)
        }
    }

    func testObserverReceivesStateAndItemUpdates() {
        let observer = RecordingObserver()
        center.addObserver(observer)
        let (item, _) = startPlayback()
        XCTAssertEqual(observer.states.first, .playing(itemID: item.id))
        XCTAssertEqual(observer.itemInfos.compactMap { $0 }.first?.itemID, item.id)

        center.pause()
        XCTAssertEqual(observer.states.last, .paused(itemID: item.id))
    }

    func testRemovedObserverStopsReceivingUpdates() {
        let observer = RecordingObserver()
        center.addObserver(observer)
        center.removeObserver(observer)
        startPlayback()
        XCTAssertTrue(observer.states.isEmpty)
    }
}

private actor ProgressiveTestGate {
    private var continuation: CheckedContinuation<Void, Error>?
    private var result: Result<Void, Error>?
    func wait() async throws {
        if let result { return try result.get() }
        try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func finish(error: Error? = nil) {
        let result: Result<Void, Error> = error.map { .failure($0) } ?? .success(())
        self.result = result; continuation?.resume(with: result); continuation = nil
    }
}
private final class ProgressiveTestRenderer: ProgressiveSpeechRendering {
    let canonicalFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24_000, channels: 1, interleaved: false)
    private let gate: ProgressiveTestGate
    private var count = 0
    var recoveryPosition: ProgressiveSpeechPosition?
    private(set) var requestedSeconds: TimeInterval?
    private(set) var resumedPosition: ProgressiveSpeechPosition?
    init(gate: ProgressiveTestGate) { self.gate = gate }
    func render(_ block: AudioScript.SpokenBlock) async throws -> RenderedSegment { throw GeminiSpeechError.unavailable }
    func position(afterPlaying seconds: TimeInterval) async -> ProgressiveSpeechPosition? {
        requestedSeconds = seconds
        return recoveryPosition
    }
    func resume(from position: ProgressiveSpeechPosition) async { resumedPosition = position }
    func nextSegment(startingAt block: AudioScript.SpokenBlock, sessionID: UUID) async throws -> RenderedSegment? {
        guard count < 2 else { try await gate.wait(); return nil }
        count += 1
        let buffer = AVAudioPCMBuffer(pcmFormat: canonicalFormat!, frameCapacity: 24_000)!
        buffer.frameLength = 24_000; memset(buffer.floatChannelData![0], 0, 24_000 * 4)
        return RenderedSegment(blockIndex: block.blockIndex, buffers: [buffer], wordMarkers: [], duration: 1, format: canonicalFormat!)
    }
}
