//
//  AudioTrimHeuristicsTests.swift
//  LunaTests
//

import LunaModels
import XCTest
@testable import LunaAudioPlayback

/// Exercises every `AudioTrimHeuristics` rule (see "Phase 4: Trimming" /
/// `AudioScriptBuilder` in `claudedocs/audio-playback-plan.md`), the
/// positional rule (a weak signal is only ever acted on as a contiguous run
/// from the article's start/end; the SAME signal mid-article is kept), and
/// the global-cap degradation.
final class AudioTrimHeuristicsTests: XCTestCase {

    private func block(
        _ kind: ArticleContent.Block.Kind = .paragraph, _ text: String, links: [ArticleContent.Link] = []
    ) -> ArticleContent.Block {
        ArticleContent.Block(kind: kind, text: text, links: links)
    }

    private func content(_ blocks: [ArticleContent.Block]) -> ArticleContent {
        ArticleContent(title: "Title", blocks: blocks)
    }

    /// A block of ordinary prose long enough (> `weakEdgeMaxWordCount`) to
    /// never qualify for a weak edge drop, and with no other signal —
    /// the article's real lead/body text.
    private func longProse(_ seed: String = "lead") -> ArticleContent.Block {
        block(.paragraph, Array(repeating: "word\(seed)", count: 45).joined(separator: " "))
    }

    // MARK: - Image blocks

    func testImageBlockAlwaysDropped() {
        let result = AudioTrimHeuristics.classify(content([
            longProse("a"), block(.image, ""), longProse("b"),
        ]))
        XCTAssertEqual(result.droppedBlockIndices, [1])
    }

    // MARK: - Caption/credit patterns (high precision — mid-article safe)

    func testCaptionCreditPrefixesDroppedMidArticle() {
        for prefix in ["Photo:", "Credit:", "Image:", "photo: ", "CREDIT:"] {
            let result = AudioTrimHeuristics.classify(content([
                longProse("a"), block(.paragraph, "\(prefix) a description of the scene"), longProse("b"),
            ]))
            XCTAssertEqual(result.droppedBlockIndices, [1], "prefix \(prefix) should be dropped mid-article")
        }
    }

    func testTrailingPhotoAgencyCreditDroppedMidArticle() {
        for suffix in ["/Getty Images", "/AP", "/Reuters"] {
            let result = AudioTrimHeuristics.classify(content([
                longProse("a"), block(.paragraph, "Jane Doe\(suffix)"), longProse("b"),
            ]))
            XCTAssertEqual(result.droppedBlockIndices, [1])
        }
    }

    func testParentheticalPhotoCreditDroppedMidArticle() {
        let result = AudioTrimHeuristics.classify(content([
            longProse("a"), block(.paragraph, "The senator spoke Tuesday. (Photo by Jane Doe)"), longProse("b"),
        ]))
        XCTAssertEqual(result.droppedBlockIndices, [1])
    }

    // MARK: - Explicit markers (high precision — mid-article safe)

    func testExplicitRelatedMarkersDroppedMidArticle() {
        for marker in ["READ MORE:", "MORE:", "ALSO READ:", "RELATED:"] {
            let result = AudioTrimHeuristics.classify(content([
                longProse("a"), block(.paragraph, "\(marker) Other stories you may like"), longProse("b"),
            ]))
            XCTAssertEqual(result.droppedBlockIndices, [1], "marker \(marker) should be dropped mid-article")
        }
    }

    func testShortAllCapsLineDroppedMidArticleEvenAsHeading() {
        let result = AudioTrimHeuristics.classify(content([
            longProse("a"), block(.heading, "ADVERTISEMENT"), longProse("b"),
        ]))
        XCTAssertEqual(result.droppedBlockIndices, [1], "short ALL-CAPS is high-precision, safe even for a heading")
    }

    func testLongAllCapsLineNotTreatedAsMarker() {
        let long = (0..<8).map { "WORD\($0)" }.joined(separator: " ")
        let result = AudioTrimHeuristics.classify(content([longProse("a"), block(.paragraph, long), longProse("b")]))
        XCTAssertTrue(result.droppedBlockIndices.isEmpty, "more than 6 words shouldn't count as a short ALL-CAPS marker")
    }

    // MARK: - Link density

    func testVeryHighLinkDensityDroppedMidArticle() {
        // Lowercase on purpose: an ALL-CAPS fixture would ALSO match the
        // short-ALL-CAPS marker rule and pass this test for the wrong reason.
        let text = "aaaaaaaaaa bbbbbb" // 17 UTF-16 units
        let link = ArticleContent.Link(start: 0, length: 13, urlString: "https://example.com") // ~0.76 density
        let result = AudioTrimHeuristics.classify(content([longProse("a"), block(.paragraph, text, links: [link]), longProse("b")]))
        XCTAssertEqual(result.droppedBlockIndices, [1])
    }

    func testModerateLinkDensityKeptMidArticleButDroppedAtLeadingEdge() {
        let text = "aaaaaaaaaa bbbbbbbbbb" // 21 UTF-16 units; lowercase (see above)
        let link = ArticleContent.Link(start: 0, length: 10, urlString: "https://example.com") // ~0.48 density
        let midResult = AudioTrimHeuristics.classify(content([longProse("a"), block(.paragraph, text, links: [link]), longProse("b")]))
        XCTAssertTrue(midResult.droppedBlockIndices.isEmpty, "moderate link density mid-article is a WEAK signal only")

        let edgeResult = AudioTrimHeuristics.classify(content([block(.paragraph, text, links: [link]), longProse("a"), longProse("b")]))
        XCTAssertEqual(edgeResult.droppedBlockIndices, [0], "the same moderate link density at the leading edge should drop")
    }

    // MARK: - Positional: leading-edge-only weak signals

    func testBylineDroppedAtLeadingEdgeButKeptMidArticle() {
        let edge = AudioTrimHeuristics.classify(content([block(.paragraph, "By Jane Doe"), longProse("a"), longProse("b")]))
        XCTAssertEqual(edge.droppedBlockIndices, [0], "byline at the very start should drop")

        let mid = AudioTrimHeuristics.classify(content([longProse("a"), block(.paragraph, "By Jane Doe"), longProse("b")]))
        XCTAssertTrue(mid.droppedBlockIndices.isEmpty, "the SAME byline text mid-article should be kept")
    }

    func testDatelineDroppedAtLeadingEdge() {
        // Mixed case after the dash so this exercises the DATELINE rule —
        // a bare "NEW YORK — " would match short-ALL-CAPS (high precision)
        // and pass without touching the dateline regex at all.
        let result = AudioTrimHeuristics.classify(content([
            block(.paragraph, "SAN FRANCISCO — Reporting from the courthouse"), longProse("a"), longProse("b"),
        ]))
        XCTAssertEqual(result.droppedBlockIndices, [0])
    }

    func testBareAllCapsDatelineFragmentDroppedAnywhereAsHighPrecision() {
        // "NEW YORK — " alone has no lowercase at all, so it hits the
        // short-ALL-CAPS marker rule — high precision, mid-article safe.
        let result = AudioTrimHeuristics.classify(content([
            longProse("a"), block(.paragraph, "NEW YORK — "), longProse("b"),
        ]))
        XCTAssertEqual(result.droppedBlockIndices, [1])
    }

    func testUpdatedPublishedTimestampDroppedAtLeadingEdge() {
        for text in ["Updated: July 10, 2026", "Published: July 10, 2026"] {
            let result = AudioTrimHeuristics.classify(content([block(.paragraph, text), longProse("a"), longProse("b")]))
            XCTAssertEqual(result.droppedBlockIndices, [0], "\(text) should drop at the leading edge")
        }
    }

    func testMinReadLabelDroppedAtLeadingEdge() {
        let result = AudioTrimHeuristics.classify(content([block(.paragraph, "5 min read"), longProse("a"), longProse("b")]))
        XCTAssertEqual(result.droppedBlockIndices, [0])
    }

    // MARK: - Positional: trailing-edge-only weak signals

    func testSharePromptDroppedAtTrailingEdgeButKeptMidArticle() {
        let text = "Share this article with your friends and family"
        let edge = AudioTrimHeuristics.classify(content([longProse("a"), longProse("b"), block(.paragraph, text)]))
        XCTAssertEqual(edge.droppedBlockIndices, [2])

        let mid = AudioTrimHeuristics.classify(content([longProse("a"), block(.paragraph, text), longProse("b")]))
        XCTAssertTrue(mid.droppedBlockIndices.isEmpty)
    }

    func testNewsletterSignupDroppedAtTrailingEdge() {
        let result = AudioTrimHeuristics.classify(content([
            longProse("a"), longProse("b"), block(.paragraph, "Sign up for our free newsletter today"),
        ]))
        XCTAssertEqual(result.droppedBlockIndices, [2])
    }

    func testSocialEmbedBoilerplateDroppedAtTrailingEdge() {
        for text in ["View this post on Instagram", "A post shared by Jane Doe"] {
            let result = AudioTrimHeuristics.classify(content([longProse("a"), longProse("b"), block(.paragraph, text)]))
            XCTAssertEqual(result.droppedBlockIndices, [2], "\(text) should drop at the trailing edge")
        }
    }

    func testCopyrightLineDroppedAtTrailingEdge() {
        let result = AudioTrimHeuristics.classify(content([
            longProse("a"), longProse("b"), block(.paragraph, "© 2026 Example News. All rights reserved."),
        ]))
        XCTAssertEqual(result.droppedBlockIndices, [2])
    }

    // MARK: - Guard rails

    func testHeadingNeverDroppedByWeakSignalEvenAtTheEdge() {
        let result = AudioTrimHeuristics.classify(content([
            block(.heading, "Updated: Monday"), longProse("a"), longProse("b"),
        ]))
        XCTAssertTrue(result.droppedBlockIndices.isEmpty, "a heading matching only a weak signal is never dropped")
    }

    func testFirstProseParagraphNeverDroppedEvenIfItLooksLikeABylineByCoincidence() {
        let longBylineLike = "By Jane Doe, a longtime correspondent who has covered international affairs for over "
            + "two decades and won numerous awards for her investigative reporting on government corruption and "
            + "financial fraud across multiple continents including Asia, Europe, and South America"
        let result = AudioTrimHeuristics.classify(content([block(.paragraph, longBylineLike), longProse("a"), longProse("b")]))
        XCTAssertTrue(result.droppedBlockIndices.isEmpty, "a real (long) lead paragraph must survive even if it starts like a byline")
    }

    func testEmptyBlocksNeverAppearInDroppedSet() {
        let result = AudioTrimHeuristics.classify(content([block(.paragraph, ""), longProse("a")]))
        XCTAssertTrue(result.droppedBlockIndices.isEmpty)
    }

    // MARK: - Global cap degradation

    func testGlobalCapDegradesToHighPrecisionOnlyWhenFullRuleSetWouldOverTrim() {
        let realProse = block(.paragraph, Array(repeating: "word", count: 10).joined(separator: " "))
        let blocks = [
            block(.paragraph, "By Jane Doe"),                        // leading weak (3w)
            block(.paragraph, "3 min read"),                          // leading weak (3w)
            block(.paragraph, "Updated: July 10, 2026"),              // leading weak (4w)
            realProse,                                                 // real prose (10w) — must survive
            block(.paragraph, "Share this article now"),              // trailing weak (4w)
            block(.paragraph, "Sign up for our newsletter"),           // trailing weak (5w)
            block(.image, ""),                                         // high precision, 0w
        ]
        let result = AudioTrimHeuristics.classify(content(blocks))

        XCTAssertTrue(result.didDegradeForGlobalCap, "the full rule set here drops well over half the words")
        // Degraded: only the image block (high precision) stays dropped —
        // every weak-only edge block is restored.
        XCTAssertEqual(result.droppedBlockIndices, [6])
    }

    func testNonDegradedCapStillAppliesFullRuleSetWhenUnderTheCap() {
        // Plenty of real prose alongside a small leading/trailing weak run —
        // well under the 50% cap, so no degradation.
        let blocks = [
            block(.paragraph, "By Jane Doe"),
            longProse("a"), longProse("b"), longProse("c"), longProse("d"),
            block(.paragraph, "Share this article now"),
        ]
        let result = AudioTrimHeuristics.classify(content(blocks))
        XCTAssertFalse(result.didDegradeForGlobalCap)
        XCTAssertEqual(result.droppedBlockIndices, [0, 5])
    }

    // MARK: - looksLikeRemovableJunk (used by AudioTrimIntelligence's mid-article gate)

    func testLooksLikeRemovableJunkTrueForImageAndSignaledAndShortBlocks() {
        XCTAssertTrue(AudioTrimHeuristics.looksLikeRemovableJunk(block(.image, "")))
        XCTAssertTrue(AudioTrimHeuristics.looksLikeRemovableJunk(block(.paragraph, "Photo: a caption")))
        XCTAssertTrue(AudioTrimHeuristics.looksLikeRemovableJunk(block(.paragraph, "Quite short indeed")))
    }

    func testLooksLikeRemovableJunkFalseForOrdinaryProse() {
        XCTAssertFalse(AudioTrimHeuristics.looksLikeRemovableJunk(longProse("a")))
    }
}
