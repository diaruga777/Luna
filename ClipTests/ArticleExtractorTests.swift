//
//  ArticleExtractorTests.swift
//  ClipTests
//

import XCTest
@testable import Clip

final class ArticleExtractorTests: XCTestCase {

    private let extractor = ArticleExtractor()
    private let baseURL = URL(string: "https://example.com/article")! // valid constant URL

    func testExtractsTitleAndParagraphs() throws {
        let html = """
        <html><head><title>Page Title</title>
        <meta property="og:title" content="OG Title" /></head>
        <body>
        <nav><p>Menu item that should be stripped from output entirely</p></nav>
        <article>
        <h1>The Heading</h1>
        <p>First paragraph with enough text to be counted as real content for scoring purposes here.</p>
        <p>Second paragraph, also with a reasonable amount of text so the container scoring works well.</p>
        <p>Third paragraph to push the article container score safely past any other candidate parent.</p>
        </article>
        <footer><p>Footer junk</p></footer>
        </body></html>
        """
        let content = try extractor.extract(html: html, baseURL: baseURL)
        XCTAssertEqual(content.title, "OG Title")
        XCTAssertTrue(content.blocks.contains { $0.kind == .heading && $0.text == "The Heading" })
        XCTAssertTrue(content.blocks.contains { $0.text.hasPrefix("First paragraph") })
        XCTAssertFalse(content.wholeText.contains("Menu item"))
        XCTAssertFalse(content.wholeText.contains("Footer junk"))
    }

    func testPreservesInlineLinksWithCorrectRanges() throws {
        let html = """
        <html><body><article>
        <p>Start text <a href="/relative">link text</a> end text. Padding padding padding padding padding padding padding padding padding padding padding padding padding padding padding padding.</p>
        <p>More filler so the article wins container scoring against body and html elements easily.</p>
        <p>Even more filler text here to make sure scores are dominated by this article container.</p>
        </article></body></html>
        """
        let content = try extractor.extract(html: html, baseURL: baseURL)
        let block = try XCTUnwrap(content.blocks.first { !$0.links.isEmpty })
        let link = block.links[0]
        XCTAssertEqual(link.urlString, "https://example.com/relative")
        let nsText = block.text as NSString
        XCTAssertEqual(nsText.substring(with: NSRange(location: link.start, length: link.length)), "link text")
    }

    func testCollapsesWhitespace() throws {
        let html = """
        <html><body><article>
        <p>Words   separated
            by    lots of
            whitespace should collapse to single spaces in the final extracted output text.</p>
        <p>Second filler paragraph so the container scoring picks the article element reliably.</p>
        <p>Third filler paragraph so the container scoring picks the article element reliably too.</p>
        </article></body></html>
        """
        let content = try extractor.extract(html: html, baseURL: baseURL)
        let first = try XCTUnwrap(content.blocks.first)
        XCTAssertTrue(first.text.hasPrefix("Words separated by lots of whitespace"))
        XCTAssertFalse(first.text.contains("  "))
    }

    func testExtractsArticleImagesAndFiltersJunk() throws {
        let html = """
        <html><body><article>
        <p>Intro paragraph with plenty of words to give the article container a dominant score here.</p>
        <p><img src="/wp-content/uploads/hero-photo.png" width="1600" height="900" /></p>
        <img src="https://adsystem.example.com/ads/banner.png" width="970" height="250" />
        <img src="/wp-content/uploads/tiny-glyph.png" width="32" height="32" />
        <img src="https://metrics.example.com/pixel.gif" />
        <p>Closing paragraph with plenty of words to keep the article container scoring dominant.</p>
        </article></body></html>
        """
        let content = try extractor.extract(html: html, baseURL: baseURL)
        let images = content.blocks.filter { $0.kind == .image }
        XCTAssertEqual(images.count, 1)
        XCTAssertEqual(images.first?.imageURLString, "https://example.com/wp-content/uploads/hero-photo.png")
    }

    func testStripsTrailingLinkFarmsAndFooterBoilerplate() throws {
        let html = """
        <html><head><meta name="author" content="Jane Writer" /></head><body><article>
        <p>Real article paragraph with plenty of words so the container scoring stays dominant here.</p>
        <p>Padding body paragraph with a generous amount of additional words so that the refined extraction layer comfortably clears its minimum substance threshold and the junk stripping behavior under test is actually exercised.</p>
        <p>Another real paragraph of body text that the reader actually cares about reading today.</p>
        <ul>
        <li><a href="/a">Company</a> <a href="/b">Careers</a> <a href="/c">Press</a></li>
        <li><a href="/d">Twitter</a> <a href="/e">Facebook</a> <a href="/f">Instagram</a></li>
        </ul>
        <p>© 2026 Example Corp. All rights reserved.</p>
        </article></body></html>
        """
        let content = try extractor.extract(html: html, baseURL: baseURL)
        XCTAssertEqual(content.author, "Jane Writer")
        XCTAssertFalse(content.wholeText.contains("All rights reserved"))
        XCTAssertFalse(content.wholeText.contains("Instagram"))
        XCTAssertTrue(content.wholeText.contains("Another real paragraph"))
    }

    func testStripsJunkByClass() throws {
        let html = """
        <html><body><article>
        <p>Real article paragraph with plenty of words so the container scoring stays dominant here.</p>
        <p>Padding body paragraph with a generous amount of additional words so that the refined extraction layer comfortably clears its minimum substance threshold and the junk stripping behavior under test is actually exercised.</p>
        <div class="social-share-bar"><p>Share this article on your favorite social platform now!</p></div>
        <div class="related-posts"><p>You might also like these other stories from our archive!</p></div>
        <p>Another real paragraph of body text that the reader actually cares about reading today.</p>
        </article></body></html>
        """
        let content = try extractor.extract(html: html, baseURL: baseURL)
        XCTAssertFalse(content.wholeText.contains("Share this article"))
        XCTAssertFalse(content.wholeText.contains("You might also like"))
        XCTAssertTrue(content.wholeText.contains("Another real paragraph"))
    }

    /// Real-page smoke test: parses saved copies of actual news pages when the
    /// fixtures are present on the host (skipped otherwise, e.g. in CI).
    func testExtractsRealWorldFixtures() throws {
        // path: minimum plausible extracted length for that page.
        let fixtures = [
            ("/tmp/fixture-verge.html", 500),
            ("/tmp/fixture-ars.html", 500),
            ("/tmp/fixture-int.html", 4000),
        ]
        for (path, minimum) in fixtures {
            guard let html = try? String(contentsOfFile: path, encoding: .utf8) else {
                continue
            }
            do {
                let content = try extractor.extract(html: html, baseURL: baseURL)
                XCTAssertGreaterThan(
                    content.wholeText.count, minimum,
                    "thin extraction for \(path): got \(content.wholeText.count)")
            } catch {
                XCTFail("extraction threw for \(path): \(error)")
            }
        }
    }

    func testThrowsOnEmptyDocument() {
        XCTAssertThrowsError(try extractor.extract(html: "<html><body></body></html>", baseURL: baseURL))
    }

    func testListAndQuoteKinds() throws {
        let html = """
        <html><body><article>
        <p>Intro paragraph with plenty of words to give the article container a dominant score here.</p>
        <blockquote>A quoted passage of text.</blockquote>
        <ul><li>First bullet item</li><li>Second bullet item</li></ul>
        <p>Closing paragraph with plenty of words to keep the article container scoring dominant.</p>
        </article></body></html>
        """
        let content = try extractor.extract(html: html, baseURL: baseURL)
        XCTAssertTrue(content.blocks.contains { $0.kind == .quote && $0.text == "A quoted passage of text." })
        XCTAssertEqual(content.blocks.filter { $0.kind == .listItem }.count, 2)
    }
}
