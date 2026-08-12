//
//  LaunchScreenGeometryTests.swift
//  LunaTests
//
//  The launch storyboard has no code in it, so this is the only thing standing
//  between its constraints and a card that is the wrong size on every device but
//  one.
//

import LunaDesignSystem
import UIKit
import XCTest
@testable import Luna

/// `LunaLaunchScreen.storyboard` reproduces `CardDeckGeometry` in Interface
/// Builder constants, because a launch screen runs none of our code. This loads
/// the real storyboard out of the built app bundle, lays it out at six screen
/// sizes, and checks the card and corona frames against the Swift answer.
///
/// Before this existed the storyboard was one 402x874 raster pinned to all four
/// edges with `scaleToFill`: correct on the recorder's phone, a non-uniform
/// stretch on every other iPhone, and a badly wrong card on iPad.
@MainActor
final class LaunchScreenGeometryTests: XCTestCase {

    private static let screens: [(String, CGSize)] = [
        ("iPhone 16 Pro", CGSize(width: 402, height: 874)),
        ("iPhone 16 Pro Max", CGSize(width: 440, height: 956)),
        ("iPhone SE", CGSize(width: 375, height: 667)),
        ("iPad mini portrait", CGSize(width: 744, height: 1_133)),
        ("iPad Pro 13 portrait", CGSize(width: 1_032, height: 1_376)),
        ("iPad Pro 13 landscape", CGSize(width: 1_376, height: 1_032)),
    ]

    func testTheLaunchScreenDrawsTheCardExactlyWhereTheDeckWill() throws {
        for (name, size) in Self.screens {
            let launch = try Self.layOutLaunchScreen(size: size)
            let expected = CardDeckGeometry.cardFrame(
                inScreenSize: launch.root.bounds.size,
                safeAreaInsets: launch.root.safeAreaInsets)

            XCTAssertEqual(launch.card.frame.minX, expected.minX, accuracy: 0.5, "\(name) x")
            XCTAssertEqual(launch.card.frame.minY, expected.minY, accuracy: 0.5, "\(name) y")
            XCTAssertEqual(launch.card.frame.width, expected.width, accuracy: 0.5, "\(name) width")
            XCTAssertEqual(
                launch.card.frame.height, expected.height, accuracy: 0.5, "\(name) height")
        }
    }

    /// The corona artwork's frame is the card grown by its proportional reach —
    /// the rule `AppLaunchTransition.makeCoronaCardView` applies in code and the
    /// storyboard applies with a width multiplier and a fixed aspect. Both have
    /// to land on the same rectangle or the crossfade from the launch screen to
    /// the app's first frame slides the glow.
    func testTheLaunchScreenCoronaMatchesTheArtworksOwnFrame() throws {
        for (name, size) in Self.screens {
            let launch = try Self.layOutLaunchScreen(size: size)
            let expected = AppLaunchGeometry.coronaFrame(forCardFrame: launch.card.frame)

            XCTAssertEqual(launch.corona.frame.minX, expected.minX, accuracy: 0.5, "\(name) x")
            XCTAssertEqual(launch.corona.frame.minY, expected.minY, accuracy: 0.5, "\(name) y")
            XCTAssertEqual(
                launch.corona.frame.width, expected.width, accuracy: 0.5, "\(name) width")
            XCTAssertEqual(
                launch.corona.frame.height, expected.height, accuracy: 1, "\(name) height")
        }
    }

    /// Both rasters ship, loose in the bundle (the launch screen needs them
    /// before the app has started) and single-scale, so one file downscales to
    /// every device instead of a 2x variant being upscaled on the largest iPad.
    func testBothLaunchRastersShipAsSingleScaleImages() throws {
        for name in [
            AppLaunchTransition.coronaCardArtworkName,
            AppLaunchTransition.starfieldArtworkName,
        ] {
            let image = try XCTUnwrap(UIImage(named: name), "\(name) is missing from the bundle")
            XCTAssertEqual(
                image.scale, 1,
                "\(name) must be single-scale: its point size IS its pixel size")
            XCTAssertGreaterThan(image.size.width, 600, "\(name) looks too small to scale up from")
        }
    }

    /// The corona raster's aspect is fixed by the card's aspect and the reach
    /// fraction, and the storyboard hard-codes it as a constraint multiplier. If
    /// the recorded canvas ever stops matching, the artwork gets squashed.
    func testTheCoronaRasterMatchesTheAspectTheStoryboardConstrains() throws {
        let image = try XCTUnwrap(UIImage(named: AppLaunchTransition.coronaCardArtworkName))
        XCTAssertEqual(
            image.size.width / image.size.height,
            AppLaunchGeometry.coronaAspectRatio,
            accuracy: 0.002)
    }

    // MARK: -

    private struct LaunchScreen {
        let root: UIView
        let card: UIView
        let corona: UIImageView
        let window: UIWindow
    }

    /// Loads the real launch storyboard and lays it out at `size`.
    ///
    /// The views are identified by z-order rather than by name: a launch
    /// storyboard's subview order IS its paint order (sky, then the card area
    /// and card layout anchors, then the corona artwork on top), so pinning the
    /// order here is worth having on its own.
    private static func layOutLaunchScreen(size: CGSize) throws -> LaunchScreen {
        let storyboard = UIStoryboard(name: "LunaLaunchScreen", bundle: .main)
        let controller = storyboard.instantiateInitialViewController()
        let launch = try XCTUnwrap(controller)
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.rootViewController = launch
        window.isHidden = false
        window.layoutIfNeeded()
        launch.view.layoutIfNeeded()

        let subviews = launch.view.subviews
        XCTAssertEqual(subviews.count, 4, "sky, card area, card, corona")
        let corona = try XCTUnwrap(subviews.last as? UIImageView, "corona is the top layer")
        XCTAssertTrue(subviews.first is UIImageView, "the sky is the bottom layer")
        return LaunchScreen(
            root: launch.view, card: subviews[2], corona: corona, window: window)
    }
}
