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

    /// The plugin the tracker store names, matching that store's host and
    /// declaring `product` — the two things a refresh checks before it runs.
    private func invoker(
        id: String, hosts: [String] = ["shop.test"],
        produces: [PluginModelKind] = [.product]
    ) -> FakePluginInvoker {
        let invoker = FakePluginInvoker()
        invoker.loadedPlugins = [.fake(id: id, hosts: hosts, produces: produces)]
        return invoker
    }

    func testTheFetcherReadsOnlyThePriceOffTheRefreshedModel() async {
        let invoker = self.invoker(id: "app.luna.shop")
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
        let invoker = self.invoker(id: "p")
        invoker.ingestAnswers["p"] = .json(#"{"kind":"media","assets":[]}"#)
        let price = await PluginPriceFetcher(invoker: invoker, processKind: .app)
            .price(forStoreURL: storeURL, pluginID: "p")
        XCTAssertNil(price, "the refresher then falls back to the Swift fetcher")
    }

    func testAPluginThatIsGoneRefreshesNothing() async {
        let invoker = self.invoker(id: "p")
        invoker.ingestAnswers["p"] = .failure(.notLoaded)
        let price = await PluginPriceFetcher(invoker: invoker, processKind: .app)
            .price(forStoreURL: storeURL, pluginID: "p")
        XCTAssertNil(price)
    }

    /// A tracker stamps its plugin onto every store it owns, alternative
    /// sellers included. Those sit on hosts the plugin never claimed, and the
    /// Swift refresher owns them.
    func testAStoreOnAHostThePluginDoesNotMatchIsNotSentToIt() async {
        let invoker = self.invoker(id: "p", hosts: ["shop.test"])
        invoker.ingestAnswers["p"] = .json("""
            {"kind":"product","name":"T","price":{"amount":"5","currency":"USD"}}
            """)
        let price = await PluginPriceFetcher(invoker: invoker, processKind: .app)
            .price(forStoreURL: URL(string: "https://other.test/thing")!, pluginID: "p")
        XCTAssertNil(price)
        XCTAssertTrue(invoker.ingestReasons.isEmpty, "the plugin must not be invoked at all")
    }

    func testAPluginThatNoLongerProducesProductsIsNotAsked() async {
        let invoker = self.invoker(id: "p", produces: [.media])
        invoker.ingestAnswers["p"] = .json("""
            {"kind":"product","name":"T","price":{"amount":"5","currency":"USD"}}
            """)
        let price = await PluginPriceFetcher(invoker: invoker, processKind: .app)
            .price(forStoreURL: storeURL, pluginID: "p")
        XCTAssertNil(price)
        XCTAssertTrue(invoker.ingestReasons.isEmpty)
    }

    func testAZeroPriceIsRefused() async {
        let invoker = self.invoker(id: "p")
        invoker.ingestAnswers["p"] = .json("""
            {"kind":"product","name":"T","price":{"amount":"0","currency":"USD"}}
            """)
        let price = await PluginPriceFetcher(invoker: invoker, processKind: .app)
            .price(forStoreURL: storeURL, pluginID: "p")
        XCTAssertNil(price, "a tracker never records a priceless refresh")
    }
}
