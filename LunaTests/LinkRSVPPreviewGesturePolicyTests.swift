//
//  LinkRSVPPreviewGesturePolicyTests.swift
//  LunaTests
//


import LunaReaderUI
import XCTest

final class LinkRSVPPreviewGesturePolicyTests: XCTestCase {
    func testVerticalThresholdSelectsPlaybackMenuAndLock() {
        XCTAssertEqual(LinkRSVPPreviewGesturePolicy.verticalMode(
            translation: CGPoint(x: 200, y: 0)), .playback)
        XCTAssertEqual(LinkRSVPPreviewGesturePolicy.verticalMode(
            translation: CGPoint(x: 0, y: -56)), .menu)
        XCTAssertEqual(LinkRSVPPreviewGesturePolicy.verticalMode(
            translation: CGPoint(x: 0, y: 56)), .lock)
    }

    func testHorizontalDragUsesDeadZoneAndTemporarySymmetricScaling() {
        XCTAssertEqual(LinkRSVPPreviewGesturePolicy.effectiveWPM(
            baseWPM: 300, horizontalTranslation: 20), 300, accuracy: 0.001)
        let slower = LinkRSVPPreviewGesturePolicy.effectiveWPM(
            baseWPM: 300, horizontalTranslation: -100)
        let faster = LinkRSVPPreviewGesturePolicy.effectiveWPM(
            baseWPM: 300, horizontalTranslation: 100)
        XCTAssertLessThan(slower, 300)
        XCTAssertGreaterThan(faster, 300)
        XCTAssertEqual(slower * faster, 90_000, accuracy: 1)
    }

    func testHorizontalSpeedIsCappedAtHalfAndDoubleBase() {
        XCTAssertEqual(LinkRSVPPreviewGesturePolicy.effectiveWPM(
            baseWPM: 420, horizontalTranslation: -10_000), 210, accuracy: 0.001)
        XCTAssertEqual(LinkRSVPPreviewGesturePolicy.effectiveWPM(
            baseWPM: 420, horizontalTranslation: 10_000), 840, accuracy: 0.001)
    }

    func testFarLeftPausesForContext() {
        XCTAssertFalse(LinkRSVPPreviewGesturePolicy.pausesForContext(
            horizontalTranslation: -173))
        XCTAssertTrue(LinkRSVPPreviewGesturePolicy.pausesForContext(
            horizontalTranslation: -174))
    }

    func testVerticalHapticRampHasThreeStepsBeforeThreshold() {
        XCTAssertEqual(LinkRSVPPreviewGesturePolicy.verticalHapticStep(translationY: 23), 0)
        XCTAssertEqual(LinkRSVPPreviewGesturePolicy.verticalHapticStep(translationY: -24), 1)
        XCTAssertEqual(LinkRSVPPreviewGesturePolicy.verticalHapticStep(translationY: 35), 2)
        XCTAssertEqual(LinkRSVPPreviewGesturePolicy.verticalHapticStep(translationY: -46), 3)
        XCTAssertEqual(LinkRSVPPreviewGesturePolicy.verticalHapticStep(translationY: 56), 0)
    }

    func testCardPrefersAboveFingerAndFallsBelowNearTopEdge() {
        XCTAssertEqual(LinkRSVPPreviewGesturePolicy.cardOriginY(
            touchY: 500, cardHeight: 190, boundsHeight: 874,
            safeTop: 59, safeBottom: 34), 272)
        XCTAssertEqual(LinkRSVPPreviewGesturePolicy.cardOriginY(
            touchY: 100, cardHeight: 190, boundsHeight: 874,
            safeTop: 59, safeBottom: 34), 130)
    }

    func testTitleHasLongMinimumDurationAndResumePrefix() {
        XCTAssertEqual(LinkRSVPPreviewGesturePolicy.titleDuration(baseWPM: 900), 1.4)
        XCTAssertEqual(LinkRSVPPreviewGesturePolicy.titleText(title: "An Article", resumeIndex: 0),
                       "An Article")
        XCTAssertEqual(LinkRSVPPreviewGesturePolicy.titleText(title: "An Article", resumeIndex: 12),
                       "Resuming: An Article")
    }
}
