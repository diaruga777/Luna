//
//  RSVPAudioSyncTests.swift
//  LunaTests
//

import AVFoundation
import LunaModels
@testable import LunaReaderEngine
import LunaReaderUI
import XCTest
@testable import LunaAudioPlayback

final class RSVPAudioSyncTests: XCTestCase {

    private var store: FakePlaybackStore!
    private var renderer: FakeRenderer!
    private var engine: FakeAudioEngine!
    private var session: FakeSessionCoordinator!
    private var positionSuiteName: String!
    private var positionDefaults: UserDefaults!
    private var center: AudioPlaybackCenter!
    private var savedLauncherCenter: AudioPlaybackCenter?
    private var savedRate: Float!

    override func setUp() {
        super.setUp()
        store = FakePlaybackStore()
        renderer = FakeRenderer()
        engine = FakeAudioEngine()
        session = FakeSessionCoordinator()
        positionSuiteName = "RSVPAudioResyncTests.\(UUID().uuidString)"
        positionDefaults = UserDefaults(suiteName: positionSuiteName)
        center = AudioPlaybackCenter(
            store: store, renderer: renderer,
            positionStore: AudioPlaybackPositionStore(defaults: positionDefaults),
            sessionCoordinator: session, engines: FixedAudioEngineMaker(engine!))
        // RSVP reads the app-wide center through ReaderAudioLauncher; point it at
        // the fake-backed one for the duration of the test.
        savedLauncherCenter = ReaderAudioLauncher.center
        ReaderAudioLauncher.center = center
        savedRate = AudioSettings.preferredRate
        AudioSettings.preferredRate = 1.0
    }

    override func tearDown() {
        ReaderAudioLauncher.center = savedLauncherCenter
        AudioSettings.preferredRate = savedRate
        positionDefaults.removePersistentDomain(forName: positionSuiteName)
        center = nil
        super.tearDown()
    }

    // MARK: - RSVPAudioWordSync
    //
    // The shared "audio-center word event -> RSVP frame" sequence both
    // RSVPViewController and LinkRSVPPreview apply in their AudioPlaybackObserver
    // conformances.

    private func content(_ paragraphs: [String]) -> ArticleContent {
        ArticleContent(title: "T", blocks: paragraphs.map { .init(kind: .paragraph, text: $0, links: []) })
    }

    func testFrameIndexMapsAWordEventToTheCorrespondingFrame() {
        let content = content(["One two three.", "Four five"])
        let engine = RSVPEngine(content: content)
        let blockTokenStarts = AudioWordEventTokenMapping.blockTokenStarts(blocks: content.blocks)

        // Block 1 ("Four five"), UTF-16 location 5 -> "five" -> global token 4.
        let event = AudioWordEvent(blockIndex: 1, rangeInBlockText: NSRange(location: 5, length: 4))
        let frame = RSVPAudioWordSync.frameIndex(
            for: event, blocks: content.blocks, blockTokenStarts: blockTokenStarts, engine: engine)
        XCTAssertEqual(frame, 4)
        XCTAssertEqual(engine.words[frame!].text, "five")
    }

    func testFrameIndexIsNilForAnOutOfRangeBlock() {
        let content = content(["One two"])
        let engine = RSVPEngine(content: content)
        let blockTokenStarts = AudioWordEventTokenMapping.blockTokenStarts(blocks: content.blocks)
        let event = AudioWordEvent(blockIndex: 5, rangeInBlockText: NSRange(location: 0, length: 3))
        XCTAssertNil(RSVPAudioWordSync.frameIndex(
            for: event, blocks: content.blocks, blockTokenStarts: blockTokenStarts, engine: engine))
    }

    /// A long word split into several RSVP frames maps to the FIRST frame of
    /// its token (`RSVPEngine.frameIndex(forTokenIndex:)`'s contract).
    func testFrameIndexLandsOnFirstFrameOfASplitLongWord() {
        let content = content(["pneumonoultramicroscopic ok"])
        let engine = RSVPEngine(content: content, maxCharactersPerWord: 10)
        let blockTokenStarts = AudioWordEventTokenMapping.blockTokenStarts(blocks: content.blocks)
        let event = AudioWordEvent(blockIndex: 0, rangeInBlockText: NSRange(location: 0, length: 24))
        let frame = RSVPAudioWordSync.frameIndex(
            for: event, blocks: content.blocks, blockTokenStarts: blockTokenStarts, engine: engine)
        XCTAssertEqual(frame, engine.firstFrameIndexByToken[0])
    }

    // MARK: - RSVPAudioResync
    //
    // The RabbitHole reader REUSES one RSVP instance across mode switches
    // (scroll <-> rsvp), re-preparing it with `configureForReuse` each time. When
    // read-aloud is playing through the app-wide `AudioPlaybackCenter`, that
    // playback continues in the background across the switch. Returning to RSVP
    // therefore has to re-adopt the center's live playing state — otherwise
    // `configureForReuse`'s reset leaves `isPlaying == false` while audio is
    // still voicing the article, which freezes the word display (the center's
    // word events are gated on `isPlaying`) and makes the play button's first
    // tap pause the audio instead of resuming. These tests pin that re-sync.

    private func makeRSVP(item: SavedItem, content: ArticleContent) -> RSVPViewController {
        let rsvp = RSVPViewController(item: item, content: content, audioEnabled: true)
        rsvp.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        rsvp.loadViewIfNeeded()
        rsvp.view.layoutIfNeeded()
        return rsvp
    }

    /// The core regression: the center is voicing this article when a reused
    /// RSVP shell is re-prepared for it — `configureForReuse` must land on
    /// `isPlaying == true` so the display follows and the controls stay in sync.
    func testReuseWhileCenterPlayingAdoptsPlayingState() {
        let item = AudioPlaybackFixtures.item(seed: "rsvp-resync")
        let content = AudioPlaybackFixtures.content(blockCount: 4, wordsPerBlock: 6)
        store.seed(item, content: content)

        center.play(item: item, content: content)
        waitUntil(self.center.state == .playing(itemID: item.id), message: "center never reached playing")

        let rsvp = makeRSVP(item: item, content: content)
        // Freshly built, the reader hasn't observed a state CHANGE (playback was
        // already underway), so it starts paused — exactly the stale state a
        // mode switch leaves behind.
        XCTAssertFalse(rsvp.isPlaying)

        rsvp.configureForReuse(item: item, content: content, audioEnabled: true)

        XCTAssertTrue(rsvp.isPlaying,
            "Returning to RSVP while the center is voicing this article must show playing")
    }

    /// The complementary case: with the center idle (nothing playing), a reused
    /// RSVP must settle on paused rather than spuriously claiming playback.
    func testReuseWhileCenterIdleShowsPaused() {
        let item = AudioPlaybackFixtures.item(seed: "rsvp-idle")
        let content = AudioPlaybackFixtures.content(blockCount: 3, wordsPerBlock: 5)
        store.seed(item, content: content)

        let rsvp = makeRSVP(item: item, content: content)
        rsvp.configureForReuse(item: item, content: content, audioEnabled: true)

        XCTAssertFalse(rsvp.isPlaying,
            "With the center idle, a reused RSVP must show paused")
    }

    /// Playback of a DIFFERENT article must not be adopted — ownership is keyed
    /// on the item id, so returning to RSVP for article B while the center voices
    /// article A stays paused.
    func testReuseDoesNotAdoptOtherArticlesPlayback() {
        let playing = AudioPlaybackFixtures.item(seed: "rsvp-other-playing")
        let playingContent = AudioPlaybackFixtures.content(blockCount: 4, wordsPerBlock: 6)
        store.seed(playing, content: playingContent)
        center.play(item: playing, content: playingContent)
        waitUntil(self.center.state == .playing(itemID: playing.id), message: "center never reached playing")

        let other = AudioPlaybackFixtures.item(seed: "rsvp-other-shown")
        let otherContent = AudioPlaybackFixtures.content(blockCount: 3, wordsPerBlock: 5)
        store.seed(other, content: otherContent)

        let rsvp = makeRSVP(item: other, content: otherContent)
        rsvp.configureForReuse(item: other, content: otherContent, audioEnabled: true)

        XCTAssertFalse(rsvp.isPlaying,
            "RSVP for a different article must not adopt the center's playback")
    }
}
