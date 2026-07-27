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
@MainActor
final class UnsupportedSaveCardTests: XCTestCase {

    // MARK: - Copy

    func testHeaderNamesTheRunningApp() {
        XCTAssertEqual(
            UnsupportedSaveCopy.header(current: .reader),
            "Unable to save this link in Luna Reader")
    }

    func testUpsellNamesTheOwningApp() {
        XCTAssertEqual(
            UnsupportedSaveCopy.upsell(owner: .downloader),
            "You can get the Luna Downloader app for this type of link")
    }

    func testSentenceFlattensBothLinesForSurfacesThatCanOnlySpeak() {
        let sentence = UnsupportedSaveCopy.sentence(owner: .priceTracker, current: .reader)
        XCTAssertEqual(
            sentence,
            "Unable to save this link in Luna Reader. "
                + "You can get the Luna Price Tracker app for this type of link.")
    }

    func testSentenceWithNoSiblingOwnerIsHeaderOnly() {
        XCTAssertEqual(
            UnsupportedSaveCopy.sentence(owner: nil, current: .downloader),
            "Unable to save this link in Luna Downloader.")
    }

    /// The intent dialog is the flattened card, not a second apology.
    func testSurfaceSupportMessageIsTheSameCopy() {
        XCTAssertEqual(
            SurfaceSupport.unsupportedMessage(owner: .downloader, current: .reader),
            UnsupportedSaveCopy.sentence(owner: .downloader, current: .reader))
    }

    // MARK: - Sibling icons

    /// The whole reason the icons live in LunaDesignSystem's resource bundle:
    /// every app must be able to draw every OTHER app's icon.
    func testEveryAppIconResolvesFromTheSharedBundle() {
        for app in LunaApp.allCases {
            XCTAssertNotNil(
                LunaAppIconImage.image(for: app),
                "\(app.displayName)'s icon must ship with LunaDesignSystem")
        }
    }

    func testAppIconsAreDistinctArtwork() {
        let artwork = LunaApp.allCases.compactMap { LunaAppIconImage.image(for: $0)?.pngData() }
        XCTAssertEqual(artwork.count, LunaApp.allCases.count)
        XCTAssertEqual(Set(artwork).count, artwork.count, "each app must show its OWN icon")
    }

    // MARK: - The card

    func testCardShowsHeaderIconAndUpsellForASiblingOwner() {
        let card = UnsupportedSaveCardViewController(owner: .downloader, currentApp: .reader)
        card.view.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        card.view.layoutIfNeeded()

        let text = Self.labelTexts(in: card.view)
        XCTAssertTrue(text.contains(UnsupportedSaveCopy.header(current: .reader)))
        XCTAssertTrue(text.contains(UnsupportedSaveCopy.upsell(owner: .downloader)))
        XCTAssertEqual(Self.count(LunaAppIconView.self, in: card.view), 1,
                       "the owning app's icon is the card's one image")
    }

    func testCardWithNoSiblingOwnerShowsTheHeaderAlone() {
        let card = UnsupportedSaveCardViewController(owner: nil, currentApp: .priceTracker)
        card.view.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        card.view.layoutIfNeeded()

        XCTAssertTrue(
            Self.labelTexts(in: card.view)
                .contains(UnsupportedSaveCopy.header(current: .priceTracker)))
        XCTAssertEqual(Self.count(LunaAppIconView.self, in: card.view), 0)
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
        var doneCount = 0
        card.onDone = { doneCount += 1 }

        guard let button = Self.first(UIButton.self, in: card.view) else {
            return XCTFail("no Done button")
        }
        button.sendActions(for: .touchUpInside)
        XCTAssertEqual(doneCount, 1)
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
