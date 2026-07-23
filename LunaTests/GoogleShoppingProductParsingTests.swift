//
//  GoogleShoppingProductParsingTests.swift
//  LunaTests
//

import LunaPriceIngest
import LunaHTMLClassification
import XCTest

final class GoogleShoppingProductParsingTests: XCTestCase {
    private func url(_ string: String) -> URL {
        guard let url = URL(string: string) else { fatalError("bad test URL: \(string)") }
        return url
    }

    func testGoogleShoppingExtractsSellerListingsInsteadOfGoogle() async {
        let html = BypassFixtures.html("Products/google-shopping-mova.html")
        let metadata = await ProductMetadataExtractor().extract(
            url: url("https://www.google.com/search?q=mova+v50+complete+vs+ultr&udm=28&shopmd=1"),
            html: html)

        XCTAssertEqual(metadata?.name, "Mova V50 Ultra Robotic Vacuum and Mop")
        XCTAssertEqual(metadata?.price.amount, 1098)
        XCTAssertEqual(metadata?.price.currency, "AUD")
        XCTAssertEqual(metadata?.sellers.map(\.url.host), [
            "www.amazon.com.au",
            "www.harveynorman.com.au",
            "au.mova-tech.com",
        ])
        XCTAssertEqual(metadata?.sellers.map(\.price.amount), [1099, 1098, 1099])
        XCTAssertFalse(metadata?.sellers.contains { $0.url.host?.contains("google") == true } ?? true)
        XCTAssertEqual(
            metadata?.sellers.first?.url.absoluteString,
            "https://www.amazon.com.au/MOVA-V50-Ultra-Auto-Empty-Robot/dp/B0F1234567")
    }

    /// The new-style product offers page (`ibp=oshop` + `prds`, what a shared
    /// `share.google` product link resolves to) extracts the same per-seller listings
    /// — and collapses one retailer listed twice under different click-tracking query
    /// strings into a single seller.
    func testGoogleShoppingIbpOshopExtractsDistinctSellers() async {
        let html = BypassFixtures.html("Products/google-shopping-ibp-oshop.html")
        let metadata = await ProductMetadataExtractor().extract(
            url: url(
                "https://www.google.com/search?ibp=oshop&q=Ryobi+18V&prds=productid:17194174350050566621"),
            html: html)

        XCTAssertEqual(metadata?.name, "Ryobi 18V ONE+ HP Brushless Stick Vacuum 4Ah Kit")
        // Best (lowest) price becomes the tracker baseline.
        XCTAssertEqual(metadata?.price.amount, 459)
        XCTAssertEqual(metadata?.price.currency, "AUD")
        // The two www.bunnings.com.au links (different tracking query strings) collapse
        // to one seller; trade.bunnings.com.au is a distinct host and stays separate.
        XCTAssertEqual(metadata?.sellers.map(\.url.host), [
            "www.bunnings.com.au",
            "www.ebay.com.au",
            "trade.bunnings.com.au",
        ])
        XCTAssertEqual(metadata?.sellers.map(\.price.amount), [459, 645, 459])
        XCTAssertEqual(metadata?.sellers.map(\.price.currency), ["AUD", "AUD", "AUD"])
        // No Google-owned host leaks in as a "seller".
        XCTAssertFalse(metadata?.sellers.contains { $0.url.host?.contains("google") == true } ?? true)
        // srsltid is stripped from the stored seller URL; the retailer's own params stay.
        XCTAssertEqual(
            metadata?.sellers.first?.url.absoluteString,
            "https://www.bunnings.com.au/ryobi-18v-stick-vac_p0657567?region_id=117152")
    }
}
