import LunaModels
//
//  CardPlaybackSpeedTests.swift
//  LunaTests
//
//  A paused media card shows its playback controls: the position bar inside
//  the card's bottom edge (over a soft black scrim for contrast) and, above
//  the bar's left end, the glass speed pill. These tests pin the halves of
//  that contract — when the controls are up, where they sit, what the pill
//  offers, and that the chosen speed is remembered PER ITEM in memory (so a
//  card unmounted two slots out comes back at the speed the user left it) and
//  never written to disk.
//

import UIKit
import XCTest
@testable import Luna
@testable import LunaDesignSystem
@testable import LunaMediaDownload

final class CardPlaybackSpeedTests: XCTestCase {

    override func setUp() {
        super.setUp()
        PlaybackSpeedMemory.shared.reset()
    }

    override func tearDown() {
        PlaybackSpeedMemory.shared.reset()
        super.tearDown()
    }

    // MARK: - Stubs

    /// Stands in for a video card: a timeline that can be paused, with a
    /// position bar and a chooseable rate.
    private final class StubPlayableContent: CardContentViewController {
        var playing = false
        var speed = PlaybackSpeed.normal
        var playable = true
        var hasPositionBar = true
        var hasSpeed = true
        var fraction: Double = 0.25

        override var isPlayable: Bool { playable }
        override var isPlaying: Bool { playing }
        override var showsPlaybackScrubProgress: Bool { hasPositionBar }
        override var supportsPlaybackSpeed: Bool { hasSpeed }
        override var playbackSpeed: Double { speed }
        override var playbackFraction: Double { fraction }

        override func setPlaying(_ playing: Bool) {
            guard self.playing != playing else { return }
            self.playing = playing
            reportPlaybackStateChange()
        }

        override func setPlaybackSpeed(_ speed: Double) {
            self.speed = speed
        }
    }

    private final class StubDataSource: CardCarouselDataSource {
        let content: StubPlayableContent

        init(content: StubPlayableContent) {
            self.content = content
        }

        func numberOfCards(in carousel: CardCarouselViewController) -> Int { 1 }

        func carousel(
            _ carousel: CardCarouselViewController,
            contentControllerForCardAt index: Int
        ) -> CardContentViewController { content }

        func carousel(
            _ carousel: CardCarouselViewController,
            loadThumbnailForCardAt index: Int,
            completion: @escaping (UIImage?) -> Void
        ) { completion(nil) }

        func carousel(
            _ carousel: CardCarouselViewController,
            edgeGlowColorForCardAt index: Int
        ) -> UIColor? { nil }
    }

    /// A windowless deck showing one card, laid out and visible — the resting
    /// state every control decision is made against.
    @MainActor
    private func makeDeck(
        _ content: StubPlayableContent
    ) -> (CardCarouselViewController, StubDataSource) {
        let dataSource = StubDataSource(content: content)
        let carousel = CardCarouselViewController()
        carousel.dataSource = dataSource
        carousel.loadViewIfNeeded()
        carousel.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        carousel.view.layoutIfNeeded()
        carousel.reloadData()
        carousel.viewDidAppear(false)
        return (carousel, dataSource)
    }

    // MARK: - When the controls are up

    @MainActor
    func testPausingTheCenteredCardRaisesThePositionBarAndSpeedPill() {
        let content = StubPlayableContent()
        let (carousel, _) = makeDeck(content)

        XCTAssertTrue(content.playing, "Centering a playable card autoplays it")
        XCTAssertFalse(
            carousel.isPlaybackPositionBarShowingForTesting,
            "A playing card shows no controls over its content")
        XCTAssertNil(carousel.playbackSpeedPillForTesting)

        content.setPlaying(false)

        XCTAssertTrue(carousel.isPlaybackPositionBarShowingForTesting)
        XCTAssertEqual(carousel.playbackSpeedPillForTesting?.speed, PlaybackSpeed.normal)
    }

    @MainActor
    func testResumingPlaybackTakesTheControlsBackDown() {
        let content = StubPlayableContent()
        let (carousel, _) = makeDeck(content)
        content.setPlaying(false)
        XCTAssertTrue(carousel.isPlaybackPositionBarShowingForTesting)

        content.setPlaying(true)

        XCTAssertFalse(carousel.isPlaybackPositionBarShowingForTesting)
        XCTAssertNil(carousel.playbackSpeedPillForTesting)
    }

    /// A GIF is a paused timeline with no position bar of its own and one rate —
    /// it must not acquire either control.
    @MainActor
    func testContentWithoutAPositionBarShowsNoControlsWhenPaused() {
        let content = StubPlayableContent()
        content.hasPositionBar = false
        let (carousel, _) = makeDeck(content)

        content.setPlaying(false)

        XCTAssertFalse(carousel.isPlaybackPositionBarShowingForTesting)
        XCTAssertNil(carousel.playbackSpeedPillForTesting)
    }

    @MainActor
    func testFixedRateContentGetsTheBarButNoSpeedPill() {
        let content = StubPlayableContent()
        content.hasSpeed = false
        let (carousel, _) = makeDeck(content)

        content.setPlaying(false)

        XCTAssertTrue(carousel.isPlaybackPositionBarShowingForTesting)
        XCTAssertNil(carousel.playbackSpeedPillForTesting)
    }

    @MainActor
    func testControlsLeaveWithTheCardWhenTheDeckStepsAsideForASecondColumn() {
        let content = StubPlayableContent()
        let (carousel, _) = makeDeck(content)
        content.setPlaying(false)
        XCTAssertTrue(carousel.isPlaybackPositionBarShowingForTesting)

        carousel.setColumnAside(shift: -120)

        XCTAssertFalse(carousel.isPlaybackPositionBarShowingForTesting)
        XCTAssertNil(carousel.playbackSpeedPillForTesting)
    }

    // MARK: - The pill

    @MainActor
    func testPillOffersTheFiveSpeedsAndChecksTheCurrentOne() {
        let content = StubPlayableContent()
        content.speed = 1.5
        let (carousel, _) = makeDeck(content)
        content.setPlaying(false)

        let options = carousel.playbackSpeedPillForTesting?.menuOptionsForTesting ?? []

        XCTAssertEqual(options.map(\.speed), [0.25, 0.5, 1, 1.5, 2])
        XCTAssertEqual(options.filter(\.isChecked).map(\.speed), [1.5])
    }

    @MainActor
    func testPickingASpeedAppliesItToTheCenteredCard() {
        let content = StubPlayableContent()
        let (carousel, _) = makeDeck(content)
        content.setPlaying(false)

        carousel.playbackSpeedPillForTesting?.selectSpeedForTesting(2)

        XCTAssertEqual(content.playbackSpeed, 2)
        XCTAssertEqual(carousel.playbackSpeedPillForTesting?.speed, 2)
    }

    /// The pill is frame-managed, so a picked speed must re-fit the frame to
    /// the new label — "0.25×" is wider than "1×", and inside the old width it
    /// wrapped onto a second line.
    @MainActor
    func testPickingAWiderSpeedRefitsThePillToOneLine() throws {
        let content = StubPlayableContent()
        let (carousel, _) = makeDeck(content)
        content.setPlaying(false)
        let pill = try XCTUnwrap(carousel.playbackSpeedPillForTesting)
        let narrowWidth = pill.frame.width

        pill.selectSpeedForTesting(0.25)

        let fitted = pill.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
        XCTAssertGreaterThan(pill.frame.width, narrowWidth, "0.25× needs more room than 1×")
        XCTAssertEqual(pill.frame.width, fitted.width, accuracy: 0.5)
        XCTAssertEqual(
            pill.frame.height, fitted.height, accuracy: 0.5,
            "a frame at the fitting size cannot be wrapping its title")
    }

    /// The bar sits INSIDE the card, bare over the video (no backdrop of its
    /// own), riding the controls inset above the card's bottom edge with the
    /// pill floating above its left end.
    @MainActor
    func testPausedControlsSitInsideTheCard() throws {
        let content = StubPlayableContent()
        let (carousel, _) = makeDeck(content)
        content.setPlaying(false)

        let bar = try XCTUnwrap(carousel.playbackScrubBarFrameForTesting)
        let card = try XCTUnwrap(carousel.cardView(at: 0))
        XCTAssertTrue(card.frame.contains(bar), "the bar overlays the video now")
        XCTAssertEqual(bar.maxY, card.frame.maxY - 12, accuracy: 0.5)

        let pillFrame = try XCTUnwrap(carousel.playbackSpeedPillFrameForTesting)
        XCTAssertEqual(pillFrame.maxY, bar.minY - 8, accuracy: 0.5)
        XCTAssertEqual(pillFrame.minX, bar.minX, accuracy: 0.5)
    }

    @MainActor
    func testPillLabelsReadAsMultiples() {
        XCTAssertEqual(PlaybackSpeed.label(for: 1), "1×")
        XCTAssertEqual(PlaybackSpeed.label(for: 0.25), "0.25×")
        XCTAssertEqual(PlaybackSpeed.label(for: 1.5), "1.5×")
        XCTAssertEqual(PlaybackSpeed.label(for: 2), "2×")
    }

    // MARK: - Per-item memory

    func testSpeedIsRememberedPerKeyAndDefaultsToNormal() {
        let memory = PlaybackSpeedMemory.shared
        XCTAssertEqual(memory.speed(forKey: "a"), PlaybackSpeed.normal)

        memory.setSpeed(2, forKey: "a")
        memory.setSpeed(0.5, forKey: "b")

        XCTAssertEqual(memory.speed(forKey: "a"), 2)
        XCTAssertEqual(memory.speed(forKey: "b"), 0.5)
        XCTAssertEqual(
            memory.speed(forKey: nil), PlaybackSpeed.normal,
            "Content with nothing to remember by always starts at normal speed")
    }

    /// The card is destroyed as soon as it is two slots from center, so a NEW
    /// player built for the same item is what has to come back at 2×.
    @MainActor
    func testVideoContentRebuiltForTheSameItemResumesAtTheRememberedSpeed() {
        let fileURL = URL(fileURLWithPath: "/dev/null/clip.mp4")
        let key = "savedMedia.\(UUID().uuidString)"

        let first = VideoCardContentViewController(fileURL: fileURL, speedMemoryKey: key)
        XCTAssertEqual(first.playbackSpeed, PlaybackSpeed.normal)
        first.setPlaybackSpeed(2)

        let rebuilt = VideoCardContentViewController(fileURL: fileURL, speedMemoryKey: key)
        XCTAssertEqual(rebuilt.playbackSpeed, 2)

        let otherItem = VideoCardContentViewController(
            fileURL: fileURL, speedMemoryKey: "savedMedia.\(UUID().uuidString)")
        XCTAssertEqual(
            otherItem.playbackSpeed, PlaybackSpeed.normal,
            "The speed belongs to one item, not to media in general")
    }

    /// Memory only: nothing about a chosen speed may reach the App Group store
    /// or user defaults, so a fresh process starts every item at 1× again.
    @MainActor
    func testChosenSpeedIsNeverPersisted() {
        let key = "savedMedia.\(UUID().uuidString)"
        VideoCardContentViewController(
            fileURL: URL(fileURLWithPath: "/dev/null/clip.mp4"), speedMemoryKey: key
        ).setPlaybackSpeed(0.25)

        // The process boundary, as far as a memory-only store is concerned.
        PlaybackSpeedMemory.shared.reset()

        XCTAssertEqual(PlaybackSpeedMemory.shared.speed(forKey: key), PlaybackSpeed.normal)
    }

    /// One key per media row, shared by both decks and the fullscreen player.
    func testMediaSpeedKeyIsTheRowIdentity() {
        let id = UUID()
        let item = SavedMediaItem(
            id: id, sourceURLString: "https://x.com/luna/status/1", title: "Clip",
            dateSaved: Date(), kind: .video, storageState: .undownloaded,
            thumbnailFileName: nil)

        XCTAssertEqual(
            MediaCardFactory.speedMemoryKey(for: item), "savedMedia.\(id.uuidString)")
    }
}
