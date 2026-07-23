//
//  RescueDigestBuilderTests.swift
//  LunaTests
//

import XCTest
@testable import LunaURLRescue

final class RescueDigestBuilderTests: XCTestCase {
    private let builder = RescueDigestBuilder()
    private let url = URL(string: "https://www.example.com/story")!

    func testRespectsCharacterBudget() {
        let big = String(repeating: "<p>lorem ipsum dolor sit amet consectetur adipiscing elit </p>", count: 5000)
        let html = "<html><head><title>T</title></head><body>\(big)</body></html>"
        let digest = builder.buildDigest(url: url, html: html, hint: .article, budget: .onDevice)
        XCTAssertLessThanOrEqual(digest.count, RescueDigestBudget.onDevice.maxCharacters)
    }

    func testHeadMetadataIncluded() {
        let html = """
        <html><head><title>Headline</title>
        <meta name="description" content="A great story">
        <meta property="og:title" content="OG Headline">
        <link rel="canonical" href="https://www.example.com/story">
        </head><body><p>Body text here.</p></body></html>
        """
        let digest = builder.buildDigest(url: url, html: html, hint: .article, budget: .privateCloud)
        XCTAssertTrue(digest.contains("Headline"))
        XCTAssertTrue(digest.contains("A great story"))
        XCTAssertTrue(digest.contains("canonical"))
    }

    func testJSONLDProductRankedFirst() {
        let html = """
        <html><head>
        <script type="application/ld+json">{"@type":"WebPage","name":"generic"}</script>
        <script type="application/ld+json">{"@type":"Product","offers":{"price":"9.99"}}</script>
        </head><body></body></html>
        """
        let digest = builder.buildDigest(url: url, html: html, hint: .product, budget: .privateCloud)
        let productIdx = digest.range(of: "\"Product\"")?.lowerBound
        let genericIdx = digest.range(of: "\"generic\"")?.lowerBound
        XCTAssertNotNil(productIdx)
        XCTAssertNotNil(genericIdx)
        if let p = productIdx, let g = genericIdx { XCTAssertLessThan(p, g) }
    }

    func testMediaHintGrepsMediaURLs() {
        let html = """
        <html><body><script>var x = {"playable_url":"https://cdn.net/v.mp4"};</script></body></html>
        """
        let digest = builder.buildDigest(url: url, html: html, hint: .media, budget: .privateCloud)
        XCTAssertTrue(digest.contains("playable_url") || digest.contains("v.mp4"))
    }

    func testCandidateURLsCappedAt30() {
        var links = ""
        for i in 0..<60 { links += "<a href=\"https://www.example.com/amp/\(i)\">l</a>" }
        let html = "<html><body>\(links)</body></html>"
        let digest = builder.buildDigest(url: url, html: html, hint: .article, budget: .privateCloud)
        let count = digest.components(separatedBy: "link: ").count - 1
        XCTAssertLessThanOrEqual(count, 30)
    }

    func testMalformedHTMLDegradesGracefully() {
        let html = "<<<not really html >>> plain text body content here for the digest"
        let digest = builder.buildDigest(url: url, html: html, hint: .article, budget: .onDevice)
        XCTAssertFalse(digest.isEmpty)
    }

    func testHalvedBudgetIsSmaller() {
        XCTAssertLessThan(RescueDigestBudget.onDevice.halved.maxCharacters, RescueDigestBudget.onDevice.maxCharacters)
    }

    func testTokenEstimate() {
        XCTAssertEqual(RescueDigestBudget.estimatedTokens(forCharacters: 400), 100)
    }
}
