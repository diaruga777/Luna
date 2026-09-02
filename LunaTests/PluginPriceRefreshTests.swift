//
//  PluginPriceRefreshTests.swift
//  LunaTests
//

import XCTest
import LunaModels
import LunaPluginIngest
import LunaPluginKit

/// A plugin-owned tracker store refreshes through its plugin, not through the
/// Swift price extraction (`claudedocs/plans/plugin-platform.md` §5.3).
final class PluginPriceRefreshTests: XCTestCase {

    private let storeURL = URL(string: "https://shop.test/thing")!

    func testTheFetcherReadsOnlyThePriceOffTheRefreshedModel() async {
        let invoker = FakePluginInvoker()
        invoker.ingestAnswers["app.luna.shop"] = .json("""
            {"kind":"product","name":"A RENAMED Thing",
             "price":{"amount":"8.50","currency":"aud"},
             "sellers":[{"url":"https://other.test/x"}]}
            """)

        let price = await PluginPriceFetcher(invoker: invoker, processKind: .app)
            .price(forStoreURL: storeURL, pluginID: "app.luna.shop")

        XCTAssertEqual(price?.amount, Decimal(string: "8.50"))
        XCTAssertEqual(price?.currency, "AUD")
        XCTAssertEqual(
            invoker.ingestReasons, ["refresh"],
            "a refresh calls the same hook a save does, under its own reason")
    }

    func testANonProductAnswerRefreshesNothing() async {
        let invoker = FakePluginInvoker()
        invoker.ingestAnswers["p"] = .json(#"{"kind":"media","assets":[]}"#)
        let price = await PluginPriceFetcher(invoker: invoker, processKind: .app)
            .price(forStoreURL: storeURL, pluginID: "p")
        XCTAssertNil(price, "the refresher then falls back to the Swift fetcher")
    }

    func testAPluginThatIsGoneRefreshesNothing() async {
        let invoker = FakePluginInvoker()
        invoker.ingestAnswers["p"] = .failure(.notLoaded)
        let price = await PluginPriceFetcher(invoker: invoker, processKind: .app)
            .price(forStoreURL: storeURL, pluginID: "p")
        XCTAssertNil(price)
    }

    func testAZeroPriceIsRefused() async {
        let invoker = FakePluginInvoker()
        invoker.ingestAnswers["p"] = .json("""
            {"kind":"product","name":"T","price":{"amount":"0","currency":"USD"}}
            """)
        let price = await PluginPriceFetcher(invoker: invoker, processKind: .app)
            .price(forStoreURL: storeURL, pluginID: "p")
        XCTAssertNil(price, "a tracker never records a priceless refresh")
    }
}
