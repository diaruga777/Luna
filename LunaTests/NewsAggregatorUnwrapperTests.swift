//
//  NewsAggregatorUnwrapperTests.swift
//  LunaTests
//

import LunaFetch
import LunaURLClassification
import XCTest
@testable import Luna

/// Covers the pure (network-free) parsing of `NewsAggregatorUnwrapper`: Apple News
/// publisher extraction, Google News id parsing + offline base64 decode + the
/// batchexecute response parse, and host classification.
final class NewsAggregatorUnwrapperTests: XCTestCase {

    private func url(_ string: String) -> URL {
        guard let url = URL(string: string) else { fatalError("bad test URL: \(string)") }
        return url
    }

    // MARK: - Apple News

    func testAppleNewsPublisherURL() {
        let cases: [(name: String, html: String, expected: String?)] = [
            // The exact shape served by apple.news (a JS redirect call).
            ("redirect call",
             #"<script>function redirectToUrlAfterTimeout(url, t){} "#
                + #"redirectToUrlAfterTimeout("https://www.weatherzone.com.au/news/australias-darkest-weekend-of-2026-is-here/1891414", 3000);</script>"#,
             "https://www.weatherzone.com.au/news/australias-darkest-weekend-of-2026-is-here/1891414"),
            // A News+ exclusive (or an unexpected page) carries no redirect target.
            ("no redirect target",
             "<html><head><title>Apple News</title></head><body>Open in the News app.</body></html>",
             nil),
            ("self-referential redirect is ignored",
             #"redirectToUrlAfterTimeout("https://apple.news/AONYnIYXuSh", 3000);"#,
             nil),
        ]

        for testCase in cases {
            XCTAssertEqual(
                NewsAggregatorUnwrapper.appleNewsPublisherURL(inHTML: testCase.html)?.absoluteString,
                testCase.expected,
                testCase.name)
        }
    }

    // MARK: - Google News id parsing

    func testGoogleNewsArticleID() {
        let cases: [(input: String, expected: String?)] = [
            ("https://news.google.com/rss/articles/CBMiABCxyz?oc=5", "CBMiABCxyz"),
            ("https://news.google.com/articles/CBMiZZZ", "CBMiZZZ"),
            ("https://news.google.com/read/CBMiREAD123", "CBMiREAD123"),
            ("https://news.google.com/home", nil),
        ]

        for testCase in cases {
            XCTAssertEqual(
                NewsAggregatorUnwrapper.googleNewsArticleID(from: url(testCase.input)),
                testCase.expected,
                testCase.input)
        }
    }

    // MARK: - Google News offline base64 decode

    /// URL-safe base64, the way Google News encodes an article id.
    private func articleID(bytes: [UInt8]) -> String {
        Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    func testGoogleNewsOfflineBase64Decode() {
        // Classic ids base64-decode to a protobuf blob: prefix 0x08 0x13 0x22, a
        // length byte, the URL, then the 0xd2 0x01 0x00 suffix. (The 0x08 0x13 0x22
        // prefix is exactly what the real "CBMi" id prefix decodes to.)
        let publisher = "https://www.example.com/news/story-123"
        var classic: [UInt8] = [0x08, 0x13, 0x22, UInt8(publisher.utf8.count)]
        classic += Array(publisher.utf8)
        classic += [0xd2, 0x01, 0x00]

        let cases: [(name: String, bytes: [UInt8], idPrefix: String?, expected: String?)] = [
            ("classic id with an embedded URL", classic, "CBMi", publisher),
            // A blob with no embedded http(s) URL (new-style) isn't decodable offline.
            ("new-style id, no embedded URL",
             [0x08, 0x13, 0x22, 0x06, 0x41, 0x55, 0x5F, 0x79, 0x71, 0x4C], nil, nil),
        ]

        for testCase in cases {
            let id = articleID(bytes: testCase.bytes)
            if let prefix = testCase.idPrefix {
                XCTAssertTrue(
                    id.hasPrefix(prefix),
                    "\(testCase.name): sanity — real ids of this shape start with \(prefix)")
            }
            XCTAssertEqual(
                NewsAggregatorUnwrapper.googleNewsURL(fromArticleID: id)?.absoluteString,
                testCase.expected,
                testCase.name)
        }
    }

    func testEmbeddedHTTPURLStopsAtFramingBytes() {
        var bytes = Array("https://site.com/a".utf8)
        bytes += [0xd2, 0x01, 0x00, 0x41]   // suffix framing must not bleed into the URL
        XCTAssertEqual(
            NewsAggregatorUnwrapper.firstEmbeddedHTTPURL(in: Data(bytes))?.absoluteString,
            "https://site.com/a")
    }

    // MARK: - Google batchexecute response parse

    func testBatchExecuteResponse() {
        let full = #"""
        )]}'

        [["wrb.fr","Fbv4je","[\"garturlres\",\"https://real.example.com/article-42\",[\"en\",\"US\"]]",null,null,null,"generic"]]
        28
        [["di",53],["af.httprm",53,"x",6]]
        """#
        let cases: [(name: String, response: String, expected: String?)] = [
            ("full garturlres envelope", full, "https://real.example.com/article-42"),
            ("envelope with no URL", ")]}'\n\n[[\"wrb.fr\"]]", nil),
        ]

        for testCase in cases {
            XCTAssertEqual(
                NewsAggregatorUnwrapper.googleBatchExecuteURL(
                    fromResponse: testCase.response)?.absoluteString,
                testCase.expected,
                testCase.name)
        }
    }

    // MARK: - Host classification

    func testHostClassification() {
        let appleNews: [(host: String, expected: Bool)] = [
            ("apple.news", true), ("www.apple.news", true), ("apple.com", false),
        ]
        for testCase in appleNews {
            XCTAssertEqual(
                NewsAggregatorUnwrapper.isAppleNews(testCase.host), testCase.expected,
                "isAppleNews(\(testCase.host))")
        }

        let googleNews: [(host: String, expected: Bool)] = [
            ("news.google.com", true), ("google.com", false),
        ]
        for testCase in googleNews {
            XCTAssertEqual(
                NewsAggregatorUnwrapper.isGoogleNews(testCase.host), testCase.expected,
                "isGoogleNews(\(testCase.host))")
        }
    }

    // MARK: - Facebook redirect / share links

    func testFacebookRedirectTarget() {
        // The EXACT URL a user reported — an Android Messenger `fbrpc://` deep link.
        // `URL(string:)` must accept it, and the http TechCrunch target (with its
        // fbclid) must be extracted.
        let verbatimMessengerLink = "fbrpc://nativethirdparty/f?app_id=256002347743983&app_name=Facebook+Messenger+for+Android&tap_behavior=web_always&target_url=https%3A%2F%2Ftechcrunch.com%2F2026%2F06%2F09%2Fits-not-faang-anymore-its-mangos%2F%3Ffbclid%3DIwZXh0bgNhZW0CMTEAc3J0YwZhcHBfaWQPNDM3NjI2MzE2OTczNzg4AAEesLLIh-33d22w_j_vcraYxjkGxo8pg5wAib6dE_XSvMmTiqzq8vCYqn_5E9I_aem_-AaPmuGo5Y_7mWnRzLDotQ&app_sites=%5B%22fb256002347743983%3A%5C%2F%5C%2Fauthorize%23target_url%3Dhttps%5Cu00253A%5Cu00252F%5Cu00252Ftechcrunch.com%5Cu00252F2026%5Cu00252F06%5Cu00252F09%5Cu00252Fits-not-faang-anymore-its-mangos%5Cu00252F%5Cu00253Ffbclid%5Cu00253DIwZXh0bgNhZW0CMTEAc3J0YwZhcHBfaWQPNDM3NjI2MzE2OTczNzg4AAEesLLIh-33d22w_j_vcraYxjkGxo8pg5wAib6dE_XSvMmTiqzq8vCYqn_5E9I_aem_-AaPmuGo5Y_7mWnRzLDotQ%22%5D&has_app_link=0"

        let cases: [(name: String, input: String, expected: String?)] = [
            ("fbrpc deep link",
             "fbrpc://nativethirdparty/f?app_id=123456789"
                + "&target_url=https%3A%2F%2Ftechcrunch.com%2F2026%2F06%2F09%2Fits-not-faang-anymore-its-mangos%2F%3Ffbclid%3DAbCdEf123"
                + "&app_sites=https%3A%2F%2Fexample.com",
             "https://techcrunch.com/2026/06/09/its-not-faang-anymore-its-mangos/?fbclid=AbCdEf123"),
            ("l.facebook.com link shim",
             "https://l.facebook.com/l.php?u=https%3A%2F%2Fwww.theverge.com%2F2026%2F06%2F01%2Fstory&h=AT123",
             "https://www.theverge.com/2026/06/01/story"),
            ("m.facebook.com link shim",
             "https://m.facebook.com/l.php?u=https%3A%2F%2Fexample.org%2Farticle",
             "https://example.org/article"),
            ("verbatim Android Messenger fbrpc link", verbatimMessengerLink,
             "https://techcrunch.com/2026/06/09/its-not-faang-anymore-its-mangos/?fbclid=IwZXh0bgNhZW0CMTEAc3J0YwZhcHBfaWQPNDM3NjI2MzE2OTczNzg4AAEesLLIh-33d22w_j_vcraYxjkGxo8pg5wAib6dE_XSvMmTiqzq8vCYqn_5E9I_aem_-AaPmuGo5Y_7mWnRzLDotQ"),
            ("not a Facebook URL",
             "https://www.nytimes.com/2026/06/20/world/story.html", nil),
            ("fbrpc target is not http",
             "fbrpc://nativethirdparty/f?app_id=123&target_url=fb%3A%2F%2Fprofile%2F42", nil),
            ("link shim target is Facebook itself",
             "https://l.facebook.com/l.php?u=https%3A%2F%2Fwww.facebook.com%2Fgroups%2F42", nil),
        ]

        for testCase in cases {
            guard let parsed = URL(string: testCase.input) else {
                XCTFail("URL(string:) must accept \(testCase.name)")
                continue
            }
            XCTAssertEqual(
                NewsAggregatorUnwrapper.facebookRedirectTarget(parsed)?.absoluteString,
                testCase.expected,
                testCase.name)
        }
    }

    func testFacebookRPCUnwrapStripsTrackingViaCanonicalization() {
        // The fbrpc target carries an fbclid; canonicalForArchiving must drop it.
        let target = url("https://techcrunch.com/2026/06/09/its-not-faang-anymore-its-mangos/?fbclid=AbCdEf123")
        XCTAssertEqual(
            ArticleFetcher.canonicalForArchiving(target).absoluteString,
            "https://techcrunch.com/2026/06/09/its-not-faang-anymore-its-mangos/")
    }
}
