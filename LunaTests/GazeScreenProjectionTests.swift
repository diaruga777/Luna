//
//  GazeScreenProjectionTests.swift
//  LunaTests
//
//  The ARKit-free half of gaze estimation: a ray in camera space onto the plane
//  of the display. Face tracking never runs on the simulator, so this geometry
//  is the only part of the tracker that can be checked here — which is exactly
//  why it lives apart from the ARKit session.
//

import LunaReaderUI
import simd
import UIKit
import XCTest
@testable import LunaGaze

final class GazeScreenProjectionTests: XCTestCase {

    private let screenSize = CGSize(width: 393, height: 852)
    private lazy var pointsPerMetre = GazeScreenProjection.pointsPerMetre(idiom: .phone)
    private let cameraHeight = GazeScreenProjection.cameraHeightAboveScreen

    /// A gaze ray that lands on `target` (in screen points), sampled partway
    /// along so the projection has to extrapolate rather than read the answer.
    private func ray(
        to target: CGPoint, from eye: SIMD3<Float>
    ) -> (eye: SIMD3<Float>, lookAt: SIMD3<Float>) {
        let hit = SIMD3<Float>(
            Float((screenSize.width / 2 - target.x) / pointsPerMetre),
            Float(-(target.y / pointsPerMetre) - cameraHeight),
            0)
        return (eye, eye + (hit - eye) * 0.5)
    }

    private var readingEye: SIMD3<Float> { SIMD3(0, -0.05, -0.4) }

    func testProjectsOntoTheScreenPointTheRayActuallyHits() throws {
        for target in [CGPoint(x: 196, y: 426), CGPoint(x: 60, y: 120), CGPoint(x: 350, y: 780)] {
            let (eye, lookAt) = ray(to: target, from: readingEye)
            let point = try XCTUnwrap(GazeScreenProjection.screenPoint(
                eyeOrigin: eye, lookAt: lookAt,
                screenSize: screenSize, pointsPerMetre: pointsPerMetre))
            XCTAssertEqual(point.x, target.x, accuracy: 0.5)
            XCTAssertEqual(point.y, target.y, accuracy: 0.5)
        }
    }

    func testCameraSpaceXIsMirroredOntoTheScreen() throws {
        // ARKit's camera frame is right-handed with −z pointing at the user, so
        // +x runs toward the user's view of the screen's LEFT.
        let eye = readingEye
        let lookAt = eye + SIMD3<Float>(0.02, 0, 0.2)
        let point = try XCTUnwrap(GazeScreenProjection.screenPoint(
            eyeOrigin: eye, lookAt: lookAt,
            screenSize: screenSize, pointsPerMetre: pointsPerMetre))
        XCTAssertLessThan(point.x, screenSize.width / 2)
    }

    func testAGazeAimedAwayFromTheDisplayHasNoIntersection() {
        let eye = readingEye
        // Straight up, and straight back out past the user: neither meets z = 0
        // in front of the eyes.
        XCTAssertNil(GazeScreenProjection.screenPoint(
            eyeOrigin: eye, lookAt: eye + SIMD3<Float>(0, 0.3, 0),
            screenSize: screenSize, pointsPerMetre: pointsPerMetre))
        XCTAssertNil(GazeScreenProjection.screenPoint(
            eyeOrigin: eye, lookAt: eye + SIMD3<Float>(0, 0, -0.3),
            screenSize: screenSize, pointsPerMetre: pointsPerMetre))
    }

    func testOnScreenTestToleratesEdgeError() {
        XCTAssertTrue(GazeScreenProjection.isOnScreen(
            CGPoint(x: 196, y: 426), screenSize: screenSize))
        XCTAssertTrue(
            GazeScreenProjection.isOnScreen(CGPoint(x: 196, y: 880), screenSize: screenSize),
            "a gaze at the very bottom of the display must not read as looking past the phone")
        XCTAssertFalse(GazeScreenProjection.isOnScreen(
            CGPoint(x: 196, y: 1400), screenSize: screenSize))
        XCTAssertFalse(GazeScreenProjection.isOnScreen(
            CGPoint(x: -300, y: 426), screenSize: screenSize))
    }

    // MARK: - Orientation

    func testPortraitPointsPassStraightThrough() {
        let point = CGPoint(x: 100, y: 700)
        XCTAssertEqual(
            GazeScreenProjection.orientedScreenPoint(
                fromPortraitPoint: point, portraitSize: screenSize, orientation: GazeOrientation.portrait),
            point)
    }

    func testRotationMapsTheDeviceCornersWhereTheyPhysicallyAre() {
        let topLeft = CGPoint.zero
        // Home-button edge right ⇒ the device's top edge lies along the screen's
        // left, and its left edge along the screen's bottom.
        XCTAssertEqual(
            GazeScreenProjection.orientedScreenPoint(
                fromPortraitPoint: topLeft, portraitSize: screenSize,
                orientation: GazeOrientation.landscapeLeft),
            CGPoint(x: 0, y: screenSize.width))
        XCTAssertEqual(
            GazeScreenProjection.orientedScreenPoint(
                fromPortraitPoint: topLeft, portraitSize: screenSize,
                orientation: GazeOrientation.landscapeRight),
            CGPoint(x: screenSize.height, y: 0))
        XCTAssertEqual(
            GazeScreenProjection.orientedScreenPoint(
                fromPortraitPoint: topLeft, portraitSize: screenSize,
                orientation: GazeOrientation.portraitUpsideDown),
            CGPoint(x: screenSize.width, y: screenSize.height))
    }

    func testRotationIsRigid() {
        // Two points a known distance apart stay that far apart in every
        // orientation — a rotation, not a shear or a flip.
        let a = CGPoint(x: 80, y: 200)
        let b = CGPoint(x: 260, y: 640)
        let expected = hypot(b.x - a.x, b.y - a.y)
        for orientation: UIInterfaceOrientation in
            [.portrait, .portraitUpsideDown, .landscapeLeft, .landscapeRight] {
            let ra = GazeScreenProjection.orientedScreenPoint(
                fromPortraitPoint: a, portraitSize: screenSize, orientation: orientation)
            let rb = GazeScreenProjection.orientedScreenPoint(
                fromPortraitPoint: b, portraitSize: screenSize, orientation: orientation)
            XCTAssertEqual(hypot(rb.x - ra.x, rb.y - ra.y), expected, accuracy: 0.001)
        }
    }

    func testPointDensityFollowsTheIdiom() {
        XCTAssertLessThan(
            GazeScreenProjection.pointsPerMetre(idiom: .pad),
            GazeScreenProjection.pointsPerMetre(idiom: .phone),
            "iPad points are physically larger, so a metre spans fewer of them")
    }

    // MARK: - Device-aware density

    func testAThreeXPhoneIsDenserThanATwoXPhone() {
        let proClass = GazeScreenProjection.pointsPerMetre(
            idiom: .phone, nativeScale: 3, portraitPointSize: CGSize(width: 393, height: 852))
        let standard = GazeScreenProjection.pointsPerMetre(
            idiom: .phone, nativeScale: 2, portraitPointSize: CGSize(width: 390, height: 844))
        XCTAssertLessThan(
            proClass, standard, "a 458ppi 3x panel packs more points per inch than a 326ppi 2x one")
    }

    func testAnIPadMiniIsDenserThanALargerIPadAtTheSameScale() {
        let mini = GazeScreenProjection.pointsPerMetre(
            idiom: .pad, nativeScale: 2, portraitPointSize: CGSize(width: 744, height: 1133))
        let larger = GazeScreenProjection.pointsPerMetre(
            idiom: .pad, nativeScale: 2, portraitPointSize: CGSize(width: 834, height: 1194))
        XCTAssertGreaterThan(
            mini, larger, "the mini shares the iPhone's denser panel, not a larger iPad's")
    }

    func testAnUnrecognisedShapeFallsBackToTheIdiomConstant() {
        XCTAssertEqual(
            GazeScreenProjection.pointsPerMetre(
                idiom: .phone, nativeScale: 1, portraitPointSize: CGSize(width: 320, height: 480)),
            GazeScreenProjection.pointsPerMetre(idiom: .phone))
    }

    // MARK: - Camera position and ray-travel guard

    func testACameraPositionParameterShiftsTheProjectedPoint() throws {
        let topCentre = try XCTUnwrap(GazeScreenProjection.screenPoint(
            eyeOrigin: readingEye, lookAt: readingEye + SIMD3<Float>(0, 0, 0.2),
            screenSize: screenSize, pointsPerMetre: pointsPerMetre))
        let offCentre = try XCTUnwrap(GazeScreenProjection.screenPoint(
            eyeOrigin: readingEye, lookAt: readingEye + SIMD3<Float>(0, 0, 0.2),
            screenSize: screenSize, pointsPerMetre: pointsPerMetre,
            cameraPosition: CGPoint(x: 0.9, y: 0.1)))
        XCTAssertNotEqual(topCentre, offCentre)
        XCTAssertEqual(offCentre.x - topCentre.x, screenSize.width * 0.4, accuracy: 0.01)
        XCTAssertEqual(offCentre.y - topCentre.y, screenSize.height * 0.1, accuracy: 0.01)
    }

    func testARayThatTravelsPastTheGuardDistanceHasNoIntersection() {
        // Nearly parallel to the display plane: the algebra finds a hit, but
        // only after travelling several metres to reach it.
        let eye = SIMD3<Float>(0, -0.05, -0.001)
        let lookAt = eye + SIMD3<Float>(0.5, 0, 0.0002)
        XCTAssertNil(GazeScreenProjection.screenPoint(
            eyeOrigin: eye, lookAt: lookAt, screenSize: screenSize, pointsPerMetre: pointsPerMetre))
    }
}
