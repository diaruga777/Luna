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

    // MARK: - Facebook redirect / share links

    func testFacebookRPCExtractsTargetURL() {
        let input = "fbrpc://nativethirdparty/f?app_id=123456789"
            + "&target_url=https%3A%2F%2Ftechcrunch.com%2F2026%2F06%2F09%2Fits-not-faang-anymore-its-mangos%2F%3Ffbclid%3DAbCdEf123"
            + "&app_sites=https%3A%2F%2Fexample.com"
        XCTAssertEqual(
            NewsAggregatorUnwrapper.facebookRedirectTarget(url(input))?.absoluteString,
            "https://techcrunch.com/2026/06/09/its-not-faang-anymore-its-mangos/?fbclid=AbCdEf123")
    }

    func testFacebookLinkShimExtractsTargetURL() {
        let input = "https://l.facebook.com/l.php?u=https%3A%2F%2Fwww.theverge.com%2F2026%2F06%2F01%2Fstory&h=AT123"
        XCTAssertEqual(
            NewsAggregatorUnwrapper.facebookRedirectTarget(url(input))?.absoluteString,
            "https://www.theverge.com/2026/06/01/story")
    }

    func testFacebookLinkShimMobileHost() {
        let input = "https://m.facebook.com/l.php?u=https%3A%2F%2Fexample.org%2Farticle"
        XCTAssertEqual(
            NewsAggregatorUnwrapper.facebookRedirectTarget(url(input))?.absoluteString,
            "https://example.org/article")
    }

    func testFacebookRedirectNilForNonFacebookURL() {
        XCTAssertNil(NewsAggregatorUnwrapper.facebookRedirectTarget(
            url("https://www.nytimes.com/2026/06/20/world/story.html")))
    }

    func testFacebookRPCNilForNonHTTPTarget() {
        let input = "fbrpc://nativethirdparty/f?app_id=123&target_url=fb%3A%2F%2Fprofile%2F42"
        XCTAssertNil(NewsAggregatorUnwrapper.facebookRedirectTarget(url(input)))
    }

    func testFacebookLinkShimNilWhenTargetIsFacebook() {
        let input = "https://l.facebook.com/l.php?u=https%3A%2F%2Fwww.facebook.com%2Fgroups%2F42"
        XCTAssertNil(NewsAggregatorUnwrapper.facebookRedirectTarget(url(input)))
    }

    func testFacebookRPCExtractsTargetFromRealMessengerLink() {
        // The EXACT URL a user reported — an Android Messenger `fbrpc://` deep link.
        // `URL(string:)` must accept it, and the http TechCrunch target (with its
        // fbclid) must be extracted.
        let verbatim = "fbrpc://nativethirdparty/f?app_id=256002347743983&app_name=Facebook+Messenger+for+Android&tap_behavior=web_always&target_url=https%3A%2F%2Ftechcrunch.com%2F2026%2F06%2F09%2Fits-not-faang-anymore-its-mangos%2F%3Ffbclid%3DIwZXh0bgNhZW0CMTEAc3J0YwZhcHBfaWQPNDM3NjI2MzE2OTczNzg4AAEesLLIh-33d22w_j_vcraYxjkGxo8pg5wAib6dE_XSvMmTiqzq8vCYqn_5E9I_aem_-AaPmuGo5Y_7mWnRzLDotQ&app_sites=%5B%22fb256002347743983%3A%5C%2F%5C%2Fauthorize%23target_url%3Dhttps%5Cu00253A%5Cu00252F%5Cu00252Ftechcrunch.com%5Cu00252F2026%5Cu00252F06%5Cu00252F09%5Cu00252Fits-not-faang-anymore-its-mangos%5Cu00252F%5Cu00253Ffbclid%5Cu00253DIwZXh0bgNhZW0CMTEAc3J0YwZhcHBfaWQPNDM3NjI2MzE2OTczNzg4AAEesLLIh-33d22w_j_vcraYxjkGxo8pg5wAib6dE_XSvMmTiqzq8vCYqn_5E9I_aem_-AaPmuGo5Y_7mWnRzLDotQ%22%5D&has_app_link=0"
        let expected = "https://techcrunch.com/2026/06/09/its-not-faang-anymore-its-mangos/?fbclid=IwZXh0bgNhZW0CMTEAc3J0YwZhcHBfaWQPNDM3NjI2MzE2OTczNzg4AAEesLLIh-33d22w_j_vcraYxjkGxo8pg5wAib6dE_XSvMmTiqzq8vCYqn_5E9I_aem_-AaPmuGo5Y_7mWnRzLDotQ"
        guard let parsed = URL(string: verbatim) else {
            return XCTFail("URL(string:) must accept the verbatim fbrpc link")
        }
        XCTAssertEqual(
            NewsAggregatorUnwrapper.facebookRedirectTarget(parsed)?.absoluteString, expected)
    }

    func testFacebookRPCUnwrapStripsTrackingViaCanonicalization() {
        // The fbrpc target carries an fbclid; canonicalForArchiving must drop it.
        let target = url("https://techcrunch.com/2026/06/09/its-not-faang-anymore-its-mangos/?fbclid=AbCdEf123")
        XCTAssertEqual(
            ArticleFetcher.canonicalForArchiving(target).absoluteString,
            "https://techcrunch.com/2026/06/09/its-not-faang-anymore-its-mangos/")
    }
}
