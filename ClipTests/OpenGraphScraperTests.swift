//
//  OpenGraphScraperTests.swift
//  ClipTests
//

import XCTest
@testable import Clip

/// Covers the pure `ogContent` HTML scrape — the parsing half of
/// `OpenGraphScraper`. The networked `fetch` is not exercised here.
final class OpenGraphScraperTests: XCTestCase {

    func testExtractsOGTitle() {
        let html = #"<meta property="og:title" content="A Post Title">"#
        XCTAssertEqual(OpenGraphScraper.ogContent(property: "og:title", in: html), "A Post Title")
    }

    func testToleratesContentBeforeProperty() {
        let html = #"<meta content="Reversed" property="og:title">"#
        XCTAssertEqual(OpenGraphScraper.ogContent(property: "og:title", in: html), "Reversed")
    }

    func testToleratesExtraAttributesBetween() {
        let html = #"<meta property="og:image" data-rh="true" itemprop="image" content="https://cdn/x.jpg">"#
        XCTAssertEqual(
            OpenGraphScraper.ogContent(property: "og:image", in: html),
            "https://cdn/x.jpg")
    }

    func testIsCaseInsensitive() {
        let html = #"<META PROPERTY="OG:TITLE" CONTENT="Caps">"#
        XCTAssertEqual(OpenGraphScraper.ogContent(property: "og:title", in: html), "Caps")
    }

    func testSingleQuotedAttributes() {
        let html = "<meta property='og:description' content='A description'>"
        XCTAssertEqual(
            OpenGraphScraper.ogContent(property: "og:description", in: html),
            "A description")
    }

    func testDecodesCommonEntities() {
        let html = #"<meta property="og:title" content="Salt &amp; Pepper&#039;s &quot;Diner&quot;">"#
        XCTAssertEqual(
            OpenGraphScraper.ogContent(property: "og:title", in: html),
            "Salt & Pepper's \"Diner\"")
    }

    func testDecodesNumericApostropheVariants() {
        let html = #"<meta property="og:title" content="It&#39;s here">"#
        XCTAssertEqual(OpenGraphScraper.ogContent(property: "og:title", in: html), "It's here")
    }

    func testReturnsNilForEmptyContent() {
        let html = #"<meta property="og:title" content="">"#
        XCTAssertNil(OpenGraphScraper.ogContent(property: "og:title", in: html))
    }

    func testReturnsNilWhenPropertyAbsent() {
        let html = #"<meta property="og:title" content="Present">"#
        XCTAssertNil(OpenGraphScraper.ogContent(property: "og:image", in: html))
    }

    func testPicksFirstMatchingTagInDocument() {
        let html = """
        <head>
        <meta property="og:image" content="https://cdn/first.jpg">
        <meta property="og:image" content="https://cdn/second.jpg">
        </head>
        """
        XCTAssertEqual(
            OpenGraphScraper.ogContent(property: "og:image", in: html),
            "https://cdn/first.jpg")
    }

    func testInstagramStyleHead() {
        let html = """
        <head>
        <meta property="og:site_name" content="Instagram">
        <meta property="og:title" content="Login • Instagram">
        <meta property="og:image" content="https://scontent.cdninstagram.com/v/abc.jpg">
        <meta property="og:description" content="See photos and videos.">
        </head>
        """
        XCTAssertEqual(
            OpenGraphScraper.ogContent(property: "og:title", in: html),
            "Login • Instagram")
        XCTAssertEqual(
            OpenGraphScraper.ogContent(property: "og:image", in: html),
            "https://scontent.cdninstagram.com/v/abc.jpg")
    }
}
