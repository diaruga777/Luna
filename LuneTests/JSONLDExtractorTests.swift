//
//  JSONLDExtractorTests.swift
//  LuneTests
//

import LuneHTMLClassification
import XCTest
@testable import Lune

/// Covers `ArticleExtractor.extractFromJSONLD` — forced JSON-LD articleBody recovery
/// used by the `.jsonLDBody` strategy, against trimmed real-publisher fixtures.
final class JSONLDExtractorTests: XCTestCase {

    private let extractor = ArticleExtractor()
    private let baseURL = URL(string: "https://www.example.com/story")!

    func testFullArticleBodyRecoveredDespitePaywallFlag() {
        let html = BypassFixtures.html("jsonld-bloomberg.html")
        let content = extractor.extractFromJSONLD(html: html, baseURL: baseURL)
        XCTAssertNotNil(content)
        XCTAssertEqual(content?.title, "Markets Wobble as Traders Weigh Rate Path")
        XCTAssertEqual(content?.author, "Jane Reporter")
        XCTAssertTrue((content?.bodyTextLength ?? 0) > 600)
        // Multiple newline-separated paragraphs become multiple blocks.
        XCTAssertTrue((content?.blocks.count ?? 0) >= 4)
    }

    func testGraphWrappedArticleRecovered() {
        let html = BypassFixtures.html("jsonld-graph.html")
        let content = extractor.extractFromJSONLD(html: html, baseURL: baseURL)
        XCTAssertNotNil(content)
        XCTAssertEqual(content?.title, "Inside the Quiet Reshaping of the Power Grid")
        XCTAssertTrue((content?.bodyTextLength ?? 0) > 600)
    }

    func testTruncatedBodyParsedButRejectedByReadabilityGate() {
        let html = BypassFixtures.html("jsonld-truncated.html")
        let content = extractor.extractFromJSONLD(html: html, baseURL: baseURL)
        // It's still parsed (the strategy doesn't pre-filter on length)…
        XCTAssertNotNil(content)
        // …but it's too short to read, so the shared readability gate rejects it.
        XCTAssertFalse(content?.hasReadableBody ?? true)
    }

    func testNoJSONLDReturnsNil() {
        let html = BypassFixtures.html("no-jsonld.html")
        XCTAssertNil(extractor.extractFromJSONLD(html: html, baseURL: baseURL))
    }
}
