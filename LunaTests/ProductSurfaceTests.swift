//
//  ProductSurfaceTests.swift
//  LunaTests
//
//  The one product surface: the title heuristic that decides what a card leads
//  with, and the parity that makes "the card" and "the extension editor" the
//  same sentence.
//

import LunaModels
import LunaPriceUI
import LunaStorage
import UIKit
import XCTest
@testable import Luna

final class ProductTitleSummaryTests: XCTestCase {

    /// The reported save, and the shape of every marketplace title: a product
    /// name, then the store, then the category path.
    func testAMarketplaceTitleIsCutBackToItsProductName() {
        let title = "Panasonic spare blade men's shaver 6-blade ES9600 : "
            + "Amazon.com.au: Health, Household & Personal Care"
        XCTAssertEqual(ProductTitleSummary.headline(for: title), "Panasonic spare blade")
        XCTAssertEqual(
            ProductTitleSummary.detail(for: title), title,
            "and nothing is thrown away — the rest is kept, smaller, underneath")
    }

    /// A model code names the product only until something else does. "Sony
    /// WH-1000XM5" is how that headphone is known; "Apple iPhone 15" is a
    /// version number bolted to a name that already stood up.
    func testAModelCodeIsKeptOnlyWhileItIsStillDoingTheNaming() {
        XCTAssertEqual(
            ProductTitleSummary.headline(for: "Sony WH-1000XM5 Wireless Noise Cancelling Headphones"),
            "Sony WH-1000XM5 Wireless")
        XCTAssertEqual(
            ProductTitleSummary.headline(for: "Apple iPhone 15 Pro Max 256GB Blue Titanium"),
            "Apple iPhone")
    }

    func testSeparatorsBracketsAndCommasEndTheName() {
        XCTAssertEqual(
            ProductTitleSummary.headline(for: "Dyson V15 Detect | Buy online at Dyson"),
            "Dyson V15 Detect")
        XCTAssertEqual(
            ProductTitleSummary.headline(for: "Weber Kettle (57cm, charcoal) - Barbecues Galore"),
            "Weber Kettle")
        XCTAssertEqual(
            ProductTitleSummary.headline(for: "Breville Barista Express, Stainless Steel"),
            "Breville Barista Express")
    }

    /// A name that is already short says itself once. The detail line exists to
    /// keep what the headline dropped, so when it dropped nothing there is no
    /// line.
    func testAShortNameDrawsNoDuplicateLineUnderItself() {
        XCTAssertEqual(ProductTitleSummary.headline(for: "The Only Kettle"), "The Only Kettle")
        XCTAssertNil(ProductTitleSummary.detail(for: "The Only Kettle"))
        XCTAssertNil(ProductTitleSummary.detail(for: "  The Only Kettle  "))
    }

    /// Three long words are worse than two: the headline sits beside a price on
    /// a 320pt card.
    func testThreeLongWordsFallBackToTwo() {
        XCTAssertEqual(
            ProductTitleSummary.headline(
                for: "Professional Refrigeration Thermometer with probe"),
            "Professional Refrigeration")
    }

    /// Nothing to work with is still an answer, not a crash.
    func testDegenerateTitles() {
        XCTAssertEqual(ProductTitleSummary.headline(for: ""), "")
        XCTAssertEqual(ProductTitleSummary.headline(for: "   "), "")
        XCTAssertEqual(ProductTitleSummary.headline(for: ": : :"), ": : :")
    }
}

/// The whole point of the refactor, pinned: a product is drawn by ONE
/// controller, and both hosts show that controller rather than a rendition of
/// it. This is the test that fails if someone gives the extension "just a
/// slightly different" seller list again.
final class ProductSurfaceParityTests: XCTestCase {

    override func setUp() {
        super.setUp()
        UIView.setAnimationsEnabled(false)
    }

    override func tearDown() {
        UITestSupport.wipeSharedStore()
        super.tearDown()
    }

    @MainActor
    func testTheCardAndTheExtensionEditorHostTheSameProductSurface() {
        UITestSupport.seedSharedStore(.priceTracking)
        guard let item = ReadingListStore.shared.items().first(where: { $0.isPriceTracker }) else {
            XCTFail("no price tracker seeded"); return
        }

        let card = ProductCardContentViewController(itemID: item.id)
        let cardWindow = UITestSupport.host(card)
        card.view.layoutIfNeeded()

        let editor = PriceTrackingViewController(
            mode: .creation(itemID: item.id, host: .extension))
        let editorWindow = UITestSupport.host(editor)
        editor.view.layoutIfNeeded()

        for (name, host) in [("card", card as UIViewController), ("editor", editor)] {
            XCTAssertTrue(
                host.children.contains { $0 is ProductDetailViewController },
                "the \(name) should HOST the shared product surface, not rebuild it")
            XCTAssertNotNil(
                host.view.firstDescendant(ofType: AlertThresholdRow.self),
                "the \(name) is missing the one alert control")
            XCTAssertNotNil(
                host.view.firstDescendant(ofType: SellerRowView.self),
                "the \(name) is missing the one seller row")
            XCTAssertNotNil(
                host.view.firstDescendant(ofType: PriceGraphView.self),
                "the \(name) is missing the graph")
        }
        _ = cardWindow
        _ = editorWindow
    }

    /// The alert row and the graph line are two views of one number. Moving the
    /// slider moves the line before anything is committed, which is what makes
    /// the readout believable.
    @MainActor
    func testTheAlertRowAndTheGraphLineShowTheSameThreshold() {
        UITestSupport.seedSharedStore(.priceTracking)
        guard let item = ReadingListStore.shared.items().first(where: {
            $0.priceTracker?.hasAlertThreshold == true
        }), let tracker = item.priceTracker else {
            XCTFail("no price tracker with an alert seeded"); return
        }
        let card = ProductCardContentViewController(itemID: item.id)
        let window = UITestSupport.host(card)
        card.view.layoutIfNeeded()

        guard let row = card.view.firstDescendant(ofType: AlertThresholdRow.self),
              let slider = row.firstDescendant(ofType: UISlider.self),
              let handle = card.view.firstDescendant(ofType: PriceGraphView.self)
                .flatMap({ graph in
                    graph.subviews.compactMap { $0 as? UIButton }.first {
                        $0.accessibilityLabel == "Alert threshold"
                    }
                })
        else {
            XCTFail("the card should show the alert row and the graph's handle"); return
        }
        let expected = PriceFormatting.string(
            amount: tracker.alertThresholdPrice ?? 0, currency: tracker.displayCurrency)
        XCTAssertEqual(slider.accessibilityValue, expected)
        XCTAssertEqual(handle.accessibilityValue, expected)

        // Drag the row's slider: the line follows immediately, uncommitted. The
        // assertion is that the two agree, not what they agree ON — the number
        // is whatever the slider is standing at.
        slider.value = 0.5
        slider.sendActions(for: .valueChanged)
        XCTAssertNotEqual(slider.accessibilityValue, expected, "the drag moved the threshold")
        XCTAssertEqual(
            handle.accessibilityValue, slider.accessibilityValue,
            "the line follows the slider live")
        XCTAssertEqual(
            ReadingListStore.shared.item(withID: item.id)?.priceTracker?.alertThresholdFraction,
            tracker.alertThresholdFraction,
            "and nothing is persisted until the drag ends")
        _ = window
    }
}

private extension UIView {
    func firstDescendant<T: UIView>(ofType type: T.Type) -> T? {
        if let match = self as? T { return match }
        return subviews.lazy.compactMap { $0.firstDescendant(ofType: type) }.first
    }
}
