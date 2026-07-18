//
//  CardCarouselMetricsTests.swift
//  LunaTests
//
//  Pure-math coverage of the card-carousel layout (portrait 9:16 cards with
//  neighbor peeks) and the scrub strip's index mapping / flick classification.
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

    func testTinyContainerDegradesGracefully() {
        let metrics = CardCarouselMetrics.resolve(containerSize: CGSize(width: 10, height: 10))
        XCTAssertGreaterThan(metrics.cardSize.width, 0)
        XCTAssertGreaterThan(metrics.cardSize.height, 0)
    }
}

final class CarouselScrubberMathTests: XCTestCase {

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

    func testQuickShortSwipeIsAFlick() {
        XCTAssertEqual(CarouselScrubberMath.flickPageStep(
            translationX: -40, velocityX: -900, duration: 0.12), 1)
        XCTAssertEqual(CarouselScrubberMath.flickPageStep(
            translationX: 35, velocityX: 800, duration: 0.15), -1)
    }

    func testSlowOrLongDragsAreScrubsNotFlicks() {
        // Too slow.
        XCTAssertNil(CarouselScrubberMath.flickPageStep(
            translationX: -40, velocityX: -200, duration: 0.2))
        // Too long a press.
        XCTAssertNil(CarouselScrubberMath.flickPageStep(
            translationX: -40, velocityX: -900, duration: 0.8))
        // Traveled too far — the user was dragging through cards.
        XCTAssertNil(CarouselScrubberMath.flickPageStep(
            translationX: -200, velocityX: -900, duration: 0.25))
    }
}
