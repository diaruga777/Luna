//
//  MacSeamTests.swift
//  LunaTests
//
//  The witnesses WP-F introduced so a Mac composition root is a wiring
//  change rather than a rewrite: the UIKit↔pure bridges in LunaGaze agree
//  with each other, and the accessory-bar / keyboard-metrics witnesses
//  answer the way the two roots (iOS, Mac) actually need them to.
//

import CoreGraphics
import UIKit
import XCTest
@testable import LunaGaze
@testable import LunaWriterEditor
import LunaDesignSystem

final class MacSeamTests: XCTestCase {

    // MARK: - GazeDeviceClass / GazeOrientation bridging

    func testDeviceClassBridgesThePadIdiomAndTreatsEverythingElseAsPhone() {
        XCTAssertEqual(GazeDeviceClass(.pad), .pad)
        XCTAssertEqual(GazeDeviceClass(.phone), .phone)
        XCTAssertEqual(GazeDeviceClass(.tv), .phone)
        XCTAssertEqual(GazeDeviceClass(.carPlay), .phone)
    }

    func testOrientationBridgesEveryUIInterfaceOrientationCaseAndDefaultsUnknownToPortrait() {
        XCTAssertEqual(GazeOrientation(.portrait), .portrait)
        XCTAssertEqual(GazeOrientation(.portraitUpsideDown), .portraitUpsideDown)
        XCTAssertEqual(GazeOrientation(.landscapeLeft), .landscapeLeft)
        XCTAssertEqual(GazeOrientation(.landscapeRight), .landscapeRight)
        XCTAssertEqual(GazeOrientation(.unknown), .portrait)
    }

    // MARK: - GazeScreenProjection / VisualAngle: the two overloads must agree

    func testPointsPerMetreAgreesBetweenTheIdiomAndDeviceClassOverloads() {
        XCTAssertEqual(
            GazeScreenProjection.pointsPerMetre(idiom: .pad),
            GazeScreenProjection.pointsPerMetre(deviceClass: .pad))
        XCTAssertEqual(
            GazeScreenProjection.pointsPerMetre(idiom: .phone),
            GazeScreenProjection.pointsPerMetre(deviceClass: .phone))
    }

    func testDeviceAwarePointsPerMetreAgreesBetweenTheIdiomAndDeviceClassOverloads() {
        let size = CGSize(width: 393, height: 852)
        XCTAssertEqual(
            GazeScreenProjection.pointsPerMetre(idiom: .phone, nativeScale: 3, portraitPointSize: size),
            GazeScreenProjection.pointsPerMetre(deviceClass: .phone, nativeScale: 3, portraitPointSize: size))
    }

    func testVisualAnglePointsPerDegreeAgreesBetweenTheIdiomAndDeviceClassOverloads() {
        XCTAssertEqual(
            VisualAngle.pointsPerDegree(idiom: .pad),
            VisualAngle.pointsPerDegree(deviceClass: .pad))
    }

    func testOrientedScreenPointAgreesBetweenTheOrientationAndInterfaceOrientationOverloads() {
        let point = CGPoint(x: 40, y: 120)
        let size = CGSize(width: 393, height: 852)
        XCTAssertEqual(
            GazeScreenProjection.orientedScreenPoint(
                fromPortraitPoint: point, portraitSize: size, orientation: GazeOrientation.landscapeLeft),
            GazeScreenProjection.orientedScreenPoint(
                fromPortraitPoint: point, portraitSize: size,
                orientation: UIInterfaceOrientation.landscapeLeft))
    }

    func testOrientedSizeAgreesBetweenTheOrientationAndInterfaceOrientationOverloads() {
        let size = CGSize(width: 393, height: 852)
        XCTAssertEqual(
            GazeScreenProjection.orientedSize(portraitSize: size, orientation: GazeOrientation.landscapeRight),
            GazeScreenProjection.orientedSize(
                portraitSize: size, orientation: UIInterfaceOrientation.landscapeRight))
    }

    // MARK: - GazeCalibrationStore: a value saved through one overload reads through the other

    func testACalibrationSavedThroughThePureOrientationReadsBackThroughTheUIKitBridge() throws {
        let suite = "MacSeamTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = GazeCalibrationStore(defaults: defaults)

        var calibration = GazeAffineCalibration.identity(
            viewSize: CGSize(width: 393, height: 852), pointsPerDegree: 44.8)
        calibration.nudge(toward: CGVector(dx: 12, dy: -8), gain: 1)
        store.save(calibration, for: GazeOrientation.landscapeLeft)

        let readBackThroughTheBridge = store.calibration(for: UIInterfaceOrientation.landscapeLeft)
        XCTAssertEqual(readBackThroughTheBridge?.offset.dx, calibration.offset.dx)
        XCTAssertEqual(readBackThroughTheBridge?.offset.dy, calibration.offset.dy)
    }

    // MARK: - GazeTrackerMaking

    func testARFaceGazeTrackerMakerProducesATracker() {
        let maker: GazeTrackerMaking = ARFaceGazeTrackerMaker()
        XCTAssertNotNil(maker.makeGazeTracker())
    }

    // MARK: - AccessoryBarPolicy

    func testDefaultPolicyHidesTheBarOnAWideColumnWithAHardwareKeyboard() {
        let policy = DefaultAccessoryBarPolicy()
        XCTAssertFalse(policy.shouldShowAccessoryBar(
            hasHardwareKeyboard: true, containerWidth: LunaLayout.wideThreshold))
    }

    func testDefaultPolicyKeepsTheBarOnAPhoneWidthColumnEvenWithAHardwareKeyboard() {
        let policy = DefaultAccessoryBarPolicy()
        XCTAssertTrue(policy.shouldShowAccessoryBar(
            hasHardwareKeyboard: true, containerWidth: LunaLayout.wideThreshold - 1))
    }

    func testDefaultPolicyKeepsTheBarWithNoHardwareKeyboardRegardlessOfWidth() {
        let policy = DefaultAccessoryBarPolicy()
        XCTAssertTrue(policy.shouldShowAccessoryBar(
            hasHardwareKeyboard: false, containerWidth: LunaLayout.wideThreshold + 400))
    }

    func testMacPolicyAlwaysHidesTheBar() {
        let policy = MacAccessoryBarPolicy()
        XCTAssertFalse(policy.shouldShowAccessoryBar(hasHardwareKeyboard: false, containerWidth: 1200))
        XCTAssertFalse(policy.shouldShowAccessoryBar(hasHardwareKeyboard: true, containerWidth: 300))
    }

    // MARK: - KeyboardMetricsProviding

    func testNoKeyboardMetricsReportsNoKeyboardEver() {
        let metrics = NoKeyboardMetrics()
        let view = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 700))
        XCTAssertFalse(metrics.isVisible)
        XCTAssertEqual(metrics.keyboardOverlap(in: view), 0)
    }
}
