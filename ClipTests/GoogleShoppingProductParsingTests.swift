//
//  GoogleShoppingProductParsingTests.swift
//  ClipTests
//

import ClipHTMLClassification
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
}
