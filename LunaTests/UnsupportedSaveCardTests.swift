//
//  UnsupportedSaveCardTests.swift
//  LunaTests
//

import LunaDesignSystem
import LunaIngest
import LunaModels
import UIKit
import XCTest

/// The ONE drop screen (`UnsupportedSaveCardViewController`) and the ONE copy
/// source behind it (`UnsupportedSaveCopy`). The point of both is that the app,
/// the share extension, and the action extension say the same thing — so these
/// pin the wording, the sibling-app icon (which must resolve in EVERY app, not
/// just the one whose appiconset it is), and the header-only fallback.
/// Stands in for whichever surface put the drop card on screen.
@MainActor
final class RecordingUnsupportedSaveCardHost: UnsupportedSaveCardDelegate {
    private(set) var finishedCards: [UnsupportedSaveCardViewController] = []

    func unsupportedSaveCardDidFinish(_ card: UnsupportedSaveCardViewController) {
        finishedCards.append(card)
    }
}

@MainActor
final class UnsupportedSaveCardTests: XCTestCase {

    // MARK: - Copy

    /// The one surface that can't draw reads the card aloud: both lines
    /// flattened, and the header alone when no sibling owns the kind. (The
    /// wording itself is `UnsupportedSaveCopy`'s; what matters here is that the
    /// spoken form is BUILT from it rather than apologising a second time.)
    func testSpokenMessageIsTheFlattenedCard() {
        XCTAssertEqual(
            UnsupportedSaveCopy.sentence(owner: .priceTracker, current: .reader),
            UnsupportedSaveCopy.header(current: .reader) + ". "
                + UnsupportedSaveCopy.upsell(owner: .priceTracker) + ".")
        XCTAssertEqual(
            UnsupportedSaveCopy.sentence(owner: nil, current: .downloader),
            UnsupportedSaveCopy.header(current: .downloader) + ".",
            "no sibling owner ⇒ no upsell clause")
        XCTAssertEqual(
            SurfaceSupport.unsupportedMessage(owner: .downloader, current: .reader),
            UnsupportedSaveCopy.sentence(owner: .downloader, current: .reader),
            "the intent dialog is the flattened card, not a second apology")
    }

    // MARK: - Sibling icons

    /// The whole reason the icons live in LunaDesignSystem's resource bundle:
    /// every app must be able to draw every OTHER app's icon, and each must be
    /// its OWN artwork.
    func testEveryAppIconResolvesFromTheSharedBundleAsDistinctArtwork() {
        for app in LunaApp.allCases {
            XCTAssertNotNil(
                LunaAppIconImage.image(for: app),
                "\(app.displayName)'s icon must ship with LunaDesignSystem")
        }
        let artwork = LunaApp.allCases.compactMap { LunaAppIconImage.image(for: $0)?.pngData() }
        XCTAssertEqual(artwork.count, LunaApp.allCases.count)
        XCTAssertEqual(Set(artwork).count, artwork.count, "each app must show its OWN icon")
    }

    // MARK: - The card

    /// The card's two statements: the header for EVERY drop, and — only when a
    /// sibling owns the kind — that app's real icon and the upsell.
    func testCardShowsTheHeaderAlwaysAndTheOwnerOnlyWhenThereIsOne() {
        let owned = UnsupportedSaveCardViewController(owner: .downloader, currentApp: .reader)
        owned.view.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        owned.view.layoutIfNeeded()

        let text = Self.labelTexts(in: owned.view)
        XCTAssertTrue(text.contains(UnsupportedSaveCopy.header(current: .reader)))
        XCTAssertTrue(text.contains(UnsupportedSaveCopy.upsell(owner: .downloader)))
        XCTAssertEqual(Self.count(LunaAppIconView.self, in: owned.view), 1,
                       "the owning app's icon is the card's one image")

        let ownerless = UnsupportedSaveCardViewController(owner: nil, currentApp: .priceTracker)
        ownerless.view.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        ownerless.view.layoutIfNeeded()

        XCTAssertTrue(
            Self.labelTexts(in: ownerless.view)
                .contains(UnsupportedSaveCopy.header(current: .priceTracker)))
        XCTAssertEqual(Self.count(LunaAppIconView.self, in: ownerless.view), 0)
    }

    /// The deck's chrome, not a dialog's: starry sky behind a 9:16 card at the
    /// carousel's own geometry.
    func testCardIsDressedAsTheRootCarousel() {
        let card = UnsupportedSaveCardViewController(owner: .reader, currentApp: .downloader)
        card.view.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        card.view.layoutIfNeeded()

        XCTAssertEqual(Self.count(StarfieldView.self, in: card.view), 1,
                       "the same starfield the decks install")
        guard let surface = Self.first(CardSurfaceView.self, in: card.view) else {
            return XCTFail("no card surface")
        }
        let aspect = surface.frame.width / surface.frame.height
        XCTAssertEqual(aspect, CardCarouselMetrics.cardAspectRatio, accuracy: 0.01)
        XCTAssertGreaterThan(surface.frame.width, 0)
    }

    /// Nothing was saved, so the card's only action is dismissal.
    func testDoneRunsTheHostsCompletion() {
        let card = UnsupportedSaveCardViewController(owner: .reader, currentApp: .downloader)
        card.view.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        card.view.layoutIfNeeded()
        let host = RecordingUnsupportedSaveCardHost()
        card.delegate = host

        guard let button = Self.first(UIButton.self, in: card.view) else {
            return XCTFail("no Done button")
        }
        button.sendActions(for: .touchUpInside)
        XCTAssertEqual(host.finishedCards, [card])
    }

    // MARK: - Appearance

    /// The whole point of the redesign is what it LOOKS like, so pin it. (The
    /// test host is the central Luna app, so these record the Luna palette; the
    /// per-app tint is `LunaSurfacePalette`'s own contract, covered there.)
    func testCardSnapshotWithSiblingOwner() {
        SnapshotTesting.assertSnapshot(
            of: UnsupportedSaveCardViewController(owner: .downloader, currentApp: .reader),
            named: "UnsupportedSaveCard-Owned")
    }

    func testCardSnapshotHeaderOnly() {
        SnapshotTesting.assertSnapshot(
            of: UnsupportedSaveCardViewController(owner: nil, currentApp: .priceTracker),
            named: "UnsupportedSaveCard-HeaderOnly")
    }

    // MARK: - Hierarchy helpers

    private static func labelTexts(in view: UIView) -> [String] {
        var found: [String] = []
        if let label = view as? UILabel, let text = label.text { found.append(text) }
        for subview in view.subviews { found += labelTexts(in: subview) }
        return found
    }

    private static func first<T: UIView>(_ type: T.Type, in view: UIView) -> T? {
        if let match = view as? T { return match }
        for subview in view.subviews {
            if let match = first(type, in: subview) { return match }
        }
        return nil
    }

    private static func count<T: UIView>(_ type: T.Type, in view: UIView) -> Int {
        (view is T ? 1 : 0) + view.subviews.reduce(0) { $0 + count(type, in: $1) }
    }
}
