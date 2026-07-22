//
//  CardCarouselMetricsTests.swift
//  LunaTests
//
//  Pure-math coverage of the card-carousel layout (portrait 9:16 cards with
//  neighbor peeks) and the scrub strip's index mapping.
//

import XCTest
@testable import LunaDesignSystem

final class CardCarouselMetricsTests: XCTestCase {

    func testWidthLimitedContainerFitsCardWithPeeks() {
        // A phone-portrait-ish container: the card is limited by width (it must
        // leave room for both neighbors' peeked edges), not height.
        let metrics = CardCarouselMetrics.resolve(
            containerSize: CGSize(width: 400, height: 800),
            peek: 14, edgeGap: 10, sideScale: 0.92, verticalPadding: 12)
        XCTAssertEqual(metrics.cardSize.width, 400 - 2 * (14 + 10), accuracy: 0.01)
        XCTAssertEqual(
            metrics.cardSize.height,
            metrics.cardSize.width * 16 / 9,
            accuracy: 0.01)
        XCTAssertLessThanOrEqual(metrics.cardSize.height, 800 - 24 + 0.01)
    }

    func testHeightLimitedContainerKeepsAspect() {
        // A short, wide container: height limits the card.
        let metrics = CardCarouselMetrics.resolve(
            containerSize: CGSize(width: 900, height: 500),
            peek: 14, edgeGap: 10, sideScale: 0.92, verticalPadding: 12)
        XCTAssertEqual(metrics.cardSize.height, 500 - 24, accuracy: 0.01)
        XCTAssertEqual(
            metrics.cardSize.width,
            metrics.cardSize.height * 9 / 16,
            accuracy: 0.01)
    }

    func testCardIsAlwaysTallerThanWide() {
        for size in [CGSize(width: 320, height: 600), CGSize(width: 1200, height: 700)] {
            let metrics = CardCarouselMetrics.resolve(containerSize: size)
            XCTAssertGreaterThan(metrics.cardSize.height, metrics.cardSize.width)
        }
    }

    func testSlotCentersLeaveExactlyPeekVisible() {
        let metrics = CardCarouselMetrics.resolve(
            containerSize: CGSize(width: 400, height: 800),
            peek: 14, edgeGap: 10, sideScale: 0.92)
        XCTAssertEqual(metrics.centerX(forSlotOffset: 0), 200, accuracy: 0.01)

        // The scaled right neighbor's near (left) edge sits `peek` points inside
        // the container's right edge.
        let scaledWidth = metrics.cardSize.width * 0.92
        let rightNearEdge = metrics.centerX(forSlotOffset: 1) - scaledWidth / 2
        XCTAssertEqual(rightNearEdge, 400 - 14, accuracy: 0.01)
        let leftNearEdge = metrics.centerX(forSlotOffset: -1) + scaledWidth / 2
        XCTAssertEqual(leftNearEdge, 14, accuracy: 0.01)

        // Slots further out continue off screen, one scaled card per step.
        XCTAssertEqual(
            metrics.centerX(forSlotOffset: 2) - metrics.centerX(forSlotOffset: 1),
            scaledWidth,
            accuracy: 0.01)
    }

    func testScaleShrinksOnlySideSlots() {
        let metrics = CardCarouselMetrics.resolve(
            containerSize: CGSize(width: 400, height: 800), sideScale: 0.92)
        XCTAssertEqual(metrics.scale(forSlotOffset: 0), 1)
        XCTAssertEqual(metrics.scale(forSlotOffset: 1), 0.92)
        XCTAssertEqual(metrics.scale(forSlotOffset: -3), 0.92)
    }

    func testCenteredCardFrameIsCentered() {
        let metrics = CardCarouselMetrics.resolve(containerSize: CGSize(width: 400, height: 800))
        let frame = metrics.centeredCardFrame()
        XCTAssertEqual(frame.midX, 200, accuracy: 0.01)
        XCTAssertEqual(frame.midY, 400, accuracy: 0.01)
        XCTAssertEqual(frame.size, metrics.cardSize)
    }

    func testPlaybackScrubProgressSitsBelowCenteredCard() {
        let metrics = CardCarouselMetrics.resolve(containerSize: CGSize(width: 400, height: 800))
        let cardFrame = metrics.centeredCardFrame()
        let progressFrame = metrics.playbackScrubProgressFrame(height: 20)

        XCTAssertEqual(progressFrame.minY, cardFrame.maxY + 8, accuracy: 0.01)
        XCTAssertEqual(progressFrame.minX, cardFrame.minX + 18, accuracy: 0.01)
        XCTAssertEqual(progressFrame.maxX, cardFrame.maxX - 18, accuracy: 0.01)
    }

    func testTinyContainerDegradesGracefully() {
        let metrics = CardCarouselMetrics.resolve(containerSize: CGSize(width: 10, height: 10))
        XCTAssertGreaterThan(metrics.cardSize.width, 0)
        XCTAssertGreaterThan(metrics.cardSize.height, 0)
    }
}

final class CarouselScrubberMathTests: XCTestCase {

    func testThumbnailImageKeepsItsItemBoundsAfterInitialLayout() throws {
        let scrubber = CarouselScrubberView(style: .thumbnails)
        scrubber.frame = CGRect(x: 0, y: 0, width: 390, height: scrubber.preferredHeight)
        scrubber.setThumbnailCount(3)
        scrubber.layoutIfNeeded()

        let imageView = try XCTUnwrap(firstImageView(in: scrubber))
        let item = try XCTUnwrap(imageView.superview)
        XCTAssertEqual(imageView.frame, item.bounds)
    }

    func testMiniCardsReserveSelectionAndShadowRunway() {
        let scrubber = CarouselScrubberView(style: .miniCards)
        XCTAssertEqual(scrubber.preferredHeight, 96)
    }

    func testIndexMapsLocationAcrossThumbnails() {
        // 26pt thumbs, 5pt spacing: each slot spans 31pt.
        XCTAssertEqual(CarouselScrubberMath.index(
            forLocationX: 0, thumbnailWidth: 26, spacing: 5, count: 10), 0)
        XCTAssertEqual(CarouselScrubberMath.index(
            forLocationX: 30, thumbnailWidth: 26, spacing: 5, count: 10), 0)
        XCTAssertEqual(CarouselScrubberMath.index(
            forLocationX: 31, thumbnailWidth: 26, spacing: 5, count: 10), 1)
        XCTAssertEqual(CarouselScrubberMath.index(
            forLocationX: 155, thumbnailWidth: 26, spacing: 5, count: 10), 5)
    }

    func testIndexClampsToValidRange() {
        XCTAssertEqual(CarouselScrubberMath.index(
            forLocationX: -50, thumbnailWidth: 26, spacing: 5, count: 10), 0)
        XCTAssertEqual(CarouselScrubberMath.index(
            forLocationX: 10_000, thumbnailWidth: 26, spacing: 5, count: 10), 9)
        XCTAssertEqual(CarouselScrubberMath.index(
            forLocationX: 40, thumbnailWidth: 26, spacing: 5, count: 0), 0)
    }

    private func firstImageView(in view: UIView) -> UIImageView? {
        if let imageView = view as? UIImageView { return imageView }
        return view.subviews.lazy.compactMap { self.firstImageView(in: $0) }.first
    }
}

final class CardCarouselPagePanStartPolicyTests: XCTestCase {

    func testHorizontalEdgePanIsAcceptedWhetherChromeIsVisibleOrImmersed() {
        let velocity = CGPoint(x: -500, y: 40)

        XCTAssertEqual(
            decision(isImmersed: false, startsInsideCenteredCard: false, velocity: velocity),
            .accept)
        XCTAssertEqual(
            decision(isImmersed: true, startsInsideCenteredCard: false, velocity: velocity),
            .acceptAndSurface)
    }

    func testVerticalEdgePanDoesNotSurfaceOrPage() {
        XCTAssertEqual(
            decision(
                isImmersed: true,
                startsInsideCenteredCard: false,
                velocity: CGPoint(x: 40, y: 500)),
            .reject)
    }

    func testImmersedInCardPanRemainsOwnedByReaderContent() {
        XCTAssertEqual(
            decision(
                isImmersed: true,
                startsInsideCenteredCard: true,
                velocity: CGPoint(x: 500, y: 10)),
            .reject)
    }

    private func decision(
        isImmersed: Bool,
        startsInsideCenteredCard: Bool,
        velocity: CGPoint
    ) -> CardCarouselPagePanStartDecision {
        CardCarouselPagePanStartPolicy.decision(
            isTransitioning: false,
            isImmersed: isImmersed,
            startsInsideCenteredCard: startsInsideCenteredCard,
            pagesOnInCardSwipes: true,
            velocity: velocity)
    }
}

@MainActor
final class CardCarouselScrubberTapPagingTests: XCTestCase {

    func testScrubberTapEclipseIsFasterThanStandardPaging() {
        XCTAssertLessThan(
            CardEclipseTransition.scrubberTapDuration,
            CardEclipseTransition.duration)
    }

    func testReaderTapTwoCardsForwardStagesTargetAndUsesEclipseBeforeCenteringIt() async throws {
        try await assertScrubberTapEclipse(style: .miniCards, from: 3, to: 5)
    }

    func testReaderTapTwoCardsBackwardStagesTargetAndUsesEclipseBeforeCenteringIt() async throws {
        try await assertScrubberTapEclipse(style: .miniCards, from: 3, to: 1)
    }

    func testDownloaderTapOneCardUsesEclipse() async throws {
        try await assertScrubberTapEclipse(style: .thumbnails, from: 3, to: 4)
    }

    func testDownloaderTapTwoCardsStagesTargetAndUsesEclipse() async throws {
        try await assertScrubberTapEclipse(style: .thumbnails, from: 3, to: 5)
    }

    func testDownloaderTapTwoCardsBackwardStagesTargetAndUsesEclipse() async throws {
        try await assertScrubberTapEclipse(style: .thumbnails, from: 3, to: 1)
    }

    private func assertScrubberTapEclipse(
        style scrubberStyle: CarouselScrubberView.Style,
        from start: Int,
        to target: Int
    ) async throws {
        let source = MiniCardPagingDataSource()
        let delegate = NavigationTargetSpy()
        let carousel = CardCarouselViewController()
        var style = CardCarouselStyle()
        style.scrubberStyle = scrubberStyle
        carousel.style = style
        carousel.dataSource = source
        carousel.delegate = delegate

        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = carousel
        window.isHidden = false
        window.layoutIfNeeded()
        carousel.reloadData(centeringAt: start)

        let scrubber = try XCTUnwrap(firstScrubber(in: carousel.view))
        scrubber.delegate?.scrubber(scrubber, didTap: target)

        XCTAssertEqual(delegate.targets, [target],
                       "Peripheral chrome must receive the target before the eclipse")
        XCTAssertEqual(carousel.currentIndex, start,
                       "The target must not replace the current card before totality")
        XCTAssertFalse(carousel.view.isUserInteractionEnabled,
                       "An automatic eclipse blocks input while it is in flight")
        let staged = try XCTUnwrap(source.contentControllers[target])
        XCTAssertTrue(staged.parent === carousel)
        XCTAssertGreaterThan(staged.view.bounds.width, 0)
        XCTAssertGreaterThan(staged.view.bounds.height, 0)

        let settled = expectation(description: "multi-card eclipse settled")
        DispatchQueue.main.asyncAfter(
            deadline: .now() + CardEclipseTransition.scrubberTapDuration + 0.12
        ) {
            settled.fulfill()
        }
        await fulfillment(
            of: [settled], timeout: CardEclipseTransition.scrubberTapDuration + 1)

        XCTAssertEqual(carousel.currentIndex, target)
        XCTAssertTrue(carousel.view.isUserInteractionEnabled)
        XCTAssertTrue(carousel.contentController(at: target) === staged)
        XCTAssertNotNil(carousel.contentController(at: max(0, target - 1)))
        XCTAssertNotNil(carousel.contentController(at: min(source.cardCount - 1, target + 1)))
        window.isHidden = true
    }

    private func firstScrubber(in view: UIView) -> CarouselScrubberView? {
        if let scrubber = view as? CarouselScrubberView { return scrubber }
        return view.subviews.lazy.compactMap { self.firstScrubber(in: $0) }.first
    }
}

@MainActor
private final class NavigationTargetSpy: @preconcurrency CardCarouselDelegate {
    private(set) var targets: [Int] = []

    func carousel(
        _ carousel: CardCarouselViewController,
        navigationTargetDidChangeTo index: Int
    ) {
        targets.append(index)
    }
}

@MainActor
private final class MiniCardPagingDataSource: @preconcurrency CardCarouselDataSource {
    let cardCount = 7
    private(set) var contentControllers: [Int: CardContentViewController] = [:]

    func numberOfCards(in carousel: CardCarouselViewController) -> Int { cardCount }

    func carousel(
        _ carousel: CardCarouselViewController,
        contentControllerForCardAt index: Int
    ) -> CardContentViewController {
        let content = CardContentViewController()
        contentControllers[index] = content
        return content
    }

    func carousel(
        _ carousel: CardCarouselViewController,
        loadThumbnailForCardAt index: Int,
        completion: @escaping (UIImage?) -> Void
    ) { completion(nil) }
}

@MainActor
final class CardCarouselScrubPromotionTests: XCTestCase {

    func testCommitPromotesPlayingPreviewWithoutPausingOrReplacingItAndPreservesSoundState() throws {
        let source = ScrubPromotionDataSource()
        let delegate = NavigationTargetSpy()
        let carousel = CardCarouselViewController()
        var style = CardCarouselStyle()
        style.autoplaysScrubPreviewContent = true
        carousel.style = style
        carousel.dataSource = source
        carousel.delegate = delegate
        carousel.loadViewIfNeeded()
        carousel.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        carousel.view.layoutIfNeeded()
        carousel.reloadData(centeringAt: 0)

        let muteButton = try XCTUnwrap(firstButton(labelled: "Unmute", in: carousel.view))
        muteButton.sendActions(for: .touchUpInside)

        let scrubber = try XCTUnwrap(firstScrubber(in: carousel.view))
        scrubber.delegate?.scrubber(scrubber, didPreview: 1)
        XCTAssertEqual(delegate.targets, [1])
        XCTAssertTrue(source.preview.isPlaying)
        XCTAssertFalse(source.preview.isMuted)
        XCTAssertEqual(source.preview.pauseCount, 0)

        scrubber.delegate?.scrubber(scrubber, didCommit: 1)

        XCTAssertEqual(carousel.currentIndex, 1)
        XCTAssertTrue(source.preview.parent === carousel)
        XCTAssertTrue(source.preview.isPlaying)
        XCTAssertEqual(source.preview.pauseCount, 0)
        XCTAssertEqual(source.normalRequestCounts[1], 1)
    }

    func testMiniCardScrubberPreparesOnlyVisibleWindowAndPromotesExactPreview() throws {
        let source = VisibleWindowScrubDataSource()
        let carousel = CardCarouselViewController()
        var style = CardCarouselStyle()
        style.scrubberStyle = .miniCards
        carousel.style = style
        carousel.dataSource = source
        carousel.loadViewIfNeeded()
        carousel.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        carousel.view.layoutIfNeeded()
        carousel.reloadData(centeringAt: 0)
        carousel.beginAppearanceTransition(true, animated: false)
        carousel.endAppearanceTransition()

        let preparedIndices = source.previewControllers.keys.sorted()
        XCTAssertFalse(preparedIndices.isEmpty)
        XCTAssertLessThan(preparedIndices.count, source.cardCount)

        let target = try XCTUnwrap(preparedIndices.first(where: { $0 != 0 }))
        let preview = try XCTUnwrap(source.previewControllers[target])
        let scrubber = try XCTUnwrap(firstScrubber(in: carousel.view))
        scrubber.delegate?.scrubber(scrubber, didPreview: target)
        scrubber.delegate?.scrubber(scrubber, didCommit: target)

        XCTAssertEqual(carousel.currentIndex, target)
        XCTAssertTrue(carousel.contentController(at: target) === preview)
        XCTAssertEqual(preview.centerCount, 1)
        XCTAssertLessThanOrEqual(source.previewRequestCounts[target] ?? 0, 2)
    }

    private func firstScrubber(in view: UIView) -> CarouselScrubberView? {
        if let scrubber = view as? CarouselScrubberView { return scrubber }
        return view.subviews.lazy.compactMap { self.firstScrubber(in: $0) }.first
    }

    private func firstButton(labelled label: String, in view: UIView) -> UIButton? {
        if let button = view as? UIButton, button.accessibilityLabel == label { return button }
        return view.subviews.lazy.compactMap { self.firstButton(labelled: label, in: $0) }.first
    }
}

@MainActor
private final class VisibleWindowScrubDataSource: @preconcurrency CardCarouselDataSource {
    let cardCount = 40
    var previewControllers: [Int: CenteringSpyCardContentViewController] = [:]
    var previewRequestCounts: [Int: Int] = [:]

    func numberOfCards(in carousel: CardCarouselViewController) -> Int { cardCount }

    func carousel(
        _ carousel: CardCarouselViewController,
        contentControllerForCardAt index: Int
    ) -> CardContentViewController {
        CardContentViewController()
    }

    func carousel(
        _ carousel: CardCarouselViewController,
        previewContentControllerForCardAt index: Int
    ) -> CardContentViewController? {
        previewRequestCounts[index, default: 0] += 1
        let content = CenteringSpyCardContentViewController()
        previewControllers[index] = content
        return content
    }

    func carousel(
        _ carousel: CardCarouselViewController,
        loadThumbnailForCardAt index: Int,
        completion: @escaping (UIImage?) -> Void
    ) { completion(nil) }
}

@MainActor
private final class CenteringSpyCardContentViewController: CardContentViewController {
    private(set) var centerCount = 0

    override func cardDidBecomeCentered() {
        centerCount += 1
        super.cardDidBecomeCentered()
    }
}

@MainActor
private final class ScrubPromotionDataSource: @preconcurrency CardCarouselDataSource {
    let preview = PlaybackSpyCardContentViewController()
    var normalRequestCounts: [Int: Int] = [:]

    func numberOfCards(in carousel: CardCarouselViewController) -> Int { 3 }

    func carousel(
        _ carousel: CardCarouselViewController,
        contentControllerForCardAt index: Int
    ) -> CardContentViewController {
        normalRequestCounts[index, default: 0] += 1
        return PlaybackSpyCardContentViewController()
    }

    func carousel(
        _ carousel: CardCarouselViewController,
        previewContentControllerForCardAt index: Int
    ) -> CardContentViewController? { preview }

    func carousel(
        _ carousel: CardCarouselViewController,
        loadThumbnailForCardAt index: Int,
        completion: @escaping (UIImage?) -> Void
    ) { completion(nil) }
}

@MainActor
private final class PlaybackSpyCardContentViewController: CardContentViewController {
    private(set) var playing = false
    private(set) var pauseCount = 0
    private(set) var isMuted = true

    override var isPlayable: Bool { true }
    override var isPlaying: Bool { playing }

    override func setPlaying(_ playing: Bool) {
        self.playing = playing
        if !playing { pauseCount += 1 }
    }

    override func setMuted(_ muted: Bool) {
        isMuted = muted
    }
}

@MainActor
final class CarouselScrubPreviewRaceTests: XCTestCase {

    func testLateThumbnailCannotReplaceTheNewerScrubPreview() async throws {
        let source = DelayedThumbnailDataSource()
        let carousel = CardCarouselViewController()
        carousel.dataSource = source
        carousel.loadViewIfNeeded()
        let cardArea = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 560))
        let preview = CarouselScrubPreviewController(carousel: carousel, cardArea: cardArea)
        let frame = CGRect(x: 10, y: 10, width: 300, height: 520)
        let oldImage = UIImage(systemName: "1.circle")
        let currentImage = UIImage(systemName: "2.circle")

        preview.show(at: 0, cardCount: 2, centeredCardFrame: frame)
        preview.show(at: 1, cardCount: 2, centeredCardFrame: frame)
        source.complete(index: 1, with: currentImage)
        source.complete(index: 0, with: oldImage)

        let mainQueueDrained = expectation(description: "thumbnail completions applied")
        DispatchQueue.main.async { mainQueueDrained.fulfill() }
        await fulfillment(of: [mainQueueDrained], timeout: 1)

        XCTAssertTrue(preview.previewImageForTesting === currentImage)
    }
}

@MainActor
private final class DelayedThumbnailDataSource: @preconcurrency CardCarouselDataSource {
    private var completions: [Int: (UIImage?) -> Void] = [:]

    func numberOfCards(in carousel: CardCarouselViewController) -> Int { 2 }

    func carousel(
        _ carousel: CardCarouselViewController,
        contentControllerForCardAt index: Int
    ) -> CardContentViewController { CardContentViewController() }

    func carousel(
        _ carousel: CardCarouselViewController,
        loadThumbnailForCardAt index: Int,
        completion: @escaping (UIImage?) -> Void
    ) {
        completions[index] = completion
    }

    func complete(index: Int, with image: UIImage?) {
        completions.removeValue(forKey: index)?(image)
    }
}
