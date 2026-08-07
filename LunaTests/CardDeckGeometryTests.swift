//
//  CardDeckGeometryTests.swift
//  LunaTests
//
//  The splash and the deck draw the same rectangle, or the launch crossfade
//  visibly moves the card.
//

import LunaDesignSystem
import UIKit
import XCTest
@testable import Luna

/// `CardDeckGeometry` claims to compute, from a screen size alone, the frame the
/// live carousel will put its centered card at. That claim is the entire reason
/// the launch splash can be drawn before the app has a root — so it is pinned
/// here against a real carousel in a real window, at the safe areas of the
/// devices Luna ships to.
///
/// It replaces three hand-tuned constants (`rootCardHorizontalInset`,
/// `rootCardBottomClearanceFromSafeArea`, `referenceSafeAreaBottomInset`) that
/// were measured on one iPhone, plus a separate "launch-safe approximation" used
/// on every other device — neither of which any test compared against a deck.
@MainActor
final class CardDeckGeometryTests: XCTestCase {

    /// (screen, EXTRA safe-area inset) covering phone and iPad shapes, both
    /// orientations, and a notch-less phone. The simulator's own device insets
    /// are added to these by UIKit, so the assertion reads the resulting insets
    /// back rather than assuming them — the claim under test is that the two
    /// answers agree at whatever safe area the deck is handed.
    private static let shapes: [(String, CGSize, UIEdgeInsets)] = [
        ("iPhone 16 Pro", CGSize(width: 402, height: 874),
         UIEdgeInsets(top: 8, left: 0, bottom: 34, right: 0)),
        ("iPhone 16 Pro Max", CGSize(width: 440, height: 956),
         UIEdgeInsets(top: 8, left: 0, bottom: 34, right: 0)),
        ("notch-less phone", CGSize(width: 375, height: 667),
         .zero),
        ("iPad mini portrait", CGSize(width: 744, height: 1_133),
         UIEdgeInsets(top: 0, left: 0, bottom: 20, right: 0)),
        ("iPad Pro 13 portrait", CGSize(width: 1_032, height: 1_376),
         UIEdgeInsets(top: 0, left: 0, bottom: 20, right: 0)),
        ("iPad Pro 13 landscape", CGSize(width: 1_376, height: 1_032),
         UIEdgeInsets(top: 0, left: 0, bottom: 20, right: 0)),
    ]

    func testTheLiveDeckRestsItsCardExactlyWhereTheSplashDrawsIt() throws {
        for (name, screen, extraInsets) in Self.shapes {
            let host = SafeAreaHost(insets: extraInsets)
            let carousel = CardCarouselViewController()
            let source = OneCardDataSource()
            carousel.dataSource = source
            host.install(carousel)

            let window = UIWindow(frame: CGRect(origin: .zero, size: screen))
            window.rootViewController = host
            window.isHidden = false
            window.layoutIfNeeded()
            carousel.reloadData(centeringAt: 0)
            // What every deck's host does, once, in `applyCarouselTopInset`.
            carousel.setTopInset(
                host.view.safeAreaInsets.top + CardCarouselHostViewController.carouselTopClearance)
            window.layoutIfNeeded()

            let live = try XCTUnwrap(
                carousel.restingCenteredCardFrame(in: host.view), name)
            let predicted = CardDeckGeometry.cardFrame(
                inScreenSize: host.view.bounds.size,
                safeAreaInsets: host.view.safeAreaInsets)

            XCTAssertEqual(live.minX, predicted.minX, accuracy: 0.5, "\(name) x")
            XCTAssertEqual(live.minY, predicted.minY, accuracy: 0.5, "\(name) y")
            XCTAssertEqual(live.width, predicted.width, accuracy: 0.5, "\(name) width")
            XCTAssertEqual(live.height, predicted.height, accuracy: 0.5, "\(name) height")
            window.isHidden = true
        }
    }

    /// The host's clearance IS the geometry's, not a number that happens to
    /// match it. Every deck reserves it — including the three with no chrome row
    /// to put there — because the card frame must not depend on which app opened.
    func testEveryDeckReservesTheOneTopClearance() {
        XCTAssertEqual(
            CardCarouselHostViewController.carouselTopClearance,
            CardDeckGeometry.topClearance)
    }

    /// The bottom chrome the geometry subtracts is the strip the carousel
    /// actually installs, so a change to the strip's height cannot silently
    /// leave the splash drawing the old card.
    func testBottomChromeIsTheScrubStripPlusItsGap() {
        XCTAssertEqual(
            CardDeckGeometry.bottomChromeHeight,
            CarouselScrubberView.preferredHeight + CardDeckGeometry.scrubberBottomGap)
    }

    /// Every shipping size resolves to an exact 9:16 card wholly inside the
    /// screen — the property the launch storyboard's constraints reproduce.
    func testEveryShippingSizeGivesAnExact9By16CardInsideTheScreen() {
        for (name, screen, insets) in Self.shippingDevices {
            let frame = CardDeckGeometry.cardFrame(inScreenSize: screen, safeAreaInsets: insets)
            XCTAssertEqual(
                frame.width / frame.height,
                CardCarouselMetrics.cardAspectRatio,
                accuracy: 0.0001, name)
            XCTAssertGreaterThanOrEqual(frame.minY, insets.top, name)
            XCTAssertLessThanOrEqual(frame.maxY, screen.height - insets.bottom, name)
            XCTAssertGreaterThan(frame.minX, 0, name)
            XCTAssertEqual(frame.midX, screen.width / 2, accuracy: 0.01, name)
        }
    }
}

extension CardDeckGeometryTests {
    /// The real safe areas Luna ships to, for the pure-arithmetic assertions
    /// (no window involved, so nothing adds the simulator's own insets).
    fileprivate static let shippingDevices: [(String, CGSize, UIEdgeInsets)] = [
        ("iPhone 16 Pro", CGSize(width: 402, height: 874),
         UIEdgeInsets(top: 62, left: 0, bottom: 34, right: 0)),
        ("iPhone 16 Pro Max", CGSize(width: 440, height: 956),
         UIEdgeInsets(top: 62, left: 0, bottom: 34, right: 0)),
        ("iPhone SE", CGSize(width: 375, height: 667),
         UIEdgeInsets(top: 20, left: 0, bottom: 0, right: 0)),
        ("iPad mini portrait", CGSize(width: 744, height: 1_133),
         UIEdgeInsets(top: 24, left: 0, bottom: 20, right: 0)),
        ("iPad Pro 13 portrait", CGSize(width: 1_032, height: 1_376),
         UIEdgeInsets(top: 24, left: 0, bottom: 20, right: 0)),
        ("iPad Pro 13 landscape", CGSize(width: 1_376, height: 1_032),
         UIEdgeInsets(top: 24, left: 0, bottom: 20, right: 0)),
    ]
}

/// A container that hands its child a chosen safe area, so one process can lay
/// the deck out at an iPhone's insets and an iPad's.
@MainActor
private final class SafeAreaHost: UIViewController {
    init(insets: UIEdgeInsets) {
        super.init(nibName: nil, bundle: nil)
        additionalSafeAreaInsets = insets
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func install(_ child: UIViewController) {
        addChild(child)
        loadViewIfNeeded()
        child.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(child.view)
        child.didMove(toParent: self)
        NSLayoutConstraint.activate([
            child.view.topAnchor.constraint(equalTo: view.topAnchor),
            child.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            child.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            child.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }
}

@MainActor
private final class OneCardDataSource: @preconcurrency CardCarouselDataSource {
    func numberOfCards(in carousel: CardCarouselViewController) -> Int { 1 }

    func carousel(
        _ carousel: CardCarouselViewController,
        contentControllerForCardAt index: Int
    ) -> CardContentViewController { CardContentViewController() }

    func carousel(
        _ carousel: CardCarouselViewController,
        loadThumbnailForCardAt index: Int,
        completion: @escaping (UIImage?) -> Void
    ) { completion(nil) }
}
