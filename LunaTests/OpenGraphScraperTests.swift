//
//  OpenGraphScraperTests.swift
//  LunaTests
//

import LunaPlatforms
import XCTest
@testable import Luna

/// Covers the pure `ogContent` HTML scrape — the parsing half of
/// `OpenGraphScraper`. The networked `fetch` is not exercised here.
final class OpenGraphScraperTests: XCTestCase {

    func testOGContentScrape() {
        let twoImages = """
        <head>
        <meta property="og:image" content="https://cdn/first.jpg">
        <meta property="og:image" content="https://cdn/second.jpg">
        </head>
        """
        let instagramHead = """
        <head>
        <meta property="og:site_name" content="Instagram">
        <meta property="og:title" content="Login • Instagram">
        <meta property="og:image" content="https://scontent.cdninstagram.com/v/abc.jpg">
        <meta property="og:description" content="See photos and videos.">
        </head>
        """

        let cases: [(name: String, property: String, html: String, expected: String?)] = [
            ("plain og:title", "og:title",
             #"<meta property="og:title" content="A Post Title">"#, "A Post Title"),
            ("content attribute before property", "og:title",
             #"<meta content="Reversed" property="og:title">"#, "Reversed"),
            ("extra attributes between property and content", "og:image",
             #"<meta property="og:image" data-rh="true" itemprop="image" content="https://cdn/x.jpg">"#,
             "https://cdn/x.jpg"),
            ("uppercase tag and attributes", "og:title",
             #"<META PROPERTY="OG:TITLE" CONTENT="Caps">"#, "Caps"),
            ("single-quoted attributes", "og:description",
             "<meta property='og:description' content='A description'>", "A description"),
            ("common entities decoded", "og:title",
             #"<meta property="og:title" content="Salt &amp; Pepper&#039;s &quot;Diner&quot;">"#,
             "Salt & Pepper's \"Diner\""),
            ("numeric apostrophe variant decoded", "og:title",
             #"<meta property="og:title" content="It&#39;s here">"#, "It's here"),
            ("empty content is nil", "og:title",
             #"<meta property="og:title" content="">"#, nil),
            ("absent property is nil", "og:image",
             #"<meta property="og:title" content="Present">"#, nil),
            ("first matching tag in the document wins", "og:image", twoImages,
             "https://cdn/first.jpg"),
            ("Instagram-style head, title", "og:title", instagramHead, "Login • Instagram"),
            ("Instagram-style head, image", "og:image", instagramHead,
             "https://scontent.cdninstagram.com/v/abc.jpg"),
        ]

        for testCase in cases {
            XCTAssertEqual(
                OpenGraphScraper.ogContent(property: testCase.property, in: testCase.html),
                testCase.expected,
                testCase.name)
        }
    }
}
