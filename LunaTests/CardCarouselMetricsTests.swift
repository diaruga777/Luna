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

    /// **One shape, every container.** Every kind's card is the same exact
    /// 9:16 rectangle, centered in the container. A per-kind card shape
    /// produces different frames and centers across the deck, which visibly
    /// jumps when paging between kinds.
    func testEveryContainerYieldsAnExact9By16CardCenteredInTheRoom() {
        for size in [
            CGSize(width: 320, height: 600),
            CGSize(width: 402, height: 626),
            CGSize(width: 440, height: 708),
            CGSize(width: 744, height: 1_000),
            CGSize(width: 1_200, height: 700),
        ] {
            let metrics = CardCarouselMetrics.resolve(containerSize: size)
            let frame = metrics.centeredCardFrame()
            XCTAssertEqual(
                frame.width / frame.height,
                CardCarouselMetrics.cardAspectRatio,
                accuracy: 0.0001, "\(size)")
            XCTAssertGreaterThan(frame.height, frame.width, "\(size)")
            XCTAssertEqual(frame.midY, size.height / 2, accuracy: 0.01, "\(size)")
            XCTAssertEqual(frame.midX, size.width / 2, accuracy: 0.01, "\(size)")
            XCTAssertGreaterThanOrEqual(
                frame.minY, CardCarouselMetrics.verticalPadding - 0.01,
                "\(size) overflowed its own padding")
            XCTAssertLessThanOrEqual(
                frame.maxY, size.height - CardCarouselMetrics.verticalPadding + 0.01, "\(size)")
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

    // MARK: - Wide containers (iPad)

    /// A tall iPad should use its available height rather than leaving most of
    /// it empty to preserve room for a possible second reader column.
    func testTallWideContainerAspectFitsTheAvailableHeight() {
        let container = CGSize(width: 1024, height: 1200)
        let metrics = CardCarouselMetrics.resolve(containerSize: container)
        XCTAssertEqual(
            metrics.cardSize.height,
            container.height - CardCarouselMetrics.verticalPadding * 2,
            accuracy: 0.01)
        XCTAssertEqual(
            metrics.cardSize.width / metrics.cardSize.height,
            CardCarouselMetrics.cardAspectRatio,
            accuracy: 0.0001)
    }

    func testTinyContainerDegradesGracefully() {
        let metrics = CardCarouselMetrics.resolve(containerSize: CGSize(width: 10, height: 10))
        XCTAssertGreaterThan(metrics.cardSize.width, 0)
        XCTAssertGreaterThan(metrics.cardSize.height, 0)
    }
}

final class CarouselScrubberMathTests: XCTestCase {

    /// A chip showing a still fills its whole item — the picture IS the chip,
    /// over the mini card's furniture rather than inset within it.
    func testThumbnailImageKeepsItsItemBoundsAfterInitialLayout() throws {
        let scrubber = CarouselScrubberView()
        scrubber.frame = CGRect(x: 0, y: 0, width: 390, height: scrubber.preferredHeight)
        scrubber.setThumbnailCount(3)
        scrubber.layoutIfNeeded()

        let imageView = try XCTUnwrap(firstImageView(in: scrubber))
        let item = try XCTUnwrap(imageView.superview)
        XCTAssertEqual(imageView.frame, item.bounds)
    }

    func testLargeCountKeepsOnlyAVisibleWindowOfReusableCells() throws {
        let scrubber = CarouselScrubberView()
        scrubber.frame = CGRect(x: 0, y: 0, width: 390, height: scrubber.preferredHeight)
        scrubber.setThumbnailCount(10_000)
        scrubber.layoutIfNeeded()

        let collection = try XCTUnwrap(firstCollectionView(in: scrubber))
        XCTAssertEqual(collection.numberOfItems(inSection: 0), 10_000)
        XCTAssertGreaterThan(collection.visibleCells.count, 0)
        XCTAssertLessThan(collection.visibleCells.count, 20)
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

    private func firstCollectionView(in view: UIView) -> UICollectionView? {
        if let collection = view as? UICollectionView { return collection }
        return view.subviews.lazy.compactMap { self.firstCollectionView(in: $0) }.first
    }
}

@MainActor
final class CardEclipseTransitionCancellationTests: XCTestCase {

    func testInterruptedIngressCleansEveryDressingViewAndCompletesOnce() {
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
        let outgoing = CarouselCardView(frame: CGRect(x: 60, y: 40, width: 270, height: 480))
        let incoming = CarouselCardView(frame: CGRect(x: 340, y: 40, width: 270, height: 480))
        let opposite = CarouselCardView(frame: CGRect(x: -220, y: 40, width: 270, height: 480))
        [opposite, outgoing, incoming].forEach(container.addSubview)
        let outgoingSubviewCount = outgoing.subviews.count
        let oppositeSubviewCount = opposite.subviews.count
        var completions: [Bool] = []

        let transition = CardEclipseTransition(
            in: container,
            outgoing: outgoing,
            incoming: incoming,
            oppositePeek: opposite,
            forward: true,
            incomingTargetCenter: outgoing.center,
            dimmingBounds: container.bounds,
            atZenith: { CardEclipseZenithResult(reappearingPeeks: []) },
            completion: { completions.append($0) })
        transition.update(fraction: 0.92)
        transition.cancel()
        transition.cancel()

        XCTAssertEqual(completions, [false])
        XCTAssertEqual(container.subviews.count, 3)
        XCTAssertEqual(outgoing.subviews.count, outgoingSubviewCount)
        XCTAssertEqual(opposite.subviews.count, oppositeSubviewCount)
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
        centeredContentScrubs: Bool = false,
        velocity: CGPoint
    ) -> CardCarouselPagePanStartDecision {
        CardCarouselPagePanStartPolicy.decision(
            isTransitioning: false,
            isImmersed: isImmersed,
            startsInsideCenteredCard: startsInsideCenteredCard,
            pagesOnInCardSwipes: true,
            centeredContentScrubs: centeredContentScrubs,
            velocity: velocity)
    }

    /// A playable card's whole width is a timeline: the same drag scrubs it,
    /// so it must never ALSO page — even on the decks that page on in-card
    /// swipes for their readers. Edge swipes stay the paging affordance.
    func testInCardPanOverPlayableContentScrubsInsteadOfPaging() {
        XCTAssertEqual(
            decision(
                isImmersed: false,
                startsInsideCenteredCard: true,
                centeredContentScrubs: true,
                velocity: CGPoint(x: 500, y: 10)),
            .reject)
        XCTAssertEqual(
            decision(
                isImmersed: false,
                startsInsideCenteredCard: false,
                centeredContentScrubs: true,
                velocity: CGPoint(x: 500, y: 10)),
            .accept,
            "an edge swipe still pages past a video card")
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
        try await assertScrubberTapEclipse(from: 3, to: 5)
    }

    func testReaderTapTwoCardsBackwardStagesTargetAndUsesEclipseBeforeCenteringIt() async throws {
        try await assertScrubberTapEclipse(from: 3, to: 1)
    }

    func testDownloaderTapOneCardUsesEclipse() async throws {
        try await assertScrubberTapEclipse(from: 3, to: 4)
    }

    private func assertScrubberTapEclipse(
        from start: Int,
        to target: Int
    ) async throws {
        let source = MiniCardPagingDataSource()
        let delegate = NavigationTargetSpy()
        let carousel = CardCarouselViewController()
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
        XCTAssertEqual(staged.centerCount, 0,
                       "centering work must wait until eclipse egress finishes")
        let farIndex = target + (target > start ? 1 : -1)
        XCTAssertNil(source.contentControllers[farIndex],
                     "the new far peek must not be constructed under totality")

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
        XCTAssertGreaterThan(staged.centerCount, 0)
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
    private(set) var contentControllers: [Int: CenteringSpyCardContentViewController] = [:]

    func numberOfCards(in carousel: CardCarouselViewController) -> Int { cardCount }

    func carousel(
        _ carousel: CardCarouselViewController,
        contentControllerForCardAt index: Int
    ) -> CardContentViewController {
        let content = CenteringSpyCardContentViewController()
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
final class CardCarouselScrubScalingTests: XCTestCase {

    func testLargeDeckRequestsArtworkOnlyForVisibleChips() throws {
        let source = LargeScrubDataSource()
        let carousel = CardCarouselViewController()
        carousel.dataSource = source
        carousel.loadViewIfNeeded()
        carousel.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        carousel.view.layoutIfNeeded()
        carousel.reloadData(centeringAt: 0)
        carousel.view.layoutIfNeeded()

        XCTAssertFalse(source.thumbnailRequests.isEmpty)
        XCTAssertLessThan(source.thumbnailRequests.count, 20)
        XCTAssertLessThan(source.thumbnailRequests.max() ?? .max, 20)
    }

    func testScrubPreviewDoesNotConstructRealContentUntilCommit() throws {
        let source = LargeScrubDataSource()
        let carousel = CardCarouselViewController()
        carousel.dataSource = source
        carousel.loadViewIfNeeded()
        carousel.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        carousel.view.layoutIfNeeded()
        carousel.reloadData(centeringAt: 0)

        let target = 50
        let scrubber = try XCTUnwrap(firstScrubber(in: carousel.view))
        scrubber.delegate?.scrubber(scrubber, didPreview: target)
        XCTAssertNil(source.contentRequestCounts[target],
                     "moving the finger must draw only lightweight chrome/poster")

        scrubber.delegate?.scrubber(scrubber, didCommit: target)
        XCTAssertEqual(source.contentRequestCounts[target], 1)
        XCTAssertEqual(carousel.currentIndex, target)
    }

    /// Releasing a mini-card scrub must settle in place even when the preview
    /// never mounted the card's real content — a media save, whose player the
    /// strip deliberately doesn't build per chip, previewed as its poster.
    /// Falling through to the eclipse here would play a page transition to a
    /// card already on screen.
    func testScrubSettleOnAPosterOnlyCardHandsOverWithoutTheEclipse() throws {
        let source = LargeScrubDataSource(cardCount: 7)
        let carousel = CardCarouselViewController()
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

}

@MainActor
private final class LargeScrubDataSource: @preconcurrency CardCarouselDataSource {
    let cardCount: Int
    var contentRequestCounts: [Int: Int] = [:]
    var thumbnailRequests: [Int] = []

    init(cardCount: Int = 10_000) { self.cardCount = cardCount }

    func numberOfCards(in carousel: CardCarouselViewController) -> Int { cardCount }

    func carousel(
        _ carousel: CardCarouselViewController,
        contentControllerForCardAt index: Int
    ) -> CardContentViewController {
        contentRequestCounts[index, default: 0] += 1
        return CenteringSpyCardContentViewController()
    }

    func carousel(
        _ carousel: CardCarouselViewController,
        loadThumbnailForCardAt index: Int,
        completion: @escaping (UIImage?) -> Void
    ) {
        thumbnailRequests.append(index)
        completion(nil)
    }

    func carousel(
        _ carousel: CardCarouselViewController,
        prefersThumbnailChipForCardAt index: Int
    ) -> Bool { true }
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

@MainActor
private final class ViewportTransitionSpyContent: CardContentViewController {
    private(set) var preparedSizes: [CGSize] = []
    private(set) var animateCount = 0
    private(set) var completions: [Bool] = []

    override func prepareForCardViewportTransition(to size: CGSize) {
        preparedSizes.append(size)
    }

    override func animatePreparedCardViewportTransition() {
        animateCount += 1
    }

    override func finishCardViewportTransition(completed: Bool) {
        completions.append(completed)
    }
}

@MainActor
private final class OneCardViewportDataSource: @preconcurrency CardCarouselDataSource {
    let content = ViewportTransitionSpyContent()

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
}

@MainActor
private final class AudioCardContent: CardContentViewController {
    override var supportsAudio: Bool { true }
}

@MainActor
private final class OneAudioCardDataSource: @preconcurrency CardCarouselDataSource {
    let content = AudioCardContent()

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
}

@MainActor
final class CardCarouselExpandedImmersionTests: XCTestCase {

    private func makeCarousel() -> (CardCarouselViewController, OneCardViewportDataSource) {
        let source = OneCardViewportDataSource()
        let carousel = CardCarouselViewController()
        carousel.dataSource = source
        carousel.loadViewIfNeeded()
        carousel.view.frame = CGRect(x: 0, y: 0, width: 1_024, height: 1_366)
        carousel.view.layoutIfNeeded()
        carousel.reloadData()
        carousel.view.layoutIfNeeded()
        return (carousel, source)
    }

    func testHorizontalInsetExpandsOnlyTheImmersedCenteredCard() throws {
        let (carousel, _) = makeCarousel()
        let resting = try XCTUnwrap(carousel.restingCenteredCardFrame(in: carousel.view))

        carousel.setImmersed(
            true, extendsCard: true, horizontalInset: 16, animated: false)
        let expandedCard = try XCTUnwrap(carousel.cardView(at: 0))
        let expanded = expandedCard.convert(expandedCard.bounds, to: carousel.view)
        XCTAssertEqual(expanded.minX, 16, accuracy: 0.5)
        XCTAssertEqual(expanded.maxX, 1_008, accuracy: 0.5)
        XCTAssertGreaterThan(expanded.width, resting.width)

        carousel.setImmersed(false, animated: false)
        let restored = expandedCard.convert(expandedCard.bounds, to: carousel.view)
        XCTAssertEqual(restored.minX, resting.minX, accuracy: 0.5)
        XCTAssertEqual(restored.width, resting.width, accuracy: 0.5)
    }

    func testAnimatedExpansionCoordinatesContentWithDestinationSize() throws {
        let (carousel, source) = makeCarousel()
        carousel.setImmersed(
            true, extendsCard: true, horizontalInset: 16, animated: true)

        let prepared = try XCTUnwrap(source.content.preparedSizes.last)
        XCTAssertEqual(prepared.width, 992, accuracy: 0.5)
        XCTAssertEqual(source.content.animateCount, 1)
        // Complete the property animation deterministically in the test runloop.
        let completion = expectation(description: "viewport transition completed")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { completion.fulfill() }
        wait(for: [completion], timeout: 1)
        XCTAssertEqual(source.content.completions.count, 1,
                       "the content must always retire its temporary presentation")
    }

    func testImmersionPinsOptedInMuteToggleToSafeScreenCornerAndRestoresIt() throws {
        let source = OneAudioCardDataSource()
        let carousel = CardCarouselViewController()
        var style = CardCarouselStyle()
        style.movesMuteButtonToScreenEdgeWhenImmersed = true
        carousel.style = style
        carousel.dataSource = source
        carousel.loadViewIfNeeded()
        carousel.view.frame = CGRect(x: 0, y: 0, width: 1_024, height: 1_366)
        carousel.view.layoutIfNeeded()
        carousel.reloadData()
        carousel.view.layoutIfNeeded()

        let button = try XCTUnwrap(Self.findButton(labelled: "Unmute", in: carousel.view))
        let restingCard = try XCTUnwrap(carousel.restingCenteredCardFrame(in: carousel.view))
        let resting = button.convert(button.bounds, to: carousel.view)
        XCTAssertEqual(resting.maxX, restingCard.maxX - CarouselCardView.muteButtonInset, accuracy: 0.5)
        XCTAssertEqual(resting.minY, restingCard.minY + CarouselCardView.muteButtonInset, accuracy: 0.5)

        carousel.setImmersed(true, extendsCard: true, horizontalInset: 16, animated: false)
        let immersed = button.convert(button.bounds, to: carousel.view)
        XCTAssertEqual(
            immersed.maxX,
            carousel.view.bounds.maxX - CarouselCardView.muteButtonInset,
            accuracy: 0.5)
        XCTAssertEqual(
            immersed.minY,
            carousel.view.safeAreaInsets.top + CarouselCardView.muteButtonInset,
            accuracy: 0.5)

        carousel.setImmersed(false, animated: false)
        let restored = button.convert(button.bounds, to: carousel.view)
        XCTAssertEqual(restored.maxX, restingCard.maxX - CarouselCardView.muteButtonInset, accuracy: 0.5)
        XCTAssertEqual(restored.minY, restingCard.minY + CarouselCardView.muteButtonInset, accuracy: 0.5)
    }

    private static func findButton(labelled label: String, in view: UIView) -> UIButton? {
        if let button = view as? UIButton, button.accessibilityLabel == label { return button }
        return view.subviews.lazy.compactMap { findButton(labelled: label, in: $0) }.first
    }
}

/// The strip's util chip: the deck's permanent first card reads as a mark over a
/// button rather than as a save's still or a favicon-and-skeleton mini card.
@MainActor
final class CarouselScrubberUtilityChipTests: XCTestCase {

    func testUtilityChipCentersItsMarkAboveCenterWithAPillBeneathIt() throws {
        let strip = CarouselScrubberView()
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
        let strip = CarouselScrubberView()
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
