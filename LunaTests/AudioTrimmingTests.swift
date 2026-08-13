//
//  AudioTrimmingTests.swift
//  LunaTests
//

import LunaModels
import XCTest
@testable import LunaAudioPlayback
@testable import LunaReaderUI

/// A scripted `AudioTrimModelSession` fake — the on-device model is NEVER
/// available in a CI simulator, so `AudioTrimIntelligence`'s chunking/
/// validation/error-handling logic is exercised entirely against this.
final class FakeTrimModelSession: AudioTrimModelSession {
    var isAvailable = true
    private(set) var prewarmCount = 0
    private(set) var requestedPrompts: [String] = []

    /// Scripted responses, consumed in order — one per
    /// `requestCleanupVerdict` call. `.indices` succeeds with those raw
    /// indices; `.failure` throws the given error.
    enum Response {
        case indices([Int])
        case failure(AudioTrimModelError)
    }
    var responses: [Response] = []

    func prewarm() { prewarmCount += 1 }

    func requestCleanupVerdict(instructions: String, numberedListPrompt: String) async throws -> [Int] {
        requestedPrompts.append(numberedListPrompt)
        guard !responses.isEmpty else { return [] }
        switch responses.removeFirst() {
        case .indices(let indices): return indices
        case .failure(let error): throw error
        }
    }
}

/// Exercises every `AudioTrimHeuristics` rule (see "Phase 4: Trimming" /
/// `AudioScriptBuilder` in `claudedocs/audio-playback-plan.md`), the
/// positional rule (a weak signal is only ever acted on as a contiguous run
/// from the article's start/end; the SAME signal mid-article is kept), and
/// the global-cap degradation; `AudioTrimIntelligence`'s chunking/
/// validation/error-handling against `FakeTrimModelSession`; and the
/// legacy extension-only read-aloud path's block-filtering contract
/// (`SpeechController.speakableBlocks`).
final class AudioTrimmingTests: XCTestCase {

    // MARK: - Shared block/content helpers
    //
    // `speechBlock` below builds a block with a different shape (text-first,
    // no `links` parameter) for the `SpeechController` tests, since its
    // signature differs from `block` here.

    private func block(
        _ kind: ArticleContent.Block.Kind = .paragraph, _ text: String, links: [ArticleContent.Link] = []
    ) -> ArticleContent.Block {
        ArticleContent.Block(kind: kind, text: text, links: links)
    }

    private func content(_ blocks: [ArticleContent.Block]) -> ArticleContent {
        ArticleContent(title: "Title", blocks: blocks)
    }

    // MARK: - AudioTrimHeuristicsTests helpers

    /// A block of ordinary prose long enough (> `weakEdgeMaxWordCount`) to
    /// never qualify for a weak edge drop, and with no other signal —
    /// the article's real lead/body text.
    private func longProse(_ seed: String = "lead") -> ArticleContent.Block {
        block(.paragraph, Array(repeating: "word\(seed)", count: 45).joined(separator: " "))
    }

    // MARK: - AudioTrimIntelligenceTests helpers

    private func prose(_ words: Int = 20) -> ArticleContent.Block {
        block(.paragraph, (0..<words).map { "w\($0)" }.joined(separator: " "))
    }

    private func heuristicResult(dropped: Set<Int> = []) -> AudioTrimHeuristics.Result {
        AudioTrimHeuristics.Result(droppedBlockIndices: dropped, reasons: [:], didDegradeForGlobalCap: false)
    }

    // MARK: - SpeechControllerAudioTrimmingTests helpers
    //
    // The legacy extension-only read-aloud path (`SpeechController`) speaks
    // a TRIMMED subset of an article's blocks.
    // `speakableBlocks(content:spokenBlockIndices:)` is the pure filtering
    // logic behind `SpeechController.init` — tested directly (no
    // `AVSpeechSynthesizer` involved) to pin the hard contract every other
    // method in the class depends on: each surviving entry keeps its
    // ORIGINAL `content.blocks` index, never renumbered, so
    // `blockTextRanges[safe: block.blockIndex]` (used by both
    // `blockPosition(forAttributedLocation:)` and
    // `willSpeakRangeOfSpeechString`) keeps mapping correctly against the
    // UNTRIMMED visual reader regardless of which/how many blocks were
    // filtered.

    /// A different shape from the `block(_:_:links:)` helper above
    /// (text-first, no `links` parameter), kept distinct rather than
    /// overloaded.
    private func speechBlock(_ text: String, kind: ArticleContent.Block.Kind = .paragraph) -> ArticleContent.Block {
        ArticleContent.Block(kind: kind, text: text, links: [])
    }

    // MARK: - AudioTrimHeuristicsTests tests

    func testImageBlockAlwaysDropped() {
        let result = AudioTrimHeuristics.classify(content([
            longProse("a"), block(.image, ""), longProse("b"),
        ]))
        XCTAssertEqual(result.droppedBlockIndices, [1])
    }

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

    // MARK: - AudioTrimIntelligenceTests tests

    func testAcceptsInRangeIndicesAndPrewarmsOnce() async {
        let session = FakeTrimModelSession()
        session.responses = [.indices([1])]
        let articleContent = content([prose(), block(.paragraph, "Photo: a caption"), prose()])

        let result = await AudioTrimIntelligence.refine(
            content: articleContent, heuristicResult: heuristicResult(), totalWordCount: 60, session: session)

        XCTAssertEqual(result.additionalDroppedIndices, [1])
        XCTAssertFalse(result.permanentFailure)
        XCTAssertEqual(session.prewarmCount, 1)
    }

    func testOutOfRangeIndicesAreFilteredOut() async {
        let session = FakeTrimModelSession()
        session.responses = [.indices([1, 999, -5])]
        let articleContent = content([prose(), block(.paragraph, "Photo: a caption"), prose()])

        let result = await AudioTrimIntelligence.refine(
            content: articleContent, heuristicResult: heuristicResult(), totalWordCount: 60, session: session)

        XCTAssertEqual(result.additionalDroppedIndices, [1])
    }

    func testChunkVerdictFlaggingMoreThanHalfItsBlocksIsRejectedEntirely() async {
        let session = FakeTrimModelSession()
        // 4 surviving blocks in one chunk; flagging 3/4 (75%) should be
        // rejected wholesale, not partially accepted.
        session.responses = [.indices([0, 1, 2])]
        let articleContent = content([prose(), prose(), prose(), prose()])

        let result = await AudioTrimIntelligence.refine(
            content: articleContent, heuristicResult: heuristicResult(), totalWordCount: 80, session: session)

        XCTAssertTrue(result.additionalDroppedIndices.isEmpty)
    }

    func testEdgeAdjacentRemovalExtendingHeuristicRunIsAcceptedOutright() async {
        // Heuristics already dropped block 0 (leading run); the model
        // proposes block 1 too, WITHOUT any weak signal of its own — should
        // still be accepted since it extends the leading run. Block 1 is
        // kept small (well under the combined cap) so this test isolates
        // the positional rule from the global-cap rule (tested separately).
        let session = FakeTrimModelSession()
        session.responses = [.indices([1])]
        let articleContent = content([block(.paragraph, "By Jane Doe"), prose(10), prose(30)])

        let result = await AudioTrimIntelligence.refine(
            content: articleContent, heuristicResult: heuristicResult(dropped: [0]), totalWordCount: 43, session: session)

        XCTAssertEqual(result.additionalDroppedIndices, [1])
    }

    func testMidArticleRemovalWithoutWeakSignalIsRejected() async {
        // Nothing at either edge is heuristically dropped; the model
        // proposes removing the middle block, which shows no heuristic
        // signal at all (ordinary long prose) — must be rejected.
        let session = FakeTrimModelSession()
        session.responses = [.indices([1])]
        let articleContent = content([prose(30), prose(30), prose(30)])

        let result = await AudioTrimIntelligence.refine(
            content: articleContent, heuristicResult: heuristicResult(), totalWordCount: 90, session: session)

        XCTAssertTrue(result.additionalDroppedIndices.isEmpty)
    }

    func testMidArticleRemovalWithWeakSignalIsAccepted() async {
        // The proposed mid-article block is short (a weak/"looks like junk"
        // signal on its own) even though it's not adjacent to any
        // heuristic-dropped run — accepted per the plan's "mid-article
        // removals only if the block ALSO shows a weak heuristic signal".
        let session = FakeTrimModelSession()
        session.responses = [.indices([1])]
        let articleContent = content([prose(30), block(.paragraph, "Quite short indeed"), prose(30)])

        let result = await AudioTrimIntelligence.refine(
            content: articleContent, heuristicResult: heuristicResult(), totalWordCount: 63, session: session)

        XCTAssertEqual(result.additionalDroppedIndices, [1])
    }

    func testCombinedCapExceededDiscardsAllLLMVerdicts() async {
        let session = FakeTrimModelSession()
        // Block 0 already heuristically dropped; the model proposes
        // block 1 (extends that run, so the positional rule accepts it
        // outright) — but blocks 0+1 together are 75% of the article's
        // total words, over the 50% combined cap, so the verdict must be
        // discarded entirely even though it was positionally fine.
        session.responses = [.indices([1])]
        let articleContent = content([
            block(.paragraph, "By Jane Doe"), block(.paragraph, "Quite short indeed"), prose(2),
        ])

        let result = await AudioTrimIntelligence.refine(
            content: articleContent, heuristicResult: heuristicResult(dropped: [0]), totalWordCount: 8, session: session)

        XCTAssertTrue(result.additionalDroppedIndices.isEmpty, "combined removal exceeds the cap; LLM verdicts discarded")
    }

    func testGuardrailViolationIsPermanentAndStopsFurtherChunks() async {
        let session = FakeTrimModelSession()
        session.responses = [.failure(.guardrailViolation), .indices([1])] // second response should never be consumed
        let manyBlocks = (0..<30).map { _ in prose() }
        let articleContent = content(manyBlocks)

        let result = await AudioTrimIntelligence.refine(
            content: articleContent, heuristicResult: heuristicResult(), totalWordCount: 600, session: session)

        XCTAssertTrue(result.permanentFailure)
        XCTAssertTrue(result.additionalDroppedIndices.isEmpty)
        XCTAssertEqual(session.requestedPrompts.count, 1, "a guardrail violation must abort remaining chunks")
    }

    func testExceededContextWindowHalvesTheChunkAndRetriesOnce() async {
        // 4 surviving blocks so each half (of 2) can flag exactly one
        // (50% — at the acceptance boundary) without tripping the
        // per-chunk >50%-rejection rule a 1-block half would.
        let session = FakeTrimModelSession()
        session.responses = [.failure(.exceededContextWindowSize), .indices([0]), .indices([3])]
        let articleContent = content([prose(), prose(), prose(), prose()])

        let result = await AudioTrimIntelligence.refine(
            content: articleContent, heuristicResult: heuristicResult(), totalWordCount: 80, session: session)

        XCTAssertEqual(result.additionalDroppedIndices, [0, 3])
        XCTAssertEqual(session.requestedPrompts.count, 3, "one failed full-chunk attempt + two halves")
    }

    func testExceededContextWindowSecondFailureJustSkipsThatHalf() async {
        let session = FakeTrimModelSession()
        session.responses = [.failure(.exceededContextWindowSize), .failure(.exceededContextWindowSize), .indices([3])]
        let articleContent = content([prose(), prose(), prose(), prose()])

        let result = await AudioTrimIntelligence.refine(
            content: articleContent, heuristicResult: heuristicResult(), totalWordCount: 80, session: session)

        XCTAssertEqual(result.additionalDroppedIndices, [3])
        XCTAssertFalse(result.permanentFailure)
    }

    func testGuardrailViolationDuringHalvedRetryIsStillPermanent() async {
        let session = FakeTrimModelSession()
        session.responses = [.failure(.exceededContextWindowSize), .failure(.guardrailViolation)]
        let articleContent = content([prose(), prose(), prose(), prose()])

        let result = await AudioTrimIntelligence.refine(
            content: articleContent, heuristicResult: heuristicResult(), totalWordCount: 80, session: session)

        XCTAssertTrue(result.permanentFailure)
    }

    func testRateLimitedSkipsTheLLMPassForThisChunk() async {
        let session = FakeTrimModelSession()
        session.responses = [.failure(.rateLimited)]
        let articleContent = content([prose(), block(.paragraph, "Photo: a caption"), prose()])

        let result = await AudioTrimIntelligence.refine(
            content: articleContent, heuristicResult: heuristicResult(), totalWordCount: 60, session: session)

        XCTAssertFalse(result.permanentFailure)
        XCTAssertTrue(result.additionalDroppedIndices.isEmpty)
    }

    func testNoSurvivingBlocksSkipsCallingTheModelEntirely() async {
        let session = FakeTrimModelSession()
        let articleContent = content([block(.image, "")])

        let result = await AudioTrimIntelligence.refine(
            content: articleContent, heuristicResult: heuristicResult(dropped: [0]), totalWordCount: 0, session: session)

        XCTAssertTrue(result.additionalDroppedIndices.isEmpty)
        XCTAssertEqual(session.prewarmCount, 0)
    }

    // MARK: - SpeechControllerAudioTrimmingTests tests

    func testNilSpokenBlockIndicesSpeaksEveryNonEmptyBlockInOrder() {
        let articleContent = content([speechBlock("Zero"), speechBlock(""), speechBlock("Two"), speechBlock("Three")])

        let speakable = SpeechController.speakableBlocks(content: articleContent, spokenBlockIndices: nil)

        // Block 1 is empty text and always skipped, filter or not.
        XCTAssertEqual(speakable.map(\.blockIndex), [0, 2, 3])
        XCTAssertEqual(speakable.map(\.text), ["Zero", "Two", "Three"])
    }

    func testFilteringToASubsetPreservesOriginalBlockIndices() {
        let articleContent = content([
            speechBlock("By Jane Doe"), // dropped (byline-style, index 0)
            speechBlock("The actual first paragraph of real prose."), // kept, index 1
            speechBlock("Photo: a caption"), // dropped (caption-style, index 2)
            speechBlock("The second paragraph of real prose."), // kept, index 3
        ])
        // Simulates an `AudioScript.spokenBlocks.map(\.blockIndex)` that
        // dropped indices 0 and 2 (byline/caption), keeping 1 and 3 — NOT
        // contiguous, and NOT starting at 0.
        let spokenBlockIndices: Set<Int> = [1, 3]

        let speakable = SpeechController.speakableBlocks(content: articleContent, spokenBlockIndices: spokenBlockIndices)

        XCTAssertEqual(speakable.map(\.blockIndex), [1, 3], "kept blocks must keep their ORIGINAL index, not 0/1")
        XCTAssertEqual(speakable.map(\.text), [
            "The actual first paragraph of real prose.",
            "The second paragraph of real prose.",
        ])
    }

    func testEmptyTextBlocksAreAlwaysExcludedEvenIfNamedInTheFilter() {
        let articleContent = content([speechBlock("Kept"), speechBlock("")])
        // Even if a script's spokenBlocks somehow named the empty block, an
        // empty-text block never becomes speakable — matching the pre-Phase-6
        // invariant (`!$0.element.text.isEmpty` runs first).
        let speakable = SpeechController.speakableBlocks(content: articleContent, spokenBlockIndices: [0, 1])
        XCTAssertEqual(speakable.map(\.blockIndex), [0])
    }

    func testFilteringToAnEmptySetSpeaksNothing() {
        let articleContent = content([speechBlock("One"), speechBlock("Two")])
        let speakable = SpeechController.speakableBlocks(content: articleContent, spokenBlockIndices: [])
        XCTAssertTrue(speakable.isEmpty)
    }

    func testFilteringWithIndicesOutOfRangeIsHarmless() {
        let articleContent = content([speechBlock("One")])
        let speakable = SpeechController.speakableBlocks(content: articleContent, spokenBlockIndices: [0, 99])
        XCTAssertEqual(speakable.map(\.blockIndex), [0])
    }
}
