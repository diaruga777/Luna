//
//  NowPlayingCoordinatorTests.swift
//  LunaTests
//

import MediaPlayer
import LunaModels
import XCTest
@testable import LunaAudioPlayback

/// `NowPlayingCoordinator` logic over its seams (`NowPlayingInfoSink`,
/// `RemoteCommandBinding`) with an `AudioPlaybackCenter` built on the shared
/// fakes — the system `MPNowPlayingInfoCenter`/`MPRemoteCommandCenter`
/// singletons are never touched, so these run headless.
final class NowPlayingCoordinatorTests: XCTestCase {

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

    private var store: FakePlaybackStore!
    private var renderer: FakeRenderer!
    private var engine: FakeAudioEngine!
    private var session: FakeSessionCoordinator!
    private var positionDefaults: UserDefaults!
    private var positionSuiteName: String!
    private var positionStore: AudioPlaybackPositionStore!
    private var center: AudioPlaybackCenter!
    private var infoSink: FakeInfoSink!
    private var binding: FakeCommandBinding!
    private var coordinator: NowPlayingCoordinator!
    private var savedAutoplay: Bool!
    private var savedRate: Float!

    override func setUp() {
        super.setUp()
        store = FakePlaybackStore()
        renderer = FakeRenderer()
        engine = FakeAudioEngine()
        session = FakeSessionCoordinator()
        positionSuiteName = "NowPlayingCoordinatorTests.\(UUID().uuidString)"
        positionDefaults = UserDefaults(suiteName: positionSuiteName)
        positionStore = AudioPlaybackPositionStore(defaults: positionDefaults)
        center = AudioPlaybackCenter(
            store: store, renderer: renderer, positionStore: positionStore,
            sessionCoordinator: session, engineFactory: { [engine] _ in engine! })
        infoSink = FakeInfoSink()
        binding = FakeCommandBinding()
        coordinator = NowPlayingCoordinator(
            infoSink: infoSink, commandBinding: binding, artworkFileURL: { _ in nil })
        savedAutoplay = AudioSettings.isAutoplayEnabled
        savedRate = AudioSettings.preferredRate
        AudioSettings.isAutoplayEnabled = true
        AudioSettings.preferredRate = 1.0
    }

    override func tearDown() {
        AudioSettings.isAutoplayEnabled = savedAutoplay
        AudioSettings.preferredRate = savedRate
        positionDefaults.removePersistentDomain(forName: positionSuiteName)
        coordinator = nil
        center = nil
        super.tearDown()
    }

    private func waitUntil(
        timeout: TimeInterval = 2, _ message: String = "condition not met in time",
        file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(condition(), message, file: file, line: line)
    }

    @discardableResult
    private func startPlayback() -> ReadingListItem {
        let item = AudioPlaybackFixtures.item(seed: "np-item", title: "Playing Title")
        let content = AudioPlaybackFixtures.content(title: "Playing Title", blockCount: 3)
        store.seed(item, content: content)
        center.play(item: item, content: content, fromWordIndex: 0)
        waitUntil { self.engine.scheduledSegments.count >= 1 }
        return item
    }

    // MARK: - Registration & enablement

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
            waitUntil { self.engine.scheduledSegments.count > index }
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

    // MARK: - Info publishing

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

    // MARK: - Command handling

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
        waitUntil { self.engine.scheduledSegments.count == 2 }
        // 0.25 s/word fixture: +30s = +120 words, clamped to the last word,
        // which snaps to the last block's start (block 2 of 3, word 8).
        XCTAssertEqual(binding.handler?(.skipForward(seconds: 30)), true)
        XCTAssertEqual(positionStore.load()?.wordIndex, 8)

        XCTAssertEqual(binding.handler?(.skipBackward(seconds: 15)), true)
        XCTAssertEqual(positionStore.load()?.wordIndex, 0)
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
        waitUntil { self.engine.scheduledSegments.count == 2 }
        // Fixture estimate: 12 words x 0.25s = 3s total. Seeking to the very
        // end lands on the last word -> snaps to block 2's start (word 8).
        XCTAssertEqual(binding.handler?(.changePlaybackPosition(seconds: 3)), true)
        XCTAssertEqual(positionStore.load()?.wordIndex, 8)
    }

    // MARK: - Cold-relaunch restore via the play command

    func testPlayCommandWhileIdleRestoresPersistedSession() {
        let item = AudioPlaybackFixtures.item(seed: "np-cold", title: "Cold Title")
        let content = AudioPlaybackFixtures.content(title: "Cold Title", blockCount: 3)
        store.seed(item, content: content)
        positionStore.save(.init(itemID: item.id, wordIndex: 5, elapsed: 2, title: "Cold Title"))

        coordinator.registerAtLaunch(center: center)
        XCTAssertEqual(binding.handler?(.play), true)
        XCTAssertEqual(center.state, .playing(itemID: item.id))
        waitUntil { !self.renderer.renderedBlocks.isEmpty }
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
