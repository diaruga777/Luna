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

    /// New Statesman regression: WordPress puts layout-state classes on <body>
    /// (`sidebar-right has-sidebar`), so the refined layer's `[class*=sidebar]` strip
    /// matched the <body> itself and removed the WHOLE document — the refined layer
    /// returned nothing and the untrimmed `basic` layer won, dragging in the trailing
    /// related-article rail. The strip must skip the page root: the article body is
    /// extracted AND the trailing recirc rail is trimmed.
    func testLayoutClassOnBodyDoesNotDeleteTheDocument() throws {
        let paragraph = "<p>Reported prose continues with enough concrete article detail here to score as the real content container and clear the refined layer's length bar comfortably.</p>"
        let html = """
        <html><body class="single-post sidebar-right has-sidebar wp-theme-figaro">
        <article><h1>The Heading</h1>
        \(String(repeating: paragraph, count: 12))
        </article>
        <section class="c-related"><h2>Related</h2>
        <p><a href="/other-1">Some other article headline over here</a></p>
        <p><a href="/other-2">Yet another unrelated recommended story link</a></p>
        </section>
        </body></html>
        """
        let content = try extractor.extract(html: html, baseURL: baseURL)
        XCTAssertGreaterThan(content.bodyTextLength, ArticleContent.readableBodyThreshold,
                             "the article body must survive a layout class on <body>")
        XCTAssertTrue(content.wholeText.contains("Reported prose continues"))
        XCTAssertFalse(content.wholeText.contains("Related"),
                       "the trailing recirc rail must be trimmed by the refined layer")
        XCTAssertFalse(content.wholeText.contains("recommended story"))
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

    func testRetainsGIFBodyImageAndCanPromoteGIFToLeadImage() throws {
        let gifURL = "https://i0.wp.com/example.com/uploads/motion.gif?resize=800%2C80&ssl=1"
        let html = """
        <html><head><meta property="og:image" content="\(gifURL)"></head>
        <body><article>
        <p>Opening article paragraph with enough text to give the article container a dominant score here.</p>
        <figure><img src="\(gifURL)" width="800" height="180"></figure>
        <p>Closing article paragraph with enough text to keep the article container scoring dominant.</p>
        </article></body></html>
        """

        let content = try extractor.extract(html: html, baseURL: baseURL)
        let images = content.blocks.filter { $0.kind == .image }

        XCTAssertEqual(images.count, 1, "metadata and body copies of the GIF are deduplicated")
        XCTAssertEqual(content.blocks.first?.kind, .image, "the GIF can be the article's lead art")
        XCTAssertEqual(content.blocks.first?.imageURLString, gifURL)
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

    /// Business Insider regression: in-body ad slots were surviving into the reader as
    /// interstitial junk. They use the industry-standard ad vocabulary — a whole-token
    /// `ad` class, `ad-wrapper`/`ad-container`, DFP/Google Ad Manager `data-adunit` and
    /// `div-gpt-ad` ids — none of which the old blocklist matched (it had `advert`,
    /// `taboola`, `sponsor`, but not bare `ad`). The strip is generic, not BI-specific.
    func testStripsInlineAdSlots() throws {
        let html = """
        <html><body><article>
        <p>Real article paragraph with plenty of words so the container scoring stays dominant here.</p>
        <div class="ad ad-wrapper fluid in-post only-mobile"><p>Sponsored ad creative headline you should click right now to buy!</p></div>
        <p>Padding body paragraph with a generous amount of additional words so that the refined extraction layer comfortably clears its minimum substance threshold and the junk stripping behavior under test is actually exercised in full.</p>
        <div class="post-bottom-ad-container" data-adunit="site/post/in-content"><p>Another advertisement block that pretends to be an interesting related product story.</p></div>
        <div id="div-gpt-ad-12345"><p>Google Ad Manager slot creative text that must never reach the reader body.</p></div>
        <p>Another real paragraph of body text that the reader actually cares about reading today.</p>
        </article></body></html>
        """
        let content = try extractor.extract(html: html, baseURL: baseURL)
        XCTAssertFalse(content.wholeText.contains("Sponsored ad creative"))
        XCTAssertFalse(content.wholeText.contains("advertisement block"))
        XCTAssertFalse(content.wholeText.contains("Google Ad Manager slot"))
        XCTAssertTrue(content.wholeText.contains("Real article paragraph"))
        XCTAssertTrue(content.wholeText.contains("Another real paragraph"))
    }

    /// Guard against the classic over-match: a naive `[class*=ad]` would eat all of
    /// these "ad"-substring names, but the token-scoped selector (`[class~=ad]` plus
    /// compound `ad-*`) must leave "headline", "download", "gradient", "shadow",
    /// "thread" alone. (Class names chosen to collide with no other strip selector.)
    func testAdStripDoesNotEatAdLikeWords() throws {
        let html = """
        <html><body><article class="article-body">
        <div class="headline-wrap download-box"><p>This lead reading paragraph has real substance and must be kept in full for the person here.</p></div>
        <div class="gradient-fill shadow-panel thread-summary"><p>Another genuine body paragraph with enough words to matter to the person actually reading this story today.</p></div>
        <p>A third solid paragraph so the container has plenty of dominant real text to score against here.</p>
        </article></body></html>
        """
        let content = try extractor.extract(html: html, baseURL: baseURL)
        XCTAssertTrue(content.wholeText.contains("lead reading paragraph"))
        XCTAssertTrue(content.wholeText.contains("Another genuine body paragraph"))
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

    // MARK: - Trailing-junk stripping (comments, recirc, newsletter, image dumps)

    private func fillerArticleParagraphs(count: Int) -> String {
        (1...count).map { index in
            "<p>Apple is preparing to raise prices on several products as memory supply "
            + "tightens across the industry, paragraph number \(index), with enough sentence "
            + "length to read like genuine reported article prose.</p>"
        }.joined()
    }

    /// A run of ≥2 trailing recirc thumbnails with no strong paragraph after or between
    /// them is trimmed entirely — the hero (from `og:image`) and the real body survive.
    func testTrimsTrailingImageDumpWithNoStrongParagraphAfter() throws {
        let html = """
        <html><head>
        <meta property="og:image" content="https://cdn.example.com/hero.jpg">
        </head><body><article>
        \(fillerArticleParagraphs(count: 6))
        <img src="/recirc/thumb1.jpg" width="300" height="200" />
        <img src="/recirc/thumb2.jpg" width="300" height="200" />
        <img src="/recirc/thumb3.jpg" width="300" height="200" />
        </article></body></html>
        """
        let content = try extractor.extract(html: html, baseURL: baseURL)
        let images = content.blocks.filter { $0.kind == .image }
        XCTAssertEqual(images.count, 1, "trailing image dump should be trimmed, keeping only the hero")
        XCTAssertEqual(images.first?.imageURLString, "https://cdn.example.com/hero.jpg")
        XCTAssertTrue(content.wholeText.contains("paragraph number 6"), "real body should survive")
    }

    /// A single trailing image immediately preceded by a strong paragraph is a legit
    /// closing photo — it must NOT be swept by the image-dump rule.
    func testKeepsLoneClosingPhotoAfterFinalStrongParagraph() throws {
        let html = """
        <html><body><article>
        \(fillerArticleParagraphs(count: 6))
        <img src="/photos/closing-shot.jpg" width="800" height="600" />
        </article></body></html>
        """
        let content = try extractor.extract(html: html, baseURL: baseURL)
        let images = content.blocks.filter { $0.kind == .image }
        XCTAssertEqual(images.count, 1, "lone closing photo should be kept")
        XCTAssertEqual(images.first?.imageURLString, "https://example.com/photos/closing-shot.jpg")
        XCTAssertTrue(content.wholeText.contains("paragraph number 6"))
    }

    /// A "Related Articles" heading followed by a link list + thumbnails, with no
    /// strong paragraph after it, is a recirc rail — the terminator hard stop (or the
    /// reverse trim / conditional list cleaning backing it up) removes all of it.
    func testRelatedArticlesHeadingTruncatesLinkListAndThumbnails() throws {
        let html = """
        <html><body><article>
        \(fillerArticleParagraphs(count: 6))
        <h2>Related Articles</h2>
        <ul>
        <li><a href="/a">Some other unrelated story headline here</a></li>
        <li><a href="/b">Another completely different unrelated story headline</a></li>
        </ul>
        <img src="/thumbs/a.jpg" width="200" height="150" />
        <img src="/thumbs/b.jpg" width="200" height="150" />
        </article></body></html>
        """
        let content = try extractor.extract(html: html, baseURL: baseURL)
        XCTAssertFalse(content.wholeText.contains("Related Articles"))
        XCTAssertFalse(content.wholeText.contains("Some other unrelated story"))
        XCTAssertTrue(content.blocks.filter { $0.kind == .image }.isEmpty)
        XCTAssertTrue(content.wholeText.contains("paragraph number 6"))
    }

    /// A short "12 Comments" line followed by plain-text comment paragraphs (no
    /// comment classes at all) after substantial body text is a comment thread — the
    /// terminator hard stop truncates it even though nothing marks it as a comment
    /// except the count phrase itself.
    func testCommentCountTerminatorTruncatesPlainTextCommentThread() throws {
        let commentParagraphs = (1...5).map { index in
            "<p>Reader comment \(index): I disagree with this take and here is my opinion "
            + "about pricing.</p>"
        }.joined()
        let html = """
        <html><body><article>
        \(fillerArticleParagraphs(count: 6))
        <p>12 Comments</p>
        \(commentParagraphs)
        </article></body></html>
        """
        let content = try extractor.extract(html: html, baseURL: baseURL)
        XCTAssertFalse(content.wholeText.contains("12 Comments"))
        XCTAssertFalse(content.wholeText.contains("Reader comment"))
        XCTAssertTrue(content.wholeText.contains("paragraph number 6"))
    }

    /// A mid-article single-line recirc teaser ("Related: <link>") is dropped in
    /// place — it must NOT truncate the rest of the article the way an end-of-article
    /// terminator would.
    func testMidArticleRecircLineRemovedWithoutTruncatingArticle() throws {
        let html = """
        <html><body><article>
        <p>Apple is preparing to raise prices on several products as memory supply tightens across the industry, paragraph number 1, with enough sentence length to read like genuine reported article prose.</p>
        <p>Related: <a href="/other-story">Some unrelated headline elsewhere on the site</a></p>
        <p>Apple is preparing to raise prices on several products as memory supply tightens across the industry, paragraph number 2, with enough sentence length to read like genuine reported article prose.</p>
        <p>Apple is preparing to raise prices on several products as memory supply tightens across the industry, paragraph number 3, with enough sentence length to read like genuine reported article prose.</p>
        </article></body></html>
        """
        let content = try extractor.extract(html: html, baseURL: baseURL)
        XCTAssertFalse(content.wholeText.contains("Related:"))
        XCTAssertFalse(content.wholeText.contains("Some unrelated headline"))
        XCTAssertTrue(content.wholeText.contains("paragraph number 1"))
        XCTAssertTrue(content.wholeText.contains("paragraph number 2"))
        XCTAssertTrue(content.wholeText.contains("paragraph number 3"), "article must not be truncated")
    }

    /// A legit editorial `<ul>` whose items are long non-link prose with only an
    /// occasional inline link must survive the conditional list-density cleaning —
    /// only near-pure link farms are removed.
    func testEditorialListWithLongLiTextSurvivesConditionalCleaning() throws {
        let html = """
        <html><body><article>
        \(fillerArticleParagraphs(count: 3))
        <ul>
        <li>The company's pricing committee weighed three separate proposals before settling on a phased rollout that begins with premium configurations and expands to the base lineup by <a href="/schedule">next quarter</a>.</li>
        <li>Analysts who reviewed the leaked schedule say the delay reflects supply constraints rather than a change in strategy, according to <a href="/analysts">people familiar with the matter</a>.</li>
        </ul>
        <p>Apple is preparing to raise prices on several products as memory supply tightens across the industry, paragraph number 4, with enough sentence length to read like genuine reported article prose.</p>
        </article></body></html>
        """
        let content = try extractor.extract(html: html, baseURL: baseURL)
        XCTAssertTrue(content.wholeText.contains("pricing committee weighed three separate proposals"))
        XCTAssertTrue(content.wholeText.contains("Analysts who reviewed the leaked schedule"))
        XCTAssertEqual(content.blocks.filter { $0.kind == .listItem }.count, 2)
    }
}
