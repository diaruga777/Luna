//
//  ArticleExtractorTests.swift
//  LunaTests
//

import LunaHTMLClassification
import LunaModels
import XCTest
@testable import Luna

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
        XCTAssertEqual(images.first?.imageWidth, 1600)
        XCTAssertEqual(images.first?.imageHeight, 900)
    }

    func testPrependsMetadataHeroImageAndUsesLazyResponsiveBodyImages() throws {
        let html = """
        <html><head>
        <meta property="og:image:secure_url" content="https://cdn.example.com/header.webp">
        </head><body><article>
        <p>Opening article paragraph with enough text to give the article container a dominant score here.</p>
        <figure><img src="data:image/gif;base64,placeholder" data-srcset="/body-small.jpg 640w, /body-large.jpg 1600w"></figure>
        <p>Closing article paragraph with enough text to keep the article container scoring dominant.</p>
        </article></body></html>
        """

        let content = try extractor.extract(html: html, baseURL: baseURL)
        let images = content.blocks.filter { $0.kind == .image }
        XCTAssertEqual(images.map(\.imageURLString), [
            "https://cdn.example.com/header.webp",
            "https://example.com/body-large.jpg",
        ])
    }

    func testPrependsJSONLDHeroWhenOpenGraphImageIsAbsent() throws {
        let html = """
        <html><head><script type="application/ld+json">
        {"@type":"NewsArticle","image":{"url":"/images/hero.jpg"}}
        </script></head><body><article>
        <p>Opening article paragraph with enough text to give the article container a dominant score here.</p>
        <p>Closing article paragraph with enough text to keep the article container scoring dominant.</p>
        </article></body></html>
        """
        let content = try extractor.extract(html: html, baseURL: baseURL)
        XCTAssertEqual(content.blocks.first?.kind, .image)
        XCTAssertEqual(content.blocks.first?.imageURLString, "https://example.com/images/hero.jpg")
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

    /// An archived WSJ snapshot ships the real article body alongside a
    /// subscription gate and a long reader-comments thread. The comment thread
    /// holds far more `<p>` text than the article, so the old layer choice fell
    /// back to the unstripped `basic` pass and surfaced gate + comments instead
    /// of the story. The body must win.
    func testArchivedArticleBeatsSubscriptionGateAndComments() throws {
        let articleParagraphs = (1...8).map { index in
            "<p>Apple is preparing to raise prices on several products as memory "
            + "supply tightens across the industry, paragraph number \(index), with "
            + "enough sentence length to read like genuine reported article prose.</p>"
        }.joined()

        // A comment thread far larger than the article body — this is what used
        // to win container scoring and the layer choice.
        let commentParagraphs = (1...60).map { index in
            "<p>Reader comment \(index): I totally disagree with this take and here "
            + "is my long-winded opinion about pricing, supply chains, and the economy.</p>"
        }.joined()

        let html = """
        <html><head><title>Apple Price Increases</title>
        <meta property="og:title" content="Apple Plans Price Increases as Memory Supply Tightens" /></head>
        <body>
        <div class="paywall subscribe-cta"><p>Subscribe to read. Unlimited access for $4 a month. Already a subscriber? Sign In to continue reading this article now.</p></div>
        <article><div itemprop="articleBody">\(articleParagraphs)</div></article>
        <section class="comments-section"><h2>Conversation</h2>\(commentParagraphs)</section>
        </body></html>
        """
        let content = try extractor.extract(html: html, baseURL: baseURL)
        XCTAssertTrue(content.wholeText.contains("Apple is preparing to raise prices"),
                      "article body was dropped")
        XCTAssertFalse(content.wholeText.contains("Reader comment"),
                       "comment thread leaked into extraction")
        XCTAssertFalse(content.wholeText.contains("Subscribe to read"),
                       "subscription gate leaked into extraction")
    }

    /// WSJ's browser-unlocked article can keep the real body inside an element whose
    /// class still says `paywall` / `PaywalledContent`. That wrapper is not a gate
    /// anymore; stripping it leaves only the free intro and nearby author bios.
    func testUnlockedWSJPaywalledContentWrapperIsKept() throws {
        let intro = """
        <p>The dispute over how to tame artificial intelligence has moved into a new phase,
        with researchers, courts and companies all drawing fresh boundaries.</p>
        <p>The first skirmish is over, but the larger fight about AI safety is accelerating.</p>
        """
        let paywalledBody = (1...9).map { index in
            "<p>Inside the unlocked article body paragraph \(index), policy makers and "
            + "engineers describe concrete tradeoffs in governing powerful AI systems "
            + "while preserving enough detail to read like real reported prose.</p>"
        }.joined()
        let authorBios = (1...5).map { index in
            "<p>Author bio \(index): This reporter covers technology companies and "
            + "regulatory debates for the newsroom.</p>"
        }.joined()
        let html = """
        <html><head><title>AI Policy Fight</title></head><body>
        <article>
          <h1>The Anthropic Fable Ban Is Over</h1>
          <div class="article-container">
            \(intro)
            <div class="paywall css-1u1nl00-PaywalledContent">\(paywalledBody)</div>
          </div>
        </article>
        <div class="AuthorModule css-authors">\(authorBios)</div>
        </body></html>
        """

        let content = try extractor.extract(html: html, baseURL: URL(string: "https://www.wsj.com/tech/ai/story")!)
        XCTAssertTrue(content.wholeText.contains("Inside the unlocked article body paragraph 9"),
                      "unlocked WSJ body was stripped as paywall junk")
        XCTAssertGreaterThan(content.bodyTextLength, ArticleContent.readableBodyThreshold)
        XCTAssertFalse(content.wholeText.contains("Author bio"),
                       "author boilerplate should not replace or trail the article body")
    }

    /// archive.today rewrites the captured page so every body paragraph is a
    /// styled `<div>` (no `<p>` at all), and an embedded video player ships its
    /// chrome — timecodes, "Up Next", an aria-live "Playing" label, sr-only
    /// captions — as short text divs. The extractor must read the div-based body
    /// and reject the player chrome / hidden labels.
    func testDivBasedArticleBodyExtractedWithoutPlayerChrome() throws {
        let bodyDivs = (1...6).map { index in
            "<div style=\"display:block\">Apple plans to raise product prices to offset "
            + "surging memory and storage costs, body paragraph number \(index), written "
            + "as a full sentence of genuine reported article prose worth reading.</div>"
        }.joined()

        let html = """
        <html><head><title>Apple Price Increases</title>
        <meta property="og:title" content="Apple Price Increases Unavoidable, Tim Cook Says" /></head>
        <body>
        <div id="video-player-wrapper">
          <div aria-live="polite" style="clip:rect(1px, 1px, 1px, 1px);height:1px;width:1px;position:absolute;">Playing</div>
          <div>0:00</div><div>0:00 / 2:33</div><div>Up Next</div><div>You may also like</div>
        </div>
        <div style="display:block">\(bodyDivs)</div>
        <div aria-live="polite" style="position:absolute;clip:rect(1px, 1px, 1px, 1px);">Embed code copied to clipboard</div>
        </body></html>
        """
        let content = try extractor.extract(html: html, baseURL: baseURL)
        XCTAssertTrue(content.wholeText.contains("Apple plans to raise product prices"),
                      "div-based article body was dropped")
        XCTAssertGreaterThan(content.wholeText.count, 600, "body under-extracted")
        for chrome in ["0:00", "Playing", "Up Next", "You may also like", "Embed code"] {
            XCTAssertFalse(content.wholeText.contains(chrome), "player/hidden chrome leaked: \(chrome)")
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
