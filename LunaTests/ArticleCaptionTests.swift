//
//  ArticleCaptionTests.swift
//  LunaTests
//

import LunaHTMLClassification
import LunaModels
import XCTest

/// A picture's caption: shown by the scroll reader, never read by RSVP or aloud.
/// Before this the extractor emitted no caption block at all — `figcaption` was in
/// no selector — so the reader silently lost every caption on the page.
final class ArticleCaptionTests: XCTestCase {

    private let extractor = ArticleExtractor()
    private let baseURL = URL(string: "https://nypost.com/2026/07/31/business/story/")! // valid constant URL

    /// A body paragraph, long enough to count toward container scoring.
    private func prose(_ index: Int) -> String {
        """
        <p>Reported paragraph number \(index) carries enough concrete detail about the \
        feud between the two prediction markets to score as real article content.</p>
        """
    }

    private func articleWithFigure() -> String {
        """
        <html><head><meta property="og:title" content="The vicious battle"></head><body>
        <article>
        \(prose(1))
        \(prose(2))
        <figure>
          <a href="/photo"><img src="/hero.jpg" width="1024" height="683"></a>
          <figcaption>Shayne Coplan has feuded for years with the co-founders of
          arch-rival Kalshi. <span class="credit">Zuffa LLC</span></figcaption>
        </figure>
        \(prose(3))
        \(prose(4))
        \(prose(5))
        \(prose(6))
        </article>
        </body></html>
        """
    }

    func testFigureCaptionIsKeptAsACaptionBlock() throws {
        let content = try extractor.extract(html: articleWithFigure(), baseURL: baseURL)
        guard let imageIndex = content.blocks.firstIndex(where: { $0.kind == .image }),
              content.blocks.indices.contains(imageIndex + 1)
        else {
            return XCTFail("the article's figure must produce an image block and a caption")
        }
        let caption = content.blocks[imageIndex + 1]
        XCTAssertEqual(caption.kind, .caption, "a caption belongs directly under its image")
        XCTAssertTrue(caption.text.contains("feuded for years"))
        XCTAssertTrue(caption.text.contains("Zuffa LLC"),
                      "the photo credit is part of the caption the page prints")
    }

    /// The caption renders, but it is not prose: RSVP, `WordMap`, `SpeechController`
    /// and the audio script all key off `isReadableProse`, so a photo credit must
    /// never be flashed mid-sentence or spoken aloud.
    func testCaptionIsExcludedFromTheWordStream() throws {
        let content = try extractor.extract(html: articleWithFigure(), baseURL: baseURL)
        let captions = content.blocks.filter { $0.kind == .caption }
        XCTAssertFalse(captions.isEmpty)
        XCTAssertTrue(captions.allSatisfy { !$0.isReadableProse })
        XCTAssertTrue(content.blocks.filter { $0.kind == .paragraph }.allSatisfy(\.isReadableProse))
    }

    /// WordPress and several CMSs emit the caption as a `<p>` inside the `<figure>`
    /// rather than as a `<figcaption>`; text inside a figure IS caption text.
    func testParagraphInsideAFigureIsACaption() throws {
        let html = """
        <html><body><article>
        \(String(repeating: prose(1), count: 8))
        <figure class="wp-block-image">
          <img src="/photo.jpg" width="800" height="600">
          <p class="wp-caption-text">A crowd outside the courthouse. Getty Images</p>
        </figure>
        </article></body></html>
        """
        let content = try extractor.extract(html: html, baseURL: baseURL)
        XCTAssertTrue(
            content.blocks.contains { $0.kind == .caption && $0.text.contains("courthouse") },
            "a figure's own paragraph is its caption")
    }

    /// A caption is not a nested duplicate: the `<span class="credit">` inside it
    /// must not surface as its own block, and the caption must appear exactly once.
    func testCaptionIsEmittedOnlyOnce() throws {
        let content = try extractor.extract(html: articleWithFigure(), baseURL: baseURL)
        XCTAssertEqual(content.blocks.filter { $0.text.contains("Zuffa LLC") }.count, 1)
    }

    /// A caption's words must not arm or trip the recirc terminator: a credit line
    /// reading "Related Press" is a photo agency, not a rail, and truncating there
    /// would throw away the rest of the article.
    func testACaptionNamingAnAgencyDoesNotTruncateTheArticle() throws {
        let html = """
        <html><body><article>
        \(String(repeating: prose(1), count: 4))
        <figure>
          <img src="/photo.jpg" width="900" height="600">
          <figcaption>Trending Now / Reuters</figcaption>
        </figure>
        \(String(repeating: prose(2), count: 4))
        </article></body></html>
        """
        let content = try extractor.extract(html: html, baseURL: baseURL)
        XCTAssertEqual(content.blocks.filter { $0.text.hasPrefix("Reported paragraph") }.count, 8)
    }

    /// The reverse trim must not pop a closing caption off the end and orphan the
    /// picture it explains — photo credits routinely carry a "©", which is one of
    /// the trailing-junk phrases.
    func testAClosingCaptionSurvivesTheReverseTrim() throws {
        let html = """
        <html><body><article>
        \(String(repeating: prose(1), count: 6))
        <figure>
          <img src="/closing.jpg" width="900" height="600">
          <figcaption>The courthouse steps in March. © 2026 Getty Images</figcaption>
        </figure>
        </article></body></html>
        """
        let content = try extractor.extract(html: html, baseURL: baseURL)
        XCTAssertEqual(content.blocks.last?.kind, .caption)
        XCTAssertEqual(content.blocks.dropLast().last?.kind, .image)
    }
}
