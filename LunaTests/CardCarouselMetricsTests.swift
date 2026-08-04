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

    /// The bar lives INSIDE the card's bottom edge now — over the video, backed
    /// by the controller's scrim — leaving the runway beneath the card to the
    /// thumbnail strip.
    func testPlaybackScrubProgressSitsInsideTheCardBottomEdge() {
        let metrics = CardCarouselMetrics.resolve(containerSize: CGSize(width: 400, height: 800))
        let cardFrame = metrics.centeredCardFrame()
        let progressFrame = metrics.playbackScrubProgressFrame(height: 20)

        XCTAssertEqual(progressFrame.maxY, cardFrame.maxY - 12, accuracy: 0.01)
        XCTAssertEqual(progressFrame.minX, cardFrame.minX + 18, accuracy: 0.01)
        XCTAssertEqual(progressFrame.maxX, cardFrame.maxX - 18, accuracy: 0.01)
        XCTAssertTrue(cardFrame.contains(progressFrame))
    }

    func testFillIgnoresAspectAndTakesEveryPoint() {
        let metrics = CardCarouselMetrics.resolve(
            containerSize: CGSize(width: 400, height: 600),
            peek: 14, edgeGap: 10, verticalPadding: 12, fit: .fill)
        XCTAssertEqual(metrics.cardSize.width, 400 - 2 * (14 + 10), accuracy: 0.01)
        XCTAssertEqual(metrics.cardSize.height, 600 - 24, accuracy: 0.01)
        XCTAssertEqual(metrics.centerY(), 300, accuracy: 0.01)
    }

    func testAspectFromBottomAddsItsExtraHeightAtTheTop() {
        // The article deck's container: too SHORT for a 9:16 card at its width,
        // so the card overflows the container's top — and only its top. Compared
        // against `.fill`, which is what the same container used to yield.
        let container = CGSize(width: 402, height: 626)
        let filled = CardCarouselMetrics.resolve(
            containerSize: container,
            peek: 14, edgeGap: 10, verticalPadding: 12, fit: .fill)
        let metrics = CardCarouselMetrics.resolve(
            containerSize: container,
            peek: 14, edgeGap: 10, verticalPadding: 12,
            fit: .aspectFromBottom, topOverflow: 48)

        // Same width; exactly 9:16, so taller than the container's usable height.
        XCTAssertEqual(metrics.cardSize.width, filled.cardSize.width, accuracy: 0.01)
        XCTAssertEqual(
            metrics.cardSize.width / metrics.cardSize.height,
            CardCarouselMetrics.cardAspectRatio,
            accuracy: 0.0001)
        XCTAssertGreaterThan(metrics.cardSize.height, filled.cardSize.height)

        // Bottom edge unmoved; the whole gain is above the old top edge.
        let frame = metrics.centeredCardFrame()
        let filledFrame = filled.centeredCardFrame()
        XCTAssertEqual(frame.maxY, filledFrame.maxY, accuracy: 0.01)
        XCTAssertEqual(
            filledFrame.minY - frame.minY,
            metrics.cardSize.height - filled.cardSize.height,
            accuracy: 0.01)
        XCTAssertLessThan(frame.minY, 0)   // above the container's own top
    }

    func testAspectFromBottomNeverOverflowsMoreThanAllowed() {
        // A container too wide for its height, but still phone-shaped enough to
        // escape the wide-container width cap (a landscape phone): the card
        // can't have the full width at 9:16 within the overflow allowance, so it
        // narrows — the aspect stays exact and the overflow stops at the
        // allowance.
        let container = CGSize(width: LunaLayout.wideThreshold - 10, height: 400)
        let metrics = CardCarouselMetrics.resolve(
            containerSize: container,
            peek: 14, edgeGap: 10, verticalPadding: 12,
            fit: .aspectFromBottom, topOverflow: 48)
        XCTAssertEqual(
            metrics.cardSize.width / metrics.cardSize.height,
            CardCarouselMetrics.cardAspectRatio,
            accuracy: 0.0001)
        XCTAssertLessThan(metrics.cardSize.width, container.width - 2 * (14 + 10))
        XCTAssertEqual(metrics.cardSize.height, 400 - 24 + 48, accuracy: 0.01)
        // Clamped: the card's top stops one `verticalPadding` inside the
        // allowance — 36pt above the container, not the full 48.
        XCTAssertEqual(metrics.centeredCardFrame().minY, -(48 - 12), accuracy: 0.01)
    }

    // MARK: - Wide containers (iPad)

    /// The half-width cap, which is the whole reason two reader columns fit.
    func testWideContainerCapsEveryFitAtHalfTheWidthMinusPadding() throws {
        let container = CGSize(width: 1024, height: 1200)
        let cap = try XCTUnwrap(LunaLayout.cardWidthCap(forContainerWidth: container.width))
        XCTAssertEqual(cap, 1024 / 2 - 36, accuracy: 0.01)

        for fit in [CardCarouselMetrics.CardFit.aspectCentered, .fill, .aspectFromBottom] {
            let metrics = CardCarouselMetrics.resolve(
                containerSize: container,
                peek: 14, edgeGap: 10, verticalPadding: 12,
                fit: fit, topOverflow: 48)
            XCTAssertLessThanOrEqual(
                metrics.cardSize.width, cap + 0.01, "\(fit) ignored the wide width cap")
        }
    }

    /// Two capped cards plus the gap between them span exactly the container
    /// minus one edge padding on each side — the geometry the side-by-side
    /// reader relies on to reuse one card width for both of its columns.
    func testTwoCappedCardsAndTheGapFillTheContainerBetweenItsEdgePaddings() throws {
        for width in [744, 834, 1024, 1366] as [CGFloat] {
            let cap = try XCTUnwrap(LunaLayout.cardWidthCap(forContainerWidth: width))
            XCTAssertEqual(
                cap * 2 + LunaLayout.columnGap,
                width - LunaLayout.wideEdgePadding * 2,
                accuracy: 0.01)
            XCTAssertEqual(
                LunaLayout.columnCenterOffset(forContainerWidth: width),
                cap / 2 + LunaLayout.columnGap / 2,
                accuracy: 0.01)
        }
    }

    /// A capped card is shorter than an iPad's card area, so anchoring its
    /// bottom would strand it under a band of dead space. It grows into the room
    /// and centers instead — bounded so it never becomes a sliver.
    func testWideAspectFromBottomGrowsIntoTheRoomAndCenters() {
        let container = CGSize(width: 834, height: 1100)
        let metrics = CardCarouselMetrics.resolve(
            containerSize: container,
            peek: 14, edgeGap: 10, verticalPadding: 12,
            fit: .aspectFromBottom, topOverflow: 48)

        XCTAssertEqual(metrics.centerY(), container.height / 2, accuracy: 0.01)
        XCTAssertGreaterThan(
            metrics.cardSize.height, metrics.cardSize.width / CardCarouselMetrics.cardAspectRatio,
            "the card should claim more than its 9:16 height")
        XCTAssertEqual(
            metrics.cardSize.width / metrics.cardSize.height,
            LunaLayout.tallestCardAspectRatio,
            accuracy: 0.0001)
        XCTAssertGreaterThanOrEqual(metrics.centeredCardFrame().minY, 0)
    }

    /// A landscape iPad is short enough that the exact-aspect card is still
    /// taller than the room, so it keeps the phone behaviour: bottom-anchored,
    /// overflowing up through the allowance.
    func testWideButShortContainerKeepsTheBottomAnchoredOverflow() {
        let container = CGSize(width: 1194, height: 700)
        let metrics = CardCarouselMetrics.resolve(
            containerSize: container,
            peek: 14, edgeGap: 10, verticalPadding: 12,
            fit: .aspectFromBottom, topOverflow: 48)
        XCTAssertEqual(
            metrics.cardSize.width / metrics.cardSize.height,
            CardCarouselMetrics.cardAspectRatio,
            accuracy: 0.0001)
        XCTAssertEqual(metrics.centeredCardFrame().minY, -(48 - 12), accuracy: 0.01)
    }

    /// Media cards are 9:16 because their CONTENT is: capping the width must not
    /// start letterboxing them vertically.
    func testWideAspectCenteredStaysExactly9By16() {
        let metrics = CardCarouselMetrics.resolve(
            containerSize: CGSize(width: 1024, height: 1200),
            peek: 14, edgeGap: 10, verticalPadding: 12, fit: .aspectCentered)
        XCTAssertEqual(
            metrics.cardSize.width / metrics.cardSize.height,
            CardCarouselMetrics.cardAspectRatio,
            accuracy: 0.0001)
    }

    /// The threshold is a cliff, so pin both sides of it: one point below, the
    /// card still takes every point the peeks leave.
    func testJustBelowTheThresholdNothingIsCapped() {
        let width = LunaLayout.wideThreshold - 1
        XCTAssertNil(LunaLayout.cardWidthCap(forContainerWidth: width))
        let metrics = CardCarouselMetrics.resolve(
            containerSize: CGSize(width: width, height: 2000),
            peek: 14, edgeGap: 10, verticalPadding: 12, fit: .fill)
        XCTAssertEqual(metrics.cardSize.width, width - 2 * (14 + 10), accuracy: 0.01)
    }

    func testAspectFromBottomWithNoAllowanceStaysInsideTheContainer() {
        let metrics = CardCarouselMetrics.resolve(
            containerSize: CGSize(width: 402, height: 626),
            peek: 14, edgeGap: 10, verticalPadding: 12, fit: .aspectFromBottom)
        let frame = metrics.centeredCardFrame()
        XCTAssertEqual(frame.minY, 12, accuracy: 0.01)
        XCTAssertEqual(frame.maxY, 614, accuracy: 0.01)
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

final class CardCarouselPagePanSimultaneityPolicyTests: XCTestCase {

    func testReaderContentKeepsItsGesturesWhileTheSwipeIsStillJustADrag() {
        XCTAssertTrue(
            allowsSimultaneousRecognition(
                otherIsScrollViewPan: true, pagePanIsTrackingTheTouch: false))
    }

    func testAPageSwipeDoesNotAlsoScrollTheCardItStartedOn() {
        XCTAssertFalse(
            allowsSimultaneousRecognition(
                otherIsScrollViewPan: true, pagePanIsTrackingTheTouch: true))
    }

    func testNonScrollingContentGesturesStillCoexistWithAPageInFlight() {
        XCTAssertTrue(
            allowsSimultaneousRecognition(
                otherIsScrollViewPan: false, pagePanIsTrackingTheTouch: true))
    }

    func testSurfacesWithoutInCardPagingShareNothing() {
        XCTAssertFalse(
            CardCarouselPagePanSimultaneityPolicy.allowsSimultaneousRecognition(
                pagesOnInCardSwipes: false,
                otherIsScrollViewPan: false,
                pagePanIsTrackingTheTouch: false))
    }

    private func allowsSimultaneousRecognition(
        otherIsScrollViewPan: Bool,
        pagePanIsTrackingTheTouch: Bool
    ) -> Bool {
        CardCarouselPagePanSimultaneityPolicy.allowsSimultaneousRecognition(
            pagesOnInCardSwipes: true,
            otherIsScrollViewPan: otherIsScrollViewPan,
            pagePanIsTrackingTheTouch: pagePanIsTrackingTheTouch)
    }
}

@MainActor
final class CardCarouselScrollViewSearchTests: XCTestCase {

    func testEveryNestedScrollViewIsFoundOutermostFirst() {
        // A mounted reader card: the article scroller, with a web frame's own
        // scroll view inside it.
        let cardArea = UIView()
        let card = UIView()
        let article = UIScrollView()
        let webFrame = UIScrollView()
        cardArea.addSubview(card)
        card.addSubview(article)
        article.addSubview(UIView())
        article.addSubview(webFrame)

        let found = CardCarouselScrollViews.nested(in: cardArea)

        XCTAssertEqual(found.count, 2)
        XCTAssertTrue(found.first === article)
        XCTAssertTrue(found.last === webFrame)
    }

    func testACardAreaWithNoScrollingContentFindsNothing() {
        let cardArea = UIView()
        cardArea.addSubview(UIView())

        XCTAssertTrue(CardCarouselScrollViews.nested(in: cardArea).isEmpty)
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

    /// Releasing a mini-card scrub must settle in place even when the preview
    /// never mounted the card's real content — a media save, whose player the
    /// strip deliberately doesn't build per chip, previewed as its poster. It
    /// used to fall through to the eclipse, so letting go of a video chip in
    /// the all-kinds deck played a page transition to a card already on screen.
    func testScrubSettleOnAPosterOnlyCardHandsOverWithoutTheEclipse() throws {
        let source = PosterOnlyScrubDataSource()
        let carousel = CardCarouselViewController()
        var style = CardCarouselStyle()
        style.scrubberStyle = .miniCards
        carousel.style = style
        carousel.dataSource = source

        // On-window, so the eclipse is available to be wrongly chosen.
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = carousel
        window.isHidden = false
        window.layoutIfNeeded()
        carousel.reloadData(centeringAt: 3)
        carousel.beginAppearanceTransition(true, animated: false)
        carousel.endAppearanceTransition()

        let mounted = try XCTUnwrap(carousel.contentController(at: 4))
        let scrubber = try XCTUnwrap(firstScrubber(in: carousel.view))
        scrubber.delegate?.scrubber(scrubber, didPreview: 4)
        scrubber.delegate?.scrubber(scrubber, didCommit: 4)

        XCTAssertEqual(
            carousel.currentIndex, 4,
            "The release settles at once; an eclipse would still be mid-flight")
        XCTAssertTrue(
            carousel.view.isUserInteractionEnabled,
            "No transition runs on release, so input is never blocked")
        XCTAssertTrue(
            carousel.contentController(at: 4) === mounted,
            "The card already standing behind the preview is the one handed over")
        XCTAssertNotNil(carousel.contentController(at: 5), "The window follows the settle")
        window.isHidden = true
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

/// A deck whose cards have no preview content to prepare — the shape the
/// all-kinds deck takes for a media save (`allowsPreparedPreviewContent`
/// false), which previews as a poster and has nothing to promote on release.
@MainActor
private final class PosterOnlyScrubDataSource: @preconcurrency CardCarouselDataSource {
    let cardCount = 7

    func numberOfCards(in carousel: CardCarouselViewController) -> Int { cardCount }

    func carousel(
        _ carousel: CardCarouselViewController,
        contentControllerForCardAt index: Int
    ) -> CardContentViewController {
        CenteringSpyCardContentViewController()
    }

    func carousel(
        _ carousel: CardCarouselViewController,
        previewContentControllerForCardAt index: Int
    ) -> CardContentViewController? { nil }

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
        let oldImage = UIImage(systemName: "1.circle")
        let currentImage = UIImage(systemName: "2.circle")

        preview.show(at: 0, cardCount: 2)
        preview.show(at: 1, cardCount: 2)
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

/// The starfield behind the cards is handed to the carousel as `chromeBackdrop`
/// so it leaves and returns with the rest of the chrome, on the same curve.
final class CardCarouselChromeBackdropTests: XCTestCase {

    @MainActor
    private func makeCarousel() -> CardCarouselViewController {
        let carousel = CardCarouselViewController()
        carousel.loadViewIfNeeded()
        carousel.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        carousel.view.layoutIfNeeded()
        return carousel
    }

    @MainActor
    func testBackdropFadesOutAndBackWithImmersion() {
        let carousel = makeCarousel()
        let backdrop = StarfieldView(frame: carousel.view.bounds)
        carousel.view.insertSubview(backdrop, at: 0)
        carousel.chromeBackdrop = backdrop
        XCTAssertEqual(backdrop.alpha, 1, accuracy: 0.001)

        carousel.setImmersed(true, animated: false)
        XCTAssertEqual(backdrop.alpha, 0, accuracy: 0.001, "stars should leave with the chrome")

        carousel.setImmersed(false, animated: false)
        XCTAssertEqual(backdrop.alpha, 1, accuracy: 0.001, "stars should come back with it")
    }

    /// Weak, so a host that tears its backdrop down mid-immersion doesn't leave
    /// the carousel holding a dangling view.
    @MainActor
    func testBackdropReferenceIsWeak() {
        let carousel = makeCarousel()
        autoreleasepool {
            let backdrop = StarfieldView(frame: carousel.view.bounds)
            carousel.chromeBackdrop = backdrop
            XCTAssertNotNil(carousel.chromeBackdrop)
        }
        XCTAssertNil(carousel.chromeBackdrop)
        // Immersion must stay safe with nothing registered.
        carousel.setImmersed(true, animated: false)
    }
}

/// The strip's util chip: the deck's permanent first card reads as a mark over a
/// button rather than as a save's still or a favicon-and-skeleton mini card.
@MainActor
final class CarouselScrubberUtilityChipTests: XCTestCase {

    func testUtilityChipCentersItsMarkAboveCenterWithAPillBeneathIt() throws {
        let strip = CarouselScrubberView(style: .miniCards)
        strip.frame = CGRect(x: 0, y: 0, width: 320, height: strip.preferredHeight)
        strip.setThumbnailCount(3)
        let icon = Self.solidImage(side: 40)
        strip.setUtilityChip(icon: icon, at: 0)
        strip.layoutIfNeeded()

        let chip = try XCTUnwrap(Self.chip(carrying: icon, in: strip))
        let mark = try XCTUnwrap(
            chip.subviews.compactMap { $0 as? UIImageView }.first { $0.image === icon })
        XCTAssertEqual(mark.contentMode, .scaleAspectFit)
        // Same size as a mini card's source badge, centered horizontally, and
        // lifted off the chip's own center by 1.3.
        XCTAssertEqual(mark.bounds.width, 16, accuracy: 0.01)
        XCTAssertEqual(mark.bounds.height, 16, accuracy: 0.01)
        XCTAssertEqual(mark.center.x, chip.bounds.midX, accuracy: 1)
        XCTAssertEqual(
            mark.center.y, chip.bounds.height / 2 / 1.3, accuracy: 1)

        let pill = try XCTUnwrap(chip.subviews.last { view in
            !(view is UIImageView) && !view.isHidden
                && view.bounds.height > 4 && view.bounds.height < 12
        })
        XCTAssertGreaterThan(pill.frame.minY, mark.frame.maxY)
        XCTAssertEqual(pill.center.x, chip.bounds.midX, accuracy: 1)
        XCTAssertEqual(pill.layer.cornerRadius, pill.bounds.height / 2, accuracy: 0.01)
    }

    func testASaveArtworkTakesTheChipBackFromTheUtilityLayout() throws {
        let strip = CarouselScrubberView(style: .miniCards)
        strip.frame = CGRect(x: 0, y: 0, width: 320, height: strip.preferredHeight)
        strip.setThumbnailCount(2)
        let icon = Self.solidImage(side: 40)
        strip.setUtilityChip(icon: icon, at: 0)
        strip.layoutIfNeeded()
        let chip = try XCTUnwrap(Self.chip(carrying: icon, in: strip))

        strip.setBadge(.symbol("safari.fill"), at: 0)
        strip.layoutIfNeeded()

        XCTAssertNil(
            chip.subviews.compactMap { $0 as? UIImageView }.first { $0.image === icon })
    }

    private static func chip(carrying icon: UIImage, in strip: UIView) -> UIView? {
        for view in strip.subviews {
            if view.subviews.contains(where: { ($0 as? UIImageView)?.image === icon }) {
                return view
            }
            if let match = chip(carrying: icon, in: view) { return match }
        }
        return nil
    }

    private static func solidImage(side: CGFloat) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        }
    }
}
