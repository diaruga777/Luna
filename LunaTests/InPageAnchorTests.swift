//
//  InPageAnchorTests.swift
//  LunaTests
//

import LunaHTMLClassification
import LunaModels
import XCTest

/// The page's own chapter marks. A `#fragment` table of contents has to survive
/// extraction at all (the junk passes delete link-dense lists and `<nav>`s
/// outright), its rows have to point at real destination blocks, and — because a
/// false positive turns prose into furniture the RSVP reader skips — the shapes
/// that merely resemble a ToC must keep being treated as ordinary content.
final class InPageAnchorTests: XCTestCase {

    private let extractor = ArticleExtractor()
    private let baseURL = URL(string: "https://blog.example.com/posts/long-entry")!

    private func extract(_ html: String) throws -> ArticleContent {
        try extractor.extract(html: html, baseURL: baseURL)
    }

    /// Enough prose that the refined layer wins arbitration outright, as it does
    /// on a real long blog entry.
    private func prose(_ marker: String, sentences: Int = 6) -> String {
        (0..<sentences)
            .map { "Paragraph \(marker) sentence \($0) carries enough reported detail to read as real body prose." }
            .joined(separator: " ")
    }

    private func tocRows(_ content: ArticleContent) -> [ArticleContent.Block] {
        content.blocks.filter { $0.kind == .tableOfContents }
    }

    /// The shape a long blog entry uses: a labelled `<nav>` holding a two-level
    /// list of same-page links.
    private func blogEntryHTML() -> String {
        """
        <html><head><title>A Long Entry</title></head><body>
        <article>
          <h1>A Long Entry</h1>
          <nav class="toc">
            <h2>Table of contents</h2>
            <ul>
              <li><a href="#beginnings">Beginnings</a></li>
              <li><a href="#the-middle">The middle</a>
                <ul><li><a href="#a-digression">A digression</a></li></ul>
              </li>
              <li><a href="#ending">Ending</a></li>
            </ul>
          </nav>
          <h2 id="beginnings">Beginnings</h2>
          <p>\(prose("one"))</p>
          <h2 id="the-middle">The middle</h2>
          <p>\(prose("two"))</p>
          <h3 id="a-digression">A digression</h3>
          <p>\(prose("three"))</p>
          <h2 id="ending">Ending</h2>
          <p>\(prose("four"))</p>
        </article>
        </body></html>
        """
    }

    // MARK: - The common blog shape

    func testPreservesInPageTableOfContentsAsItsOwnBlockKind() throws {
        let rows = tocRows(try extract(blogEntryHTML()))
        // The label plus one row per jump — including the nested sub-entry, which
        // the generic `<li>` walk would have folded into its parent's bullet.
        XCTAssertEqual(
            rows.map(\.text),
            ["Table of contents", "Beginnings", "The middle", "A digression", "Ending"])
        XCTAssertEqual(rows.first?.links.count, 0)
        XCTAssertEqual(
            rows.dropFirst().compactMap { $0.links.first?.anchorID },
            ["beginnings", "the-middle", "a-digression", "ending"])
    }

    func testEveryTableOfContentsRowResolvesToADestinationBlock() throws {
        let content = try extract(blogEntryHTML())
        let rows = tocRows(content).filter { !$0.links.isEmpty }
        XCTAssertEqual(rows.count, 4)
        for row in rows {
            let anchorID = try XCTUnwrap(row.links.first?.anchorID)
            let destination = try XCTUnwrap(content.blockIndex(forAnchorID: anchorID))
            XCTAssertEqual(content.blocks[destination].kind, .heading)
        }
    }

    func testDestinationHeadingsCarryTheirAnchorAndProseDoesNot() throws {
        let content = try extract(blogEntryHTML())
        let anchored = content.blocks.filter { $0.anchorID != nil }
        XCTAssertEqual(anchored.count, 4)
        XCTAssertTrue(anchored.allSatisfy { $0.kind == .heading })
        XCTAssertTrue(content.blocks.filter { $0.kind == .paragraph }.allSatisfy { $0.anchorID == nil })
    }

    /// The ToC renders but is never read: RSVP, `WordMap` and read-aloud all key
    /// off this one predicate, so it must hold for every row.
    func testTableOfContentsIsNotPartOfTheWordStream() throws {
        let content = try extract(blogEntryHTML())
        XCTAssertFalse(tocRows(content).isEmpty)
        XCTAssertTrue(tocRows(content).allSatisfy { !$0.isReadableProse })
        XCTAssertTrue(
            content.blocks.filter { $0.kind != .tableOfContents }.allSatisfy(\.isReadableProse))
    }

    /// Crawling an in-page jump would refetch this very article.
    func testInPageJumpsAreNotOutboundLinks() throws {
        XCTAssertTrue(try extract(blogEntryHTML()).outboundURLs.isEmpty)
    }

    func testBareListWithoutAWrapperIsAlsoRecognized() throws {
        let html = """
        <html><body><article>
          <h1>Story</h1>
          <ul>
            <li><a href="#one">One</a></li>
            <li><a href="#two">Two</a></li>
            <li><a href="#three">Three</a></li>
          </ul>
          <h2 id="one">One</h2><p>\(prose("one"))</p>
          <h2 id="two">Two</h2><p>\(prose("two"))</p>
          <h2 id="three">Three</h2><p>\(prose("three"))</p>
        </article></body></html>
        """
        let content = try extract(html)
        XCTAssertEqual(tocRows(content).map(\.text), ["One", "Two", "Three"])
    }

    // MARK: - Shapes that must NOT become chapter marks

    func testRelatedArticlesRailIsStillStripped() throws {
        let html = """
        <html><body><article>
          <h1>Story</h1>
          <p>\(prose("body", sentences: 10))</p>
          <ul class="related">
            <li><a href="https://blog.example.com/other-one">Other one</a></li>
            <li><a href="https://blog.example.com/other-two">Other two</a></li>
            <li><a href="https://blog.example.com/other-three">Other three</a></li>
          </ul>
        </article></body></html>
        """
        let content = try extract(html)
        XCTAssertTrue(tocRows(content).isEmpty)
        XCTAssertFalse(content.wholeText.contains("Other one"))
    }

    func testATwoLinkJumpBarIsNotATableOfContents() throws {
        let html = """
        <html><body><article>
          <h1>Recipe</h1>
          <div class="jump-links">
            <a href="#recipe">Jump to recipe</a>
            <a href="#notes">Jump to notes</a>
          </div>
          <p>\(prose("intro", sentences: 10))</p>
          <h2 id="recipe">The recipe</h2><p>\(prose("recipe", sentences: 8))</p>
          <h2 id="notes">Notes</h2><p>\(prose("notes", sentences: 8))</p>
        </article></body></html>
        """
        let content = try extract(html)
        XCTAssertTrue(tocRows(content).isEmpty)
        // Still in-page jumps, though — resolution is per link; only the ToC
        // itself needs a quorum.
        let bar = try XCTUnwrap(content.blocks.first { $0.links.count == 2 })
        XCTAssertTrue(bar.links.allSatisfy(\.isInPageAnchor))
    }

    func testProsePepperedWithFootnoteMarkersIsNotATableOfContents() throws {
        let html = """
        <html><body><article>
          <h1>Story</h1>
          <p>\(prose("body", sentences: 8)) <a href="#fn1">1</a> and more of it
             <a href="#fn2">2</a> and still more <a href="#fn3">3</a>.</p>
          <h2>Notes</h2>
          <p id="fn1">\(prose("first note"))</p>
          <p id="fn2">\(prose("second note"))</p>
          <p id="fn3">\(prose("third note"))</p>
        </article></body></html>
        """
        let content = try extract(html)
        XCTAssertTrue(tocRows(content).isEmpty)
        let body = try XCTUnwrap(content.blocks.first { $0.links.count == 3 })
        XCTAssertTrue(body.links.allSatisfy(\.isInPageAnchor))
        XCTAssertTrue(content.outboundURLs.isEmpty)
    }

    /// A footnote list is link-dense in ANCHOR COUNT but not in link TEXT — the
    /// gate that separates a ToC from prose that merely links inside itself.
    func testAFootnoteListWithBackLinksIsNotATableOfContents() throws {
        let html = """
        <html><body><article>
          <h1>Story</h1>
          <p>\(prose("body", sentences: 10))</p>
          <h2 id="ref1">Notes</h2>
          <ol>
            <li>\(prose("note one")) <a href="#ref1">back</a></li>
            <li>\(prose("note two")) <a href="#ref1">back</a></li>
            <li>\(prose("note three")) <a href="#ref1">back</a></li>
          </ol>
        </article></body></html>
        """
        let content = try extract(html)
        XCTAssertTrue(tocRows(content).isEmpty)
        XCTAssertTrue(content.wholeText.contains("note two"))
    }

    func testSiteNavigationWithOneAnchorIsNotATableOfContents() throws {
        let html = """
        <html><body><article>
          <h1>Story</h1>
          <div class="post-nav">
            <a href="https://blog.example.com/">Home</a>
            <a href="https://blog.example.com/about">About</a>
            <a href="https://blog.example.com/archive">Archive</a>
            <a href="#one">One</a>
          </div>
          <h2 id="one">One</h2><p>\(prose("one"))</p>
          <h2 id="two">Two</h2><p>\(prose("two"))</p>
        </article></body></html>
        """
        XCTAssertTrue(tocRows(try extract(html)).isEmpty)
    }

    // MARK: - Erring toward omission

    /// A destination stripped as junk (`[id*=comment]` here) leaves its row
    /// unlinked rather than offering a tap that reopens the live page — and with
    /// too few working rows left, the whole list goes.
    func testATableOfContentsWhoseDestinationsVanishedIsDroppedWhole() throws {
        let html = """
        <html><body><article>
          <h1>Story</h1>
          <ul>
            <li><a href="#comment-one">One</a></li>
            <li><a href="#comment-two">Two</a></li>
            <li><a href="#comment-three">Three</a></li>
          </ul>
          <p>\(prose("body", sentences: 10))</p>
          <h2 id="comment-one">One</h2><p>\(prose("one"))</p>
          <h2 id="comment-two">Two</h2><p>\(prose("two"))</p>
          <h2 id="comment-three">Three</h2><p>\(prose("three"))</p>
        </article></body></html>
        """
        XCTAssertTrue(tocRows(try extract(html)).isEmpty)
    }

    /// A ToC parked in a sidebar goes with the sidebar. Keeping the `<aside>`
    /// alive for it would drag the newsletter box and popular-posts rail into the
    /// article — the omission side of the trade, asserted so it stays deliberate.
    func testATableOfContentsInsideAStrippedSidebarIsGivenUp() throws {
        let html = """
        <html><body>
        <aside class="sidebar">
          <nav><ul>
            <li><a href="#one">One</a></li>
            <li><a href="#two">Two</a></li>
            <li><a href="#three">Three</a></li>
          </ul></nav>
        </aside>
        <article>
          <h1>Story</h1>
          <h2 id="one">One</h2><p>\(prose("one"))</p>
          <h2 id="two">Two</h2><p>\(prose("two"))</p>
          <h2 id="three">Three</h2><p>\(prose("three"))</p>
        </article></body></html>
        """
        let content = try extract(html)
        XCTAssertTrue(tocRows(content).isEmpty)
        XCTAssertTrue(content.wholeText.contains("Paragraph two"))
    }

    // MARK: - Markup idioms

    func testTheEmptyNamedAnchorIdiomStillResolves() throws {
        let html = """
        <html><body><article>
          <h1>Story</h1>
          <div class="contents">
            <p><a href="#part-one">Part one</a></p>
            <p><a href="#part-two">Part two</a></p>
            <p><a href="#part-three">Part three</a></p>
          </div>
          <a name="part-one"></a><h2>Part one</h2><p>\(prose("one"))</p>
          <a name="part-two"></a><h2>Part two</h2><p>\(prose("two"))</p>
          <a name="part-three"></a><h2>Part three</h2><p>\(prose("three"))</p>
        </article></body></html>
        """
        let content = try extract(html)
        let rows = tocRows(content)
        XCTAssertEqual(rows.count, 3)
        for row in rows {
            let anchorID = try XCTUnwrap(row.links.first?.anchorID)
            let destination = try XCTUnwrap(content.blockIndex(forAnchorID: anchorID))
            XCTAssertEqual(content.blocks[destination].kind, .heading)
        }
    }

    func testASectionWrapperLendsItsAnchorToItsHeadingOnly() throws {
        let html = """
        <html><body><article>
          <h1>Story</h1>
          <ul>
            <li><a href="#s1">First</a></li>
            <li><a href="#s2">Second</a></li>
            <li><a href="#s3">Third</a></li>
          </ul>
          <section id="s1"><h2>First</h2><p>\(prose("one"))</p></section>
          <section id="s2"><h2>Second</h2><p>\(prose("two"))</p></section>
          <section id="s3"><h2>Third</h2><p>\(prose("three"))</p></section>
        </article></body></html>
        """
        let content = try extract(html)
        XCTAssertEqual(tocRows(content).count, 3)
        let anchored = content.blocks.filter { $0.anchorID != nil }
        XCTAssertEqual(anchored.count, 3)
        XCTAssertTrue(anchored.allSatisfy { $0.kind == .heading })
    }

    func testFullPathHrefsToTheSamePageCountAsInPageJumps() throws {
        let html = """
        <html><body><article>
          <h1>Story</h1>
          <ul>
            <li><a href="/posts/long-entry#one">One</a></li>
            <li><a href="/posts/long-entry#two">Two</a></li>
            <li><a href="/posts/long-entry#three">Three</a></li>
          </ul>
          <h2 id="one">One</h2><p>\(prose("one"))</p>
          <h2 id="two">Two</h2><p>\(prose("two"))</p>
          <h2 id="three">Three</h2><p>\(prose("three"))</p>
        </article></body></html>
        """
        let content = try extract(html)
        XCTAssertEqual(
            tocRows(content).compactMap { $0.links.first?.anchorID }, ["one", "two", "three"])
    }

    /// Hrefs may be percent-encoded while markup ids arrive decoded.
    func testPercentEncodedFragmentsMatchTheirDecodedIDs() throws {
        let html = """
        <html><body><article>
          <h1>Story</h1>
          <ul>
            <li><a href="#caf%C3%A9">Caf\u{00E9}</a></li>
            <li><a href="#two">Two</a></li>
            <li><a href="#three">Three</a></li>
          </ul>
          <h2 id="caf\u{00E9}">Caf\u{00E9}</h2><p>\(prose("one"))</p>
          <h2 id="two">Two</h2><p>\(prose("two"))</p>
          <h2 id="three">Three</h2><p>\(prose("three"))</p>
        </article></body></html>
        """
        let content = try extract(html)
        XCTAssertEqual(tocRows(content).first?.links.first?.anchorID, "caf\u{00E9}")
        XCTAssertNotNil(content.blockIndex(forAnchorID: "caf\u{00E9}"))
    }

    // MARK: - Persistence

    /// `anchorID` is additive on both `Block` and `Link`, so articles saved
    /// before this existed must keep decoding.
    func testContentSavedBeforeAnchorsExistedStillDecodes() throws {
        let legacy = """
        {"title":"Story","blocks":[
          {"kind":"paragraph","text":"Body.","links":[
            {"start":0,"length":4,"urlString":"https://example.com/x"}]}]}
        """
        let content = try JSONDecoder().decode(ArticleContent.self, from: Data(legacy.utf8))
        XCTAssertNil(content.blocks[0].anchorID)
        XCTAssertFalse(content.blocks[0].links[0].isInPageAnchor)
        XCTAssertTrue(content.blocks[0].isReadableProse)
    }
}
