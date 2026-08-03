//
//  WeeklyPromotionMenuTests.swift
//  LunaTests
//

import LunaModels
import LunaWeekly
import UIKit
import XCTest
@testable import Luna

@MainActor
final class WeeklyPromotionMenuTests: XCTestCase {

    func testANonKeyHolderIsOfferedTheProposeVerb() throws {
        let action = try XCTUnwrap(WeeklyPromotionMenu.action(
            for: readySave(), presenter: UIViewController(), isKeyHolder: false))
        XCTAssertEqual(action.title, "Propose Save of the Week")
    }

    func testAKeyHolderIsOfferedTheAppsOwnPromoteVerb() throws {
        let promote = try XCTUnwrap(WeeklyPromotionMenu.action(
            for: readySave(), presenter: UIViewController(),
            isKeyHolder: true, app: .reader))
        XCTAssertEqual(promote.title, "Promote to Read of the Week")

        let central = try XCTUnwrap(WeeklyPromotionMenu.action(
            for: readySave(), presenter: UIViewController(),
            isKeyHolder: true, app: .luna))
        XCTAssertEqual(central.title, "Promote to Save of the Week")
    }

    /// A failed save has nothing behind it to recommend, so neither verb
    /// appears — for a key-holder or anyone else.
    func testAFailedSaveIsNeverACandidate() {
        var failed = ReadingListItem(
            seed: "weekly-failed", urlString: "https://example.com/failed",
            title: nil, dateAdded: Date(), state: .failed)
        failed.platform = nil
        XCTAssertNil(WeeklyPromotionMenu.weeklyKind(for: failed))
        XCTAssertNil(WeeklyPromotionMenu.action(
            for: failed, presenter: UIViewController(), isKeyHolder: false))
        XCTAssertNil(WeeklyPromotionMenu.action(
            for: failed, presenter: UIViewController(), isKeyHolder: true))
    }

    func testTheItemsOwnKindDecidesTheWeeklyKind() {
        XCTAssertEqual(WeeklyPromotionMenu.weeklyKind(for: readySave()), .article)

        var media = readySave()
        media.platform = .youtube
        XCTAssertEqual(WeeklyPromotionMenu.weeklyKind(for: media), .media)

        var product = readySave()
        product.priceTracker = PriceTracker(
            productName: "A Thing", firstStoreURL: "https://shop.example/p",
            price: 9, currency: "USD", brand: nil, productID: nil)
        XCTAssertEqual(WeeklyPromotionMenu.weeklyKind(for: product), .product)
    }

    private func readySave() -> ReadingListItem {
        ReadingListItem(
            seed: "weekly-menu", urlString: "https://example.com/weekly-menu",
            title: "A Save", dateAdded: Date(), state: .ready, wordCount: 400)
    }
}
