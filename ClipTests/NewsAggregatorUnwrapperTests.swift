//
//  NewsAggregatorUnwrapperTests.swift
//  ClipTests
//

import XCTest
@testable import Clip

/// Covers the pure (network-free) parsing of `NewsAggregatorUnwrapper`: Apple News
/// publisher extraction, Google News id parsing + offline base64 decode + the
/// batchexecute response parse, and host classification.
final class NewsAggregatorUnwrapperTests: XCTestCase {

    private func url(_ string: String) -> URL {
        guard let url = URL(string: string) else { fatalError("bad test URL: \(string)") }
        return url
    }

    // MARK: - Apple News

    func testAppleNewsExtractsPublisherURLFromRedirectCall() {
        // The exact shape served by apple.news (a JS redirect call).
        let html = #"<script>function redirectToUrlAfterTimeout(url, t){} "#
            + #"redirectToUrlAfterTimeout("https://www.weatherzone.com.au/news/australias-darkest-weekend-of-2026-is-here/1891414", 3000);</script>"#
        XCTAssertEqual(
            NewsAggregatorUnwrapper.appleNewsPublisherURL(inHTML: html)?.absoluteString,
            "https://www.weatherzone.com.au/news/australias-darkest-weekend-of-2026-is-here/1891414")
    }

    func testAppleNewsReturnsNilWhenNoPublisherURL() {
        // A News+ exclusive (or an unexpected page) carries no redirect target.
        let html = "<html><head><title>Apple News</title></head><body>Open in the News app.</body></html>"
        XCTAssertNil(NewsAggregatorUnwrapper.appleNewsPublisherURL(inHTML: html))
    }

    func testAppleNewsIgnoresSelfReferentialURL() {
        let html = #"redirectToUrlAfterTimeout("https://apple.news/AONYnIYXuSh", 3000);"#
        XCTAssertNil(NewsAggregatorUnwrapper.appleNewsPublisherURL(inHTML: html))
    }

    // MARK: - Google News id parsing

    func testGoogleNewsArticleIDFromRSSPath() {
        XCTAssertEqual(
            NewsAggregatorUnwrapper.googleNewsArticleID(from: url("https://news.google.com/rss/articles/CBMiABCxyz?oc=5")),
            "CBMiABCxyz")
    }

    func testGoogleNewsArticleIDFromArticlesPath() {
        XCTAssertEqual(
            NewsAggregatorUnwrapper.googleNewsArticleID(from: url("https://news.google.com/articles/CBMiZZZ")),
            "CBMiZZZ")
    }

    func testGoogleNewsArticleIDFromReadPath() {
        XCTAssertEqual(
            NewsAggregatorUnwrapper.googleNewsArticleID(from: url("https://news.google.com/read/CBMiREAD123")),
            "CBMiREAD123")
    }

    func testGoogleNewsArticleIDNilForNonArticle() {
        XCTAssertNil(NewsAggregatorUnwrapper.googleNewsArticleID(from: url("https://news.google.com/home")))
    }

    // MARK: - Google News offline base64 decode

    func testGoogleNewsClassicBase64DecodesEmbeddedURL() {
        // Classic ids base64-decode to a protobuf blob: prefix 0x08 0x13 0x22, a
        // length byte, the URL, then the 0xd2 0x01 0x00 suffix. (The 0x08 0x13 0x22
        // prefix is exactly what the real "CBMi" id prefix decodes to.)
        let publisher = "https://www.example.com/news/story-123"
        var bytes: [UInt8] = [0x08, 0x13, 0x22, UInt8(publisher.utf8.count)]
        bytes += Array(publisher.utf8)
        bytes += [0xd2, 0x01, 0x00]
        let id = Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        XCTAssertTrue(id.hasPrefix("CBMi"), "sanity: real classic ids start with CBMi")
        XCTAssertEqual(
            NewsAggregatorUnwrapper.googleNewsURL(fromArticleID: id)?.absoluteString,
            publisher)
    }

    func testGoogleNewsNewStyleBase64ReturnsNilOffline() {
        // A blob with no embedded http(s) URL (new-style) isn't decodable offline.
        let bytes: [UInt8] = [0x08, 0x13, 0x22, 0x06, 0x41, 0x55, 0x5F, 0x79, 0x71, 0x4C]
        let id = Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        XCTAssertNil(NewsAggregatorUnwrapper.googleNewsURL(fromArticleID: id))
    }

    func testEmbeddedHTTPURLStopsAtFramingBytes() {
        var bytes = Array("https://site.com/a".utf8)
        bytes += [0xd2, 0x01, 0x00, 0x41]   // suffix framing must not bleed into the URL
        XCTAssertEqual(
            NewsAggregatorUnwrapper.firstEmbeddedHTTPURL(in: Data(bytes))?.absoluteString,
            "https://site.com/a")
    }

    // MARK: - Google batchexecute response parse

    func testBatchExecuteResponseExtractsURL() {
        let response = #"""
        )]}'

        [["wrb.fr","Fbv4je","[\"garturlres\",\"https://real.example.com/article-42\",[\"en\",\"US\"]]",null,null,null,"generic"]]
        28
        [["di",53],["af.httprm",53,"x",6]]
        """#
        XCTAssertEqual(
            NewsAggregatorUnwrapper.googleBatchExecuteURL(fromResponse: response)?.absoluteString,
            "https://real.example.com/article-42")
    }

    func testBatchExecuteResponseNilWhenNoURL() {
        XCTAssertNil(NewsAggregatorUnwrapper.googleBatchExecuteURL(fromResponse: ")]}'\n\n[[\"wrb.fr\"]]"))
    }

    // MARK: - Host classification

    func testHostClassification() {
        XCTAssertTrue(NewsAggregatorUnwrapper.isAppleNews("apple.news"))
        XCTAssertTrue(NewsAggregatorUnwrapper.isAppleNews("www.apple.news"))
        XCTAssertFalse(NewsAggregatorUnwrapper.isAppleNews("apple.com"))
        XCTAssertTrue(NewsAggregatorUnwrapper.isGoogleNews("news.google.com"))
        XCTAssertFalse(NewsAggregatorUnwrapper.isGoogleNews("google.com"))
    }

    // MARK: - Non-wrapper URLs are left alone (no network)

    func testUnwrapReturnsNilForOrdinaryURL() async {
        let result = await NewsAggregatorUnwrapper.unwrap(url("https://www.nytimes.com/2026/06/20/world/story.html"))
        XCTAssertNil(result)
    }
}
