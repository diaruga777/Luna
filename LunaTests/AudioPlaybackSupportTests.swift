//
//  AudioPlaybackSupportTests.swift
//  LunaTests
//
//  Merged from AudioPlaybackHandoffTests, AudioPlaybackPersistenceTests,
//  AudioQueueRuleTests, AudioSessionCoordinatorTests, NowPlayingCoordinatorTests,
//  ReaderPlaybackArbiterTests, and AudioFormatConversionTests.
//

import AVFoundation
import MediaPlayer
@testable import Luna
@testable import LunaAudioPlayback
import LunaModels
import LunaReaderUI
import XCTest

/// Everything below `AudioPlaybackHandoffTests`'s doc comment through
/// `AudioFormatConversionTests`'s doc comment used to be seven separate
/// XCTestCase files; they're combined here since none of their fixtures
/// conflict once reconciled (see the shared `setUp`/`tearDown` below).
/// `ReaderPlaybackArbiterTests` (below, in this same file) is kept as its
/// own class: it is `@MainActor` because `ReaderPlaybackArbiter` requires
/// main-actor isolation, and forcing that isolation onto this class's
/// NotificationCenter-driven (`AudioSessionCoordinatorTests`) and
/// RunLoop-spinning (`NowPlayingCoordinatorTests`) fixtures would be an
/// unverifiable behavior change for what should be a pure fixture-count
/// merge — those fixtures' completion/notification callbacks are not
/// guaranteed to already be main-actor-isolated.
final class AudioPlaybackSupportTests: XCTestCase {

    // MARK: - NowPlayingCoordinatorTests seam fakes

    private final class FakeInfoSink: NowPlayingInfoSink {
        var nowPlayingInfo: [String: Any]?
        var playbackStates: [Bool] = []
        func setPlaybackState(isPlaying: Bool) { playbackStates.append(isPlaying) }
    }

    private final class FakeCommandBinding: RemoteCommandBinding {
        var handler: ((NowPlayingCoordinator.Command) -> Bool)?
        var bindCount = 0
        var transportEnabledStates: [Bool] = []
        func bindTargets(handler: @escaping (NowPlayingCoordinator.Command) -> Bool) {
            bindCount += 1
            self.handler = handler
        }
        func setTransportCommandsEnabled(_ enabled: Bool) {
            transportEnabledStates.append(enabled)
        }
    }

    // MARK: - Shared AudioPlaybackCenter fixture (AudioPlaybackHandoffTests + NowPlayingCoordinatorTests)

    private var store: FakePlaybackStore!
    private var renderer: FakeRenderer!
    private var engine: FakeAudioEngine!
    private var session: FakeSessionCoordinator!
    private var positionDefaults: UserDefaults!
    private var positionSuiteName: String!
    private var positionStore: AudioPlaybackPositionStore!
    private var center: AudioPlaybackCenter!

    // MARK: - NowPlayingCoordinatorTests fixture

    private var infoSink: FakeInfoSink!
    private var binding: FakeCommandBinding!
    private var coordinator: NowPlayingCoordinator!
    private var savedAutoplay: Bool!
    private var savedRate: Float!

    // MARK: - AudioPlaybackPersistenceTests fixture
    //
    // Named `persistence*` (rather than colliding with the `store`/
    // `positionStore`/`positionDefaults`/`positionSuiteName` names above,
    // which are a DIFFERENT fixture — a `FakePlaybackStore`-backed
    // `AudioPlaybackCenter`, not a bare `AudioPlaybackPositionStore`
    // round-trip harness).

    private var persistenceSuiteName: String!
    private var persistenceDefaults: UserDefaults!
    private var persistencePositionStore: AudioPlaybackPositionStore!

    // MARK: - AudioSessionCoordinatorTests fixture
    //
    // Renamed from `coordinator` (which collided with
    // NowPlayingCoordinatorTests's `coordinator: NowPlayingCoordinator!`
    // above — same name, unrelated type).

    private var audioSessionCoordinatorUnderTest: AudioSessionCoordinator!
    private var actions: [AudioSessionCoordinator.Action] = []

    // MARK: - AudioQueueRuleTests fixture

    private let now = Date(timeIntervalSince1970: 1_750_000_000)

    // MARK: - setUp / tearDown (union of all seven originals')

    override func setUp() {
        super.setUp()

        // AudioPlaybackHandoffTests + NowPlayingCoordinatorTests
        store = FakePlaybackStore()
        renderer = FakeRenderer()
        engine = FakeAudioEngine()
        session = FakeSessionCoordinator()
        positionSuiteName = "AudioPlaybackSupportTests.\(UUID().uuidString)"
        positionDefaults = UserDefaults(suiteName: positionSuiteName)
        positionStore = AudioPlaybackPositionStore(defaults: positionDefaults)
        center = AudioPlaybackCenter(
            store: store, renderer: renderer, positionStore: positionStore,
            sessionCoordinator: session, engineFactory: { [engine] _ in engine! })

        // NowPlayingCoordinatorTests
        infoSink = FakeInfoSink()
        binding = FakeCommandBinding()
        coordinator = NowPlayingCoordinator(
            infoSink: infoSink, commandBinding: binding, artworkFileURL: { _ in nil })
        savedAutoplay = AudioSettings.isAutoplayEnabled
        savedRate = AudioSettings.preferredRate
        AudioSettings.isAutoplayEnabled = true
        AudioSettings.preferredRate = 1.0

        // AudioPlaybackPersistenceTests
        persistenceSuiteName = "AudioPlaybackSupportTests.persistence.\(UUID().uuidString)"
        persistenceDefaults = UserDefaults(suiteName: persistenceSuiteName)
        persistencePositionStore = AudioPlaybackPositionStore(defaults: persistenceDefaults)

        // AudioSessionCoordinatorTests
        audioSessionCoordinatorUnderTest = AudioSessionCoordinator()
        actions = []
        audioSessionCoordinatorUnderTest.actionHandler = { [weak self] action in self?.actions.append(action) }
        audioSessionCoordinatorUnderTest.start()
    }

    override func tearDown() {
        // AudioPlaybackHandoffTests + NowPlayingCoordinatorTests
        AudioSettings.isAutoplayEnabled = savedAutoplay
        AudioSettings.preferredRate = savedRate
        positionDefaults.removePersistentDomain(forName: positionSuiteName)
        coordinator = nil
        center = nil

        // AudioPlaybackPersistenceTests
        persistenceDefaults.removePersistentDomain(forName: persistenceSuiteName)
        persistencePositionStore = nil
        persistenceDefaults = nil
        persistenceSuiteName = nil

        // AudioSessionCoordinatorTests
        audioSessionCoordinatorUnderTest = nil

        super.tearDown()
    }

    // MARK: - AudioFormatConversionTests helpers
    //
    // `AudioFormatConversion.convert` is the shared `AVAudioConverter`
    // plumbing both `SpeechRenderer` (native synthesizer format -> canonical
    // float32) and `ToneLibrary` (bundled .caf -> canonical) go through.
    // These tests feed it hand-built synthetic buffers (no real synthesis or
    // file I/O) and check the output format/sample counts are sane.

    /// Builds an int16-interleaved mono buffer of `frameCount` frames at
    /// `sampleRate`, filled with a simple ramp so non-silence is easy to
    /// assert on if ever needed.
    private func makeInt16Buffer(frameCount: AVAudioFrameCount, sampleRate: Double) -> (AVAudioPCMBuffer, AVAudioFormat) {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: true)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount
        let channel = buffer.int16ChannelData![0]
        for i in 0..<Int(frameCount) {
            channel[i] = Int16(truncatingIfNeeded: i * 37)
        }
        return (buffer, format)
    }

    // MARK: - AudioPlaybackHandoffTests helpers

    @discardableResult
    private func startPlayback() -> ReadingListItem {
        let item = AudioPlaybackFixtures.item(seed: "np-item", title: "Playing Title")
        let content = AudioPlaybackFixtures.content(title: "Playing Title", blockCount: 3)
        store.seed(item, content: content)
        center.play(item: item, content: content, fromWordIndex: 0)
        waitUntil(self.engine.scheduledSegments.count >= 1)
        return item
    }

    // MARK: - AudioPlaybackPersistenceTests helpers

    /// AudioSettings is deliberately App-Group-global (no injectable suite —
    /// it mirrors ReaderSettings/VoiceModelStore exactly), so these tests
    /// save and restore the live values around each assertion.
    private func withSavedSettings(_ body: () -> Void) {
        let autoplay = AudioSettings.isAutoplayEnabled
        let trimming = AudioSettings.isIntelligentTrimmingEnabled
        let rate = AudioSettings.preferredRate
        body()
        AudioSettings.isAutoplayEnabled = autoplay
        AudioSettings.isIntelligentTrimmingEnabled = trimming
        AudioSettings.preferredRate = rate
    }

    // MARK: - AudioQueueRuleTests helpers
    //
    // The autoplay queue rule (`AudioQueueRule.nextCandidate` in the app
    // shell): top-most unopened, readable Reader-surface article in the
    // reading list's own displayed order, excluding the currently playing
    // item.

    private func fresh(_ seed: String,
                       readState: ReadingListItem.ReadState = .unopened,
                       state: ReadingListItem.State = .ready,
                       platform: ContentPlatform? = nil,
                       ageDays: Double = 1) -> ReadingListItem {
        ReadingListItem(
            seed: seed, urlString: "https://example.com/\(seed)", title: seed,
            dateAdded: now.addingTimeInterval(-ageDays * 24 * 60 * 60),
            state: state, readState: readState, platform: platform)
    }

    private func readableContent(_ title: String = "t") -> ArticleContent {
        ArticleContent(title: title, blocks: [
            ArticleContent.Block(kind: .paragraph, text: "Some real body text.", links: []),
        ])
    }

    private func pick(
        _ items: [ReadingListItem],
        excluding excludedItemID: UUID? = nil,
        contents: [UUID: ArticleContent]? = nil
    ) -> ReadingListItem? {
        let contentByID = contents ?? Dictionary(
            uniqueKeysWithValues: items.map { ($0.id, readableContent()) })
        return AudioQueueRule.nextCandidate(
            items: items, now: now, excludedItemID: excludedItemID,
            content: { contentByID[$0.id] })?.item
    }

    // MARK: - AudioSessionCoordinatorTests helpers
    //
    // `AudioSessionCoordinator`'s interruption/route-change DECISIONS, driven
    // by posting the real notification names with synthesized `userInfo`
    // (the observers filter on `object == AVAudioSession.sharedInstance()`,
    // so these run headless without ever activating a session). Actual
    // session activation/deactivation is Apple's behavior and is not
    // asserted here.

    private func postInterruption(type: AVAudioSession.InterruptionType, options: AVAudioSession.InterruptionOptions? = nil) {
        var userInfo: [AnyHashable: Any] = [AVAudioSessionInterruptionTypeKey: type.rawValue]
        if let options {
            userInfo[AVAudioSessionInterruptionOptionKey] = options.rawValue
        }
        NotificationCenter.default.post(
            name: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(), userInfo: userInfo)
    }

    private func postRouteChange(reason: AVAudioSession.RouteChangeReason) {
        NotificationCenter.default.post(
            name: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            userInfo: [AVAudioSessionRouteChangeReasonKey: reason.rawValue])
    }

    // MARK: - AudioFormatConversionTests tests

    func testConvertingToMatchingFormatIsANoOp() throws {
        let (buffer, format) = makeInt16Buffer(frameCount: 512, sampleRate: 22050)
        let result = try AudioFormatConversion.convert([buffer], from: format, to: format)
        XCTAssertEqual(result.count, 1)
        XCTAssertTrue(result[0] === buffer)
    }

    func testConvertingInt16InterleavedToCanonicalFloat32Deinterleaved() throws {
        let (buffer, sourceFormat) = makeInt16Buffer(frameCount: 1000, sampleRate: 22050)
        let canonical = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 22050, channels: 1, interleaved: false)!

        let result = try AudioFormatConversion.convert([buffer], from: sourceFormat, to: canonical)

        XCTAssertEqual(result.count, 1)
        let out = result[0]
        XCTAssertEqual(out.format.commonFormat, .pcmFormatFloat32)
        XCTAssertFalse(out.format.isInterleaved)
        XCTAssertEqual(out.format.sampleRate, 22050)
        // Same sample rate in/out -> frame count should be very close (allow
        // a small margin for converter buffering behavior).
        XCTAssertEqual(Double(out.frameLength), 1000, accuracy: 8)
    }

    func testConvertingAcrossSampleRatesScalesFrameCountByRatio() throws {
        let (buffer, sourceFormat) = makeInt16Buffer(frameCount: 22050, sampleRate: 22050)
        let canonical = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 44100, channels: 1, interleaved: false)!

        let result = try AudioFormatConversion.convert([buffer], from: sourceFormat, to: canonical)

        XCTAssertEqual(result.count, 1)
        // 1 second of audio at 22050 Hz in -> ~1 second at 44100 Hz out -> ~44100 frames.
        XCTAssertEqual(Double(result[0].frameLength), 44100, accuracy: 200)
    }

    func testConvertingMultipleBuffersPreservesOrderAndCount() throws {
        let (bufferA, sourceFormat) = makeInt16Buffer(frameCount: 256, sampleRate: 22050)
        let (bufferB, _) = makeInt16Buffer(frameCount: 128, sampleRate: 22050)
        let canonical = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 22050, channels: 1, interleaved: false)!

        let result = try AudioFormatConversion.convert([bufferA, bufferB], from: sourceFormat, to: canonical)

        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(Double(result[0].frameLength), 256, accuracy: 8)
        XCTAssertEqual(Double(result[1].frameLength), 128, accuracy: 8)
    }

    func testEmptyBufferListConvertsToEmptyList() throws {
        let sourceFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16, sampleRate: 22050, channels: 1, interleaved: true)!
        let canonical = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 22050, channels: 1, interleaved: false)!
        let result = try AudioFormatConversion.convert([], from: sourceFormat, to: canonical)
        XCTAssertTrue(result.isEmpty)
    }

    // MARK: - AudioPlaybackHandoffTests tests
    //
    // Phase 6, product requirement C:
    // `AudioPlaybackCenter.restorableHandoffIfAvailable()` is the
    // non-mutating peek behind the launch-time paused mini-player preview
    // (extension → main-app playback handoff). It must say yes only for a
    // RECENT, still-valid persisted position, and never touch `state`/the
    // engine — every case here asserts `center.state` stays `.idle`
    // throughout.

    func testNilWhenNothingPersisted() {
        XCTAssertNil(center.restorableHandoffIfAvailable())
        XCTAssertEqual(center.state, .idle)
    }

    func testFreshPositionWithinWindowIsRestorable() {
        let item = AudioPlaybackFixtures.item(seed: "fresh")
        let content = AudioPlaybackFixtures.content(blockCount: 4, wordsPerBlock: 4)
        store.seed(item, content: content)
        let now = Date()
        positionStore.save(.init(
            itemID: item.id, wordIndex: 4, elapsed: 30, title: "Fresh Article",
            savedAt: now.addingTimeInterval(-60))) // 1 minute ago

        let handoff = center.restorableHandoffIfAvailable(now: now)

        XCTAssertEqual(handoff?.itemID, item.id)
        XCTAssertEqual(handoff?.title, "Fresh Article")
        XCTAssertEqual(center.state, .idle, "a peek must never mutate state")
    }

    func testPositionOlderThanTheRecencyWindowIsStale() {
        let item = AudioPlaybackFixtures.item(seed: "stale")
        let content = AudioPlaybackFixtures.content(blockCount: 4, wordsPerBlock: 4)
        store.seed(item, content: content)
        let now = Date()
        positionStore.save(.init(
            itemID: item.id, wordIndex: 4, elapsed: 30, title: "Stale Article",
            savedAt: now.addingTimeInterval(-(AudioPlaybackCenter.handoffRecencyWindow + 1))))

        XCTAssertNil(center.restorableHandoffIfAvailable(now: now))
    }

    func testPositionExactlyAtTheWindowBoundaryIsStillRestorable() {
        let item = AudioPlaybackFixtures.item(seed: "boundary")
        let content = AudioPlaybackFixtures.content(blockCount: 4, wordsPerBlock: 4)
        store.seed(item, content: content)
        let now = Date()
        positionStore.save(.init(
            itemID: item.id, wordIndex: 4, elapsed: 30, title: "Boundary Article",
            savedAt: now.addingTimeInterval(-AudioPlaybackCenter.handoffRecencyWindow)))

        XCTAssertNotNil(center.restorableHandoffIfAvailable(now: now))
    }

    func testNilWhenTheItemNoLongerExistsInTheStore() {
        // Never seeded into `store` — simulates the item being deleted after
        // the extension persisted the position.
        positionStore.save(.init(itemID: UUID(), wordIndex: 4, elapsed: 30, title: "Gone"))
        XCTAssertNil(center.restorableHandoffIfAvailable())
    }

    func testNilWhenTheItemExistsButItsContentIsMissing() {
        let item = AudioPlaybackFixtures.item(seed: "no-content")
        store.seed(item, content: nil) // item present, content never saved/loadable
        positionStore.save(.init(itemID: item.id, wordIndex: 4, elapsed: 30, title: "No Content"))

        XCTAssertNil(center.restorableHandoffIfAvailable())
    }

    func testNilWhileAlreadyPlayingSomething() {
        let playingItem = AudioPlaybackFixtures.item(seed: "playing")
        let playingContent = AudioPlaybackFixtures.content(blockCount: 2, wordsPerBlock: 4)
        store.seed(playingItem, content: playingContent)
        center.play(item: playingItem, content: playingContent)
        XCTAssertEqual(center.state, .playing(itemID: playingItem.id))

        let otherItem = AudioPlaybackFixtures.item(seed: "handoff-candidate")
        let otherContent = AudioPlaybackFixtures.content(blockCount: 2, wordsPerBlock: 4)
        store.seed(otherItem, content: otherContent)
        positionStore.save(.init(itemID: otherItem.id, wordIndex: 2, elapsed: 5, title: "Other"))

        XCTAssertNil(center.restorableHandoffIfAvailable(), "must never offer a handoff while something is already playing")
    }

    func testProgressFractionIsWordIndexOverTotalWordCount() {
        let item = AudioPlaybackFixtures.item(seed: "progress")
        // 4 blocks x 4 words = 16 total words.
        let content = AudioPlaybackFixtures.content(blockCount: 4, wordsPerBlock: 4)
        store.seed(item, content: content)
        positionStore.save(.init(itemID: item.id, wordIndex: 8, elapsed: 20, title: "Progress"))

        guard let handoff = center.restorableHandoffIfAvailable() else {
            return XCTFail("expected a restorable handoff")
        }
        XCTAssertEqual(handoff.progressFraction, 0.5, accuracy: 0.0001)
    }

    func testEmptyPersistedTitleFallsBackToTheItemOrContentTitle() {
        let item = AudioPlaybackFixtures.item(seed: "title-fallback", title: "Item Title")
        let content = AudioPlaybackFixtures.content(blockCount: 2, wordsPerBlock: 4)
        store.seed(item, content: content)
        positionStore.save(.init(itemID: item.id, wordIndex: 0, elapsed: 0, title: ""))

        XCTAssertEqual(center.restorableHandoffIfAvailable()?.title, "Item Title")
    }

    // MARK: - AudioPlaybackPersistenceTests tests
    //
    // `AudioPlaybackPositionStore` round-trip (scratch `UserDefaults` suite,
    // per the SafariExtensionStatusStoreTests pattern) and `AudioSettings`
    // clamping / defaults (the shared App-Group suite, with original values
    // restored).

    func testLoadReturnsNilWhenNothingSaved() {
        XCTAssertNil(persistencePositionStore.load())
    }

    func testSaveLoadRoundTrip() {
        let position = AudioPlaybackPositionStore.Position(
            itemID: UUID(), wordIndex: 123, elapsed: 45.5, title: "An Article")
        persistencePositionStore.save(position)
        XCTAssertEqual(persistencePositionStore.load(), position)
    }

    func testSaveOverwritesPreviousPosition() {
        persistencePositionStore.save(.init(itemID: UUID(), wordIndex: 1, elapsed: 1, title: "first"))
        let second = AudioPlaybackPositionStore.Position(
            itemID: UUID(), wordIndex: 2, elapsed: 2, title: "second")
        persistencePositionStore.save(second)
        XCTAssertEqual(persistencePositionStore.load(), second)
    }

    func testClearRemovesThePosition() {
        persistencePositionStore.save(.init(itemID: UUID(), wordIndex: 1, elapsed: 1, title: "x"))
        persistencePositionStore.clear()
        XCTAssertNil(persistencePositionStore.load())
    }

    func testCorruptPayloadLoadsAsNil() {
        persistenceDefaults.set(["itemID": "not-a-uuid", "wordIndex": 3], forKey: "audioPlaybackPosition.v1")
        XCTAssertNil(persistencePositionStore.load())
    }

    func testAudioSettingsDefaults() {
        withSavedSettings {
            let suite = UserDefaults(suiteName: AudioSettings.appGroupID) ?? .standard
            suite.removeObject(forKey: "audioAutoplayEnabled")
            suite.removeObject(forKey: "audioIntelligentTrimmingEnabled")
            suite.removeObject(forKey: "audioPreferredRate")
            XCTAssertTrue(AudioSettings.isAutoplayEnabled, "autoplay defaults ON")
            XCTAssertTrue(AudioSettings.isIntelligentTrimmingEnabled, "intelligent trimming defaults ON")
            XCTAssertEqual(AudioSettings.preferredRate, 1.0, "rate defaults to 1.0")
        }
    }

    func testAudioSettingsRoundTrip() {
        withSavedSettings {
            AudioSettings.isAutoplayEnabled = false
            XCTAssertFalse(AudioSettings.isAutoplayEnabled)
            AudioSettings.isIntelligentTrimmingEnabled = false
            XCTAssertFalse(AudioSettings.isIntelligentTrimmingEnabled)
            AudioSettings.preferredRate = 1.5
            XCTAssertEqual(AudioSettings.preferredRate, 1.5)
        }
    }

    func testPreferredRateClampsToLegacySteps() {
        withSavedSettings {
            AudioSettings.preferredRate = 0.1
            XCTAssertEqual(AudioSettings.preferredRate, 0.8, "clamped up to the lowest step")
            AudioSettings.preferredRate = 9.9
            XCTAssertEqual(AudioSettings.preferredRate, 1.5, "clamped down to the highest step")
            AudioSettings.preferredRate = 1.34
            XCTAssertEqual(AudioSettings.preferredRate, 1.2, "snapped to the nearest step")
        }
    }

    // MARK: - AudioQueueRuleTests tests

    func testPicksTopMostUnopenedReadableArticle() {
        let first = fresh("first")
        let second = fresh("second")
        XCTAssertEqual(pick([first, second])?.id, first.id, "list order is respected")
    }

    func testEmptyListYieldsNil() {
        XCTAssertNil(pick([]))
    }

    func testOpenedItemsAreNeverAutoQueued() {
        let opened = fresh("opened", readState: .opened)
        let unopened = fresh("unopened")
        XCTAssertEqual(pick([opened, unopened])?.id, unopened.id,
                       "opened-but-unfinished items are skipped (explicit product decision)")
    }

    func testReadItemsAreSkipped() {
        let read = fresh("read", readState: .read)
        XCTAssertNil(pick([read]))
    }

    func testExcludedItemIsSkipped() {
        let playing = fresh("playing")
        let next = fresh("next")
        XCTAssertEqual(pick([playing, next], excluding: playing.id)?.id, next.id)
    }

    func testMediaItemsAreSkipped() {
        let video = fresh("video", platform: .tiktok)
        let article = fresh("article")
        XCTAssertEqual(pick([video, article])?.id, article.id,
                       "platform/media items are not Reader-surface articles")
    }

    func testPriceTrackersAreSkipped() {
        var trackerItem = fresh("tracker")
        trackerItem.priceTracker = PriceTracker(
            productName: "Widget",
            stores: [PriceTrackerStore(urlString: "https://shop.example.com/w", lastPrice: 10, currency: "USD")])
        let article = fresh("article")
        XCTAssertEqual(pick([trackerItem, article])?.id, article.id)
    }

    func testPendingItemsAreSkipped() {
        let pending = fresh("pending", state: .pending)
        XCTAssertNil(pick([pending]))
    }

    func testPaywalledCaptchaStubsAreSkipped() {
        let locked = fresh("locked", state: .needsCaptcha)
        XCTAssertNil(pick([locked]))
    }

    func testItemsWithoutStoredContentAreSkippedInFavorOfTheNextReadableOne() {
        let missing = fresh("missing")
        let readable = fresh("readable")
        let picked = pick(
            [missing, readable],
            contents: [readable.id: readableContent()])
        XCTAssertEqual(picked?.id, readable.id)
    }

    func testContentWithOnlyEmptyTextBlocksIsNotReadable() {
        let imageOnly = fresh("imageOnly")
        let picked = pick(
            [imageOnly],
            contents: [imageOnly.id: ArticleContent(title: "t", blocks: [
                ArticleContent.Block(kind: .image, text: "", links: []),
            ])])
        XCTAssertNil(picked)
    }

    func testFreshReadingItemsComeBeforeAgedOutArchiveItems() {
        // An unopened item older than the archive window displays in the
        // Archive section, BELOW the Reading section — so a fresh unopened
        // item later in raw store order still wins.
        let agedOut = fresh("agedOut", ageDays: 30)
        let freshItem = fresh("fresh", ageDays: 1)
        XCTAssertEqual(pick([agedOut, freshItem])?.id, freshItem.id)
    }

    func testAgedOutUnopenedItemIsStillQueuedWhenNothingFresherExists() {
        let agedOut = fresh("agedOut", ageDays: 30)
        XCTAssertEqual(pick([agedOut])?.id, agedOut.id,
                       "the Archive section is part of the displayed order and still qualifies")
    }

    func testCandidateCarriesTheLoadedContent() {
        let item = fresh("carrier")
        let content = readableContent("Carried Along")
        let candidate = AudioQueueRule.nextCandidate(
            items: [item], now: now, excludedItemID: nil, content: { _ in content })
        XCTAssertEqual(candidate?.content.title, "Carried Along",
                       "the candidate bundles the content so the center never re-hits the store")
    }

    // MARK: - AudioSessionCoordinatorTests tests

    func testInterruptionBeganPauses() {
        postInterruption(type: .began)
        XCTAssertEqual(actions, [.pause])
    }

    func testInterruptionEndedWithShouldResumeResumes() {
        postInterruption(type: .ended, options: .shouldResume)
        XCTAssertEqual(actions, [.resume])
    }

    func testInterruptionEndedWithoutShouldResumeDoesNotResume() {
        postInterruption(type: .ended, options: [])
        XCTAssertEqual(actions, [], "no action should be emitted")
    }

    func testInterruptionEndedWithMissingOptionsDoesNotResume() {
        postInterruption(type: .ended)
        XCTAssertEqual(actions, [], "no action should be emitted")
    }

    func testOldDeviceUnavailablePauses() {
        postRouteChange(reason: .oldDeviceUnavailable)
        XCTAssertEqual(actions, [.pause], "headphones unplugged -> pause")
    }

    func testNewDeviceAvailableNeverAutoResumes() {
        postRouteChange(reason: .newDeviceAvailable)
        XCTAssertEqual(actions, [], "a new route (e.g. AirPods connecting) must not auto-resume")
    }

    func testUnrelatedRouteChangeReasonsAreIgnored() {
        postRouteChange(reason: .categoryChange)
        postRouteChange(reason: .override)
        XCTAssertEqual(actions, [])
    }

    func testMalformedInterruptionUserInfoIsIgnored() {
        NotificationCenter.default.post(
            name: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(), userInfo: [:])
        XCTAssertEqual(actions, [])
    }

    func testStartIsIdempotent() {
        audioSessionCoordinatorUnderTest.start()
        audioSessionCoordinatorUnderTest.start()
        postInterruption(type: .began)
        XCTAssertEqual(actions, [.pause], "duplicate start() must not double-deliver")
    }

    // MARK: - NowPlayingCoordinatorTests tests
    //
    // `NowPlayingCoordinator` logic over its seams (`NowPlayingInfoSink`,
    // `RemoteCommandBinding`) with an `AudioPlaybackCenter` built on the
    // shared fakes — the system `MPNowPlayingInfoCenter`/
    // `MPRemoteCommandCenter` singletons are never touched, so these run
    // headless.

    func testRegisterAtLaunchBindsTargetsOnceAndDisablesTransportWhileIdle() {
        coordinator.registerAtLaunch(center: center)
        XCTAssertEqual(binding.bindCount, 1)
        XCTAssertEqual(binding.transportEnabledStates, [false], "idle: transport commands disabled")
        XCTAssertNil(infoSink.nowPlayingInfo, "idle: no Now Playing info")
        XCTAssertEqual(infoSink.playbackStates.last, false)
    }

    func testTransportCommandsEnableOnPlayAndDisableBackAtIdle() {
        coordinator.registerAtLaunch(center: center)
        AudioSettings.isAutoplayEnabled = false
        let item = startPlayback()
        XCTAssertEqual(binding.transportEnabledStates.last, true)
        _ = item

        // Drive the article to completion -> final chime -> idle.
        for index in 0..<3 {
            waitUntil(self.engine.scheduledSegments.count > index)
            engine.completeSegment(at: index)
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        engine.completeTone(at: 0)
        XCTAssertEqual(center.state, .idle)
        XCTAssertEqual(binding.transportEnabledStates.last, false)
    }

    func testLeavingIdleReassertsCommandOwnership() {
        coordinator.registerAtLaunch(center: center)
        XCTAssertEqual(binding.bindCount, 1)
        startPlayback()
        XCTAssertGreaterThan(binding.bindCount, 1,
                             "targets are re-bound when playback starts, in case legacy SpeechController wiped them")
    }

    func testPlayingPushesTitleElapsedAndRateAtomically() {
        coordinator.registerAtLaunch(center: center)
        startPlayback()
        let info = infoSink.nowPlayingInfo
        XCTAssertEqual(info?[MPMediaItemPropertyTitle] as? String, "Playing Title")
        XCTAssertEqual(info?[MPNowPlayingInfoPropertyPlaybackRate] as? Double, 1.0)
        XCTAssertNotNil(info?[MPNowPlayingInfoPropertyElapsedPlaybackTime])
        XCTAssertNotNil(info?[MPMediaItemPropertyPlaybackDuration])
        XCTAssertEqual(info?[MPMediaItemPropertyArtist] as? String, "example.com",
                       "no author in fixture content -> artist falls back to the source host")
        XCTAssertEqual(infoSink.playbackStates.last, true)
    }

    func testPausePushesZeroRateAndPausedState() {
        coordinator.registerAtLaunch(center: center)
        startPlayback()
        center.pause()
        let info = infoSink.nowPlayingInfo
        XCTAssertEqual(info?[MPNowPlayingInfoPropertyPlaybackRate] as? Double, 0.0)
        XCTAssertEqual(infoSink.playbackStates.last, false)
    }

    func testPauseAndPlayCommandsControlTheCenter() {
        coordinator.registerAtLaunch(center: center)
        let item = startPlayback()

        XCTAssertEqual(binding.handler?(.pause), true)
        XCTAssertEqual(center.state, .paused(itemID: item.id))

        XCTAssertEqual(binding.handler?(.play), true)
        XCTAssertEqual(center.state, .playing(itemID: item.id))
    }

    func testTogglePlayPauseCommand() {
        coordinator.registerAtLaunch(center: center)
        let item = startPlayback()
        XCTAssertEqual(binding.handler?(.togglePlayPause), true)
        XCTAssertEqual(center.state, .paused(itemID: item.id))
    }

    func testSkipCommandsMapToSecondsSkips() {
        coordinator.registerAtLaunch(center: center)
        startPlayback()
        waitUntil(self.engine.scheduledSegments.count == 2)
        // 0.25 s/word fixture: +30s = +120 words, clamped to the last word,
        // which snaps to the last block's start (block 2 of 3, word 8).
        XCTAssertEqual(binding.handler?(.skipForward(seconds: 30)), true)
        XCTAssertEqual(positionStore.load()?.wordIndex, 8)

        XCTAssertEqual(binding.handler?(.skipBackward(seconds: 15)), true)
        XCTAssertEqual(positionStore.load()?.wordIndex, 0)
    }

    func testSkipCommandsUseLiveEngineClockWhenWordMarkersAreStale() {
        coordinator.registerAtLaunch(center: center)
        startPlayback()
        waitUntil(self.engine.scheduledSegments.count == 2)
        engine.currentTime = 1.0 // word 4, even with no word-marker tick

        // +1.25s at 0.25 s/word = +5 words from live word 4 -> word 9,
        // which snaps to block 2's start (word 8). The stale base was word 0.
        XCTAssertEqual(binding.handler?(.skipForward(seconds: 1.25)), true)

        XCTAssertEqual(positionStore.load()?.wordIndex, 8)
    }

    func testSkipCommandsFailWhenIdle() {
        coordinator.registerAtLaunch(center: center)
        XCTAssertEqual(binding.handler?(.skipForward(seconds: 30)), false)
        XCTAssertEqual(binding.handler?(.skipBackward(seconds: 15)), false)
        XCTAssertEqual(binding.handler?(.changePlaybackPosition(seconds: 10)), false)
    }

    func testChangePlaybackPositionSeeksProportionally() {
        coordinator.registerAtLaunch(center: center)
        startPlayback()
        waitUntil(self.engine.scheduledSegments.count == 2)
        // Fixture estimate: 12 words x 0.25s = 3s total. Seeking to the very
        // end lands on the last word -> snaps to block 2's start (word 8).
        XCTAssertEqual(binding.handler?(.changePlaybackPosition(seconds: 3)), true)
        XCTAssertEqual(positionStore.load()?.wordIndex, 8)
    }

    func testPlayCommandWhileIdleRestoresPersistedSession() {
        let item = AudioPlaybackFixtures.item(seed: "np-cold", title: "Cold Title")
        let content = AudioPlaybackFixtures.content(title: "Cold Title", blockCount: 3)
        store.seed(item, content: content)
        positionStore.save(.init(itemID: item.id, wordIndex: 5, elapsed: 2, title: "Cold Title"))

        coordinator.registerAtLaunch(center: center)
        XCTAssertEqual(binding.handler?(.play), true)
        XCTAssertEqual(center.state, .playing(itemID: item.id))
        waitUntil(!self.renderer.renderedBlocks.isEmpty)
        XCTAssertEqual(renderer.renderedBlocks.first?.blockIndex, 1,
                       "restored from the persisted word index (word 5 -> block 1)")
    }

    func testPlayCommandWhileIdleWithoutPersistedStateFails() {
        coordinator.registerAtLaunch(center: center)
        XCTAssertEqual(binding.handler?(.play), false)
        XCTAssertEqual(center.state, .idle)
    }

    func testHandleWithoutRegisteredCenterFails() {
        XCTAssertEqual(coordinator.handle(.play), false)
    }
}

// MARK: - ReaderPlaybackArbiterTests
//
// Kept as its own class — see the rationale in `AudioPlaybackSupportTests`'s
// header comment above.
//
// Two readers on one screen, one moving word.

@MainActor
final class ReaderPlaybackArbiterTests: XCTestCase {

    override func tearDown() {
        ReaderPlaybackArbiter.isPaired = false
        super.tearDown()
    }

    func testPlayingOneColumnPausesTheOther() {
        let left = PlayerSpy()
        let right = PlayerSpy()
        ReaderPlaybackArbiter.isPaired = true

        ReaderPlaybackArbiter.claim(left)
        XCTAssertEqual(right.pauseCount, 0)

        ReaderPlaybackArbiter.claim(right)
        XCTAssertEqual(left.pauseCount, 1)
        XCTAssertTrue(ReaderPlaybackArbiter.holds(right))

        ReaderPlaybackArbiter.claim(left)
        XCTAssertEqual(right.pauseCount, 1)
        XCTAssertEqual(left.pauseCount, 1, "the one being started is never paused")
    }

    func testReclaimingFromTheSameReaderPausesNothing() {
        let player = PlayerSpy()
        ReaderPlaybackArbiter.isPaired = true

        ReaderPlaybackArbiter.claim(player)
        ReaderPlaybackArbiter.claim(player)
        XCTAssertEqual(player.pauseCount, 0)
    }

    /// Luna keeps read-aloud going when you navigate away — that is what the
    /// mini-player is for. Unpaired, starting a reader must not silence whatever
    /// is already playing somewhere else.
    func testUnpairedPlaybackNeverInterruptsAnything() {
        let background = PlayerSpy()
        let opened = PlayerSpy()

        ReaderPlaybackArbiter.claim(background)
        ReaderPlaybackArbiter.claim(opened)
        XCTAssertEqual(background.pauseCount, 0)
    }

    /// Pairing enforces from the next claim on; it does not reach back and stop
    /// whatever was already playing when the second column opened.
    func testPairingEnforcesFromTheNextClaimOnward() {
        let left = PlayerSpy()
        let right = PlayerSpy()

        ReaderPlaybackArbiter.claim(left)
        ReaderPlaybackArbiter.isPaired = true
        XCTAssertEqual(left.pauseCount, 0)

        ReaderPlaybackArbiter.claim(right)
        XCTAssertEqual(left.pauseCount, 1)
    }

    /// A reader that stopped on its own must not still be able to pause its
    /// successor once a new one has claimed playback.
    func testResignOnlyClearsTheClaimItStillHolds() {
        let left = PlayerSpy()
        let right = PlayerSpy()
        ReaderPlaybackArbiter.isPaired = true

        ReaderPlaybackArbiter.claim(left)
        ReaderPlaybackArbiter.claim(right)
        ReaderPlaybackArbiter.resign(left)
        XCTAssertTrue(ReaderPlaybackArbiter.holds(right))

        ReaderPlaybackArbiter.resign(right)
        XCTAssertFalse(ReaderPlaybackArbiter.holds(right))
    }

    /// The claim is weak: a torn-down column can't keep its successor from
    /// playing, and it can't be asked to pause after it is gone.
    func testTheClaimDoesNotRetainTheReader() {
        ReaderPlaybackArbiter.isPaired = true
        autoreleasepool {
            let transient = PlayerSpy()
            ReaderPlaybackArbiter.claim(transient)
            XCTAssertTrue(ReaderPlaybackArbiter.holds(transient))
        }
        let next = PlayerSpy()
        ReaderPlaybackArbiter.claim(next)
        XCTAssertTrue(ReaderPlaybackArbiter.holds(next))
    }
}

@MainActor
private final class PlayerSpy: ReaderPlaybackPausable {
    private(set) var pauseCount = 0
    func pauseForExclusivePlayback() { pauseCount += 1 }
}
