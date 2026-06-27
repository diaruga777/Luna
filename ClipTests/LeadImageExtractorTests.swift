//
//  LeadImageExtractorTests.swift
//  ClipTests
//

import ClipHTMLClassification
import XCTest
@testable import Clip

final class LeadImageExtractorTests: XCTestCase {

    private let baseURL = URL(string: "https://example.com/article")!

    // MARK: - imageURL: source precedence

    func testPrefersOGImageOverTwitterImage() {
        let html = """
        <meta property="og:image" content="https://cdn.example.com/og.jpg">
        <meta name="twitter:image" content="https://cdn.example.com/twitter.jpg">
        """
        XCTAssertEqual(
            LeadImageExtractor.imageURL(in: html, baseURL: baseURL)?.absoluteString,
            "https://cdn.example.com/og.jpg")
    }

    func testFallsBackToTwitterImageWhenNoOG() {
        let html = #"<meta name="twitter:image" content="https://cdn.example.com/t.png">"#
        XCTAssertEqual(
            LeadImageExtractor.imageURL(in: html, baseURL: baseURL)?.absoluteString,
            "https://cdn.example.com/t.png")
    }

    func testFallsBackToLinkImageSrc() {
        let html = #"<link rel="image_src" href="https://cdn.example.com/legacy.jpg">"#
        XCTAssertEqual(
            LeadImageExtractor.imageURL(in: html, baseURL: baseURL)?.absoluteString,
            "https://cdn.example.com/legacy.jpg")
    }

    // MARK: - imageURL: attribute ordering & variants

    func testHandlesContentBeforeProperty() {
        let html = #"<meta content="https://cdn.example.com/reversed.jpg" property="og:image">"#
        XCTAssertEqual(
            LeadImageExtractor.imageURL(in: html, baseURL: baseURL)?.absoluteString,
            "https://cdn.example.com/reversed.jpg")
    }

    func testMatchesOGImageURLVariant() {
        let html = #"<meta property="og:image:url" content="https://cdn.example.com/explicit.jpg">"#
        XCTAssertEqual(
            LeadImageExtractor.imageURL(in: html, baseURL: baseURL)?.absoluteString,
            "https://cdn.example.com/explicit.jpg")
    }

    func testMatchesTwitterImageSrcVariant() {
        let html = #"<meta name="twitter:image:src" content="https://cdn.example.com/src.jpg">"#
        XCTAssertEqual(
            LeadImageExtractor.imageURL(in: html, baseURL: baseURL)?.absoluteString,
            "https://cdn.example.com/src.jpg")
    }

    func testIsCaseInsensitive() {
        let html = #"<META PROPERTY="OG:IMAGE" CONTENT="https://cdn.example.com/caps.jpg">"#
        XCTAssertEqual(
            LeadImageExtractor.imageURL(in: html, baseURL: baseURL)?.absoluteString,
            "https://cdn.example.com/caps.jpg")
    }

    func testSingleQuotedAttributes() {
        let html = "<meta property='og:image' content='https://cdn.example.com/single.jpg'>"
        XCTAssertEqual(
            LeadImageExtractor.imageURL(in: html, baseURL: baseURL)?.absoluteString,
            "https://cdn.example.com/single.jpg")
    }

    // MARK: - imageURL: URL handling

    func testResolvesRelativeURLAgainstBase() {
        let html = #"<meta property="og:image" content="/media/cover.jpg">"#
        XCTAssertEqual(
            LeadImageExtractor.imageURL(in: html, baseURL: baseURL)?.absoluteString,
            "https://example.com/media/cover.jpg")
    }

    func testDecodesAmpersandEntityInURL() {
        let html = #"<meta property="og:image" content="https://cdn.example.com/i.jpg?w=1200&amp;h=630">"#
        XCTAssertEqual(
            LeadImageExtractor.imageURL(in: html, baseURL: baseURL)?.absoluteString,
            "https://cdn.example.com/i.jpg?w=1200&h=630")
    }

    func testRejectsNonHTTPScheme() {
        let html = #"<meta property="og:image" content="data:image/png;base64,AAAA">"#
        XCTAssertNil(LeadImageExtractor.imageURL(in: html, baseURL: baseURL))
    }

    func testReturnsNilWhenNoImageMeta() {
        let html = "<html><head><title>No image here</title></head><body><p>Text.</p></body></html>"
        XCTAssertNil(LeadImageExtractor.imageURL(in: html, baseURL: baseURL))
    }

    // MARK: - Real-world publisher snippets

    func testGuardianStyleHead() {
        let html = """
        <head>
        <meta charset="utf-8">
        <meta property="og:url" content="https://www.theguardian.com/world/2024/jan/01/story">
        <meta property="og:title" content="A major world story unfolds">
        <meta property="og:description" content="What happened and why it matters.">
        <meta property="og:image" content="https://i.guim.co.uk/img/media/abc/master/2000.jpg?width=1200&amp;quality=85">
        <meta name="twitter:card" content="summary_large_image">
        </head>
        """
        XCTAssertEqual(
            LeadImageExtractor.imageURL(in: html, baseURL: baseURL)?.absoluteString,
            "https://i.guim.co.uk/img/media/abc/master/2000.jpg?width=1200&quality=85")
    }

    func testSubstackStyleHead() {
        let html = """
        <head>
        <meta property="og:type" content="article">
        <meta property="og:title" content="My Newsletter Post">
        <meta name="twitter:image" content="https://substackcdn.com/image/fetch/abc.png">
        </head>
        """
        // No og:image, so twitter:image wins.
        XCTAssertEqual(
            LeadImageExtractor.imageURL(in: html, baseURL: baseURL)?.absoluteString,
            "https://substackcdn.com/image/fetch/abc.png")
    }

    // MARK: - metaContent

    func testMetaContentDecodesEntities() {
        let html = #"<meta property="og:title" content="Tim &amp; Eric&#39;s &quot;Show&quot;">"#
        XCTAssertEqual(
            LeadImageExtractor.metaContent(property: "og:title", in: html),
            "Tim & Eric's \"Show\"")
    }

    func testMetaContentHandlesNameAttribute() {
        let html = #"<meta name="twitter:title" content="Tweet Title">"#
        XCTAssertEqual(
            LeadImageExtractor.metaContent(property: "twitter:title", in: html),
            "Tweet Title")
    }

    func testMetaContentHandlesReversedOrder() {
        let html = #"<meta content="Reversed Description" property="og:description">"#
        XCTAssertEqual(
            LeadImageExtractor.metaContent(property: "og:description", in: html),
            "Reversed Description")
    }

    func testMetaContentReturnsNilWhenAbsent() {
        let html = #"<meta property="og:title" content="Present">"#
        XCTAssertNil(LeadImageExtractor.metaContent(property: "og:image", in: html))
    }
}
