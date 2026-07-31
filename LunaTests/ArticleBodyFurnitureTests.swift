//
//  ArticleBodyFurnitureTests.swift
//  LunaTests
//

import LunaHTMLClassification
import LunaModels
import XCTest

/// Two things a NY Post save kept that are not article body — a self-labelling ad
/// slot and an "Explore More" card rail — plus the false positives each rule must
/// not introduce. Both leaked through ONE root cause: `[class*=sidebar]` matching
/// the two-column layout wrapper `<div class="layout layout--sidebar">` that HOLDS
/// the article, which zeroed the refined layer (13 chars survived) and handed the
/// win to `basic`, the layer that does no junk trimming at all.
final class ArticleBodyFurnitureTests: XCTestCase {

    private let extractor = ArticleExtractor()
    private let baseURL = URL(string: "https://nypost.com/2026/07/31/business/story/")! // valid constant URL

    /// A body paragraph, long enough to count toward container scoring.
    private func prose(_ index: Int) -> String {
        """
        <p>Reported paragraph number \(index) carries enough concrete detail about the \
        feud between the two prediction markets to score as real article content.</p>
        """
    }

    /// NY Post's page, reduced to the shapes that mattered: the layout wrapper whose
    /// class names the sidebar it makes room for, an ad slot that labels itself, and
    /// an "Explore More" card rail dropped between two body paragraphs.
    private func nyPostShapedHTML() -> String {
        """
        <html><head><meta property="og:title" content="The vicious battle"></head><body>
        <div class="layout layout--sidebar">
          <div class="layout__grid">
            <div class="layout__item layout__item--main">
              <div class="single__content entry-content">
                \(prose(1))
                \(prose(2))
                <figure>
                  <a href="/photo"><img src="/hero.jpg" width="1024" height="683"></a>
                  <figcaption>Shayne Coplan has feuded for years with the co-founders of
                  arch-rival Kalshi. <span class="credit">Zuffa LLC</span></figcaption>
                </figure>
                <div class="ad ad--container ad--inline">
                  <div class="ad__wrapper">
                    <p class="ad__label ad__label--top">Advertisement</p>
                  </div>
                </div>
                \(prose(3))
                <div class="in-line-column wp-caption alignleft">
                  <div class="inline-module inline-module--more inline-module--explore">
                    <h2 class="inline-module__heading">Explore More</h2>
                    <h3><a href="https://nypost.com/2026/07/30/business/jersey-mikes/">Jersey
                    Mike's shares fall in hyped NYSE debut as Danny DeVito rings the bell</a></h3>
                    <h3><a href="https://nypost.com/2026/07/30/business/amazon-refunds/">Amazon
                    customers to receive Trump tariff refunds after payout</a></h3>
                    <h3><a href="https://nypost.com/2026/07/29/business/short-sellers/">Short
                    sellers have made a fortune betting against SpaceX</a></h3>
                  </div>
                </div>
                \(prose(4))
                \(prose(5))
                \(prose(6))
              </div>
            </div>
            <div class="layout__item layout__item--sidebar">
              <aside><p>Sidebar rail promoting a completely different section entirely.</p></aside>
            </div>
          </div>
        </div>
        </body></html>
        """
    }

    // MARK: - Root cause

    /// The regression that produced all three glitches: a grid wrapper naming the
    /// column it lays out beside the story is layout, not junk.
    func testLayoutWrapperNamingASidebarDoesNotDeleteTheArticle() throws {
        let content = try extractor.extract(html: nyPostShapedHTML(), baseURL: baseURL)
        XCTAssertEqual(content.blocks.filter { $0.text.hasPrefix("Reported paragraph") }.count, 6,
                       "every body paragraph must survive the layout wrapper's `sidebar` class")
        XCTAssertFalse(content.wholeText.contains("Sidebar rail"),
                       "sparing the WRAPPER must not spare the sidebar inside it")
    }

    // MARK: - Ad labels

    func testAdSlotLabelIsRemoved() throws {
        let content = try extractor.extract(html: nyPostShapedHTML(), baseURL: baseURL)
        XCTAssertFalse(content.blocks.contains { $0.text == "Advertisement" })
    }

    /// The label rule matches a block's WHOLE text, so prose that merely discusses
    /// advertising is untouched.
    func testProseAboutAdvertisingSurvivesTheAdLabelRule() throws {
        let sentence = "The company's advertisement spend tripled last year, according to two "
            + "people familiar with its media buying, and the sponsored content it commissioned "
            + "ran across four networks before the campaign was quietly shelved in March."
        let html = """
        <html><body><article>
        \(String(repeating: prose(1), count: 8))
        <p>\(sentence)</p>
        </article></body></html>
        """
        let content = try extractor.extract(html: html, baseURL: baseURL)
        XCTAssertTrue(content.wholeText.contains("advertisement spend tripled"))
    }

    /// An ad label is never article content in ANY layer, so it must also go on a
    /// page where `basic` wins arbitration (here the refined layer is starved by a
    /// junk class sitting directly on the only content container).
    func testAdLabelIsRemovedEvenWhenTheBasicLayerWins() throws {
        let html = """
        <html><body>
        <div class="promo-wrapper">
        \(String(repeating: prose(1), count: 3))
        <p>Advertisement</p>
        \(String(repeating: prose(2), count: 3))
        </div>
        </body></html>
        """
        let content = try extractor.extract(html: html, baseURL: baseURL)
        XCTAssertGreaterThan(content.bodyTextLength, 600, "the body must still be extracted")
        XCTAssertFalse(content.blocks.contains { $0.text == "Advertisement" })
    }

    // MARK: - In-body recirc modules

    func testExploreMoreCardRailIsRemovedInPlace() throws {
        let content = try extractor.extract(html: nyPostShapedHTML(), baseURL: baseURL)
        XCTAssertFalse(content.wholeText.contains("Explore More"))
        XCTAssertFalse(content.wholeText.contains("Jersey Mike"))
        XCTAssertFalse(content.wholeText.contains("tariff refunds"))
        XCTAssertFalse(content.wholeText.contains("SpaceX"))
        XCTAssertEqual(content.blocks.filter { $0.text.hasPrefix("Reported paragraph") }.count, 6,
                       "the rail sits mid-article: what follows it must NOT be truncated")
    }

    /// The shape rule, not the class name — a rail a site names something the strip
    /// has never heard of is still recognised by being all-hyperlink.
    func testUnrecognisedRecircRailIsStillRemovedByShape() throws {
        let html = """
        <html><body><article>
        \(String(repeating: prose(1), count: 6))
        <div class="nyp-widget-4487">
          <h2>More from Business</h2>
          <h3><a href="https://nypost.com/a/">One neighbouring headline about a merger</a></h3>
          <h3><a href="https://nypost.com/b/">Another neighbouring headline about a filing</a></h3>
        </div>
        \(String(repeating: prose(2), count: 6))
        </article></body></html>
        """
        let content = try extractor.extract(html: html, baseURL: baseURL)
        XCTAssertFalse(content.wholeText.contains("More from Business"))
        XCTAssertFalse(content.wholeText.contains("neighbouring headline"))
        XCTAssertEqual(content.blocks.filter { $0.text.hasPrefix("Reported paragraph") }.count, 12)
    }

    /// A genuine link roundup — every item IS a linked heading, followed by the
    /// author's own prose — is the false positive this rule must not create. Each
    /// linked heading stands alone (run of one) and carries no recirc label, so
    /// both gates fail and the article keeps its structure.
    func testLinkRoundupArticleKeepsItsLinkedHeadings() throws {
        let html = """
        <html><body><article>
        <h1>Five things worth reading this week</h1>
        <h2><a href="https://example.org/one">A history of the shipping container</a></h2>
        <p>Marc's argument here is that standardisation, not scale, is what collapsed the
        cost of moving goods, and he makes it with a patience that the subject rewards.</p>
        <h2><a href="https://example.org/two">The last analogue telephone exchange</a></h2>
        <p>A quiet piece of reporting about the two engineers who still maintain a switch
        that nobody else on the continent knows how to repair, and what happens after.</p>
        <h2><a href="https://example.org/three">Why nobody finishes a crossword</a></h2>
        <p>A statistician takes eleven years of solve data and finds the exact clue at
        which most people give up, which turns out to be far earlier than anyone assumed.</p>
        </article></body></html>
        """
        let content = try extractor.extract(html: html, baseURL: baseURL)
        XCTAssertEqual(content.blocks.filter { $0.kind == .heading }.count, 4,
                       "a roundup's linked headings are content, not a rail")
        XCTAssertTrue(content.wholeText.contains("shipping container"))
        XCTAssertTrue(content.wholeText.contains("analogue telephone exchange"))
    }

    /// A blog whose section headings link to their own permalink anchor looks
    /// fully-linked but is in-page navigation, which the rule excludes outright.
    func testSelfAnchoredSectionHeadingsAreKept() throws {
        let html = """
        <html><body><article>
        <h2 id="one"><a href="#one">The first section</a></h2>
        <h2 id="two"><a href="#two">The second section</a></h2>
        \(String(repeating: prose(1), count: 8))
        </article></body></html>
        """
        let content = try extractor.extract(html: html, baseURL: baseURL)
        XCTAssertTrue(content.wholeText.contains("The first section"))
        XCTAssertTrue(content.wholeText.contains("The second section"))
    }

    /// A recirc LABEL alone must not truncate or remove anything: a genuine
    /// "Related" subheading introducing more prose keeps the prose AND the heading.
    func testRecircLabelWithoutALinkRunIsKept() throws {
        let html = """
        <html><body><article>
        \(String(repeating: prose(1), count: 6))
        <h2>Related</h2>
        <p>The dispute also reaches into a second market, where both firms have filed for
        the same category of licence and neither will say which regulator moved first.</p>
        \(String(repeating: prose(2), count: 4))
        </article></body></html>
        """
        let content = try extractor.extract(html: html, baseURL: baseURL)
        XCTAssertTrue(content.wholeText.contains("Related"))
        XCTAssertTrue(content.wholeText.contains("second market"))
        XCTAssertEqual(content.blocks.filter { $0.text.hasPrefix("Reported paragraph") }.count, 10)
    }
}
