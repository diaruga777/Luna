//
//  AudioPlaybackHandoffTests.swift
//  LunaTests
//

import LunaModels
import XCTest
@testable import LunaAudioPlayback

/// Phase 6, product requirement C: `AudioPlaybackCenter.restorableHandoffIfAvailable()`
/// is the non-mutating peek behind the launch-time paused mini-player preview
/// (extension → main-app playback handoff). It must say yes only for a
/// RECENT, still-valid persisted position, and never touch `state`/the
/// engine — every case here asserts `center.state` stays `.idle` throughout.
final class AudioPlaybackHandoffTests: XCTestCase {

    private var store: FakePlaybackStore!
    private var renderer: FakeRenderer!
    private var engine: FakeAudioEngine!
    private var session: FakeSessionCoordinator!
    private var positionDefaults: UserDefaults!
    private var positionSuiteName: String!
    private var positionStore: AudioPlaybackPositionStore!
    private var center: AudioPlaybackCenter!

    override func setUp() {
        super.setUp()
        store = FakePlaybackStore()
        renderer = FakeRenderer()
        engine = FakeAudioEngine()
        session = FakeSessionCoordinator()
        positionSuiteName = "AudioPlaybackHandoffTests.\(UUID().uuidString)"
        positionDefaults = UserDefaults(suiteName: positionSuiteName)
        positionStore = AudioPlaybackPositionStore(defaults: positionDefaults)
        center = AudioPlaybackCenter(
            store: store, renderer: renderer, positionStore: positionStore,
            sessionCoordinator: session, engineFactory: { [engine] _ in engine! })
    }

    override func tearDown() {
        positionDefaults.removePersistentDomain(forName: positionSuiteName)
        center = nil
        super.tearDown()
    }

    // MARK: - No persisted position

    func testNilWhenNothingPersisted() {
        XCTAssertNil(center.restorableHandoffIfAvailable())
        XCTAssertEqual(center.state, .idle)
    }

    // MARK: - Recency

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

    // MARK: - Missing item / content guards

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

    // MARK: - "Nothing is playing" guard

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

    // MARK: - Progress estimate

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

    // MARK: - Title fallback

    func testEmptyPersistedTitleFallsBackToTheItemOrContentTitle() {
        let item = AudioPlaybackFixtures.item(seed: "title-fallback", title: "Item Title")
        let content = AudioPlaybackFixtures.content(blockCount: 2, wordsPerBlock: 4)
        store.seed(item, content: content)
        positionStore.save(.init(itemID: item.id, wordIndex: 0, elapsed: 0, title: ""))

        XCTAssertEqual(center.restorableHandoffIfAvailable()?.title, "Item Title")
    }
}
