//
//  AudioTrimIntelligenceTests.swift
//  LunaTests
//

import LunaModels
import XCTest
@testable import LunaAudioPlayback

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

final class AudioTrimIntelligenceTests: XCTestCase {

    private func block(
        _ kind: ArticleContent.Block.Kind = .paragraph, _ text: String, links: [ArticleContent.Link] = []
    ) -> ArticleContent.Block {
        ArticleContent.Block(kind: kind, text: text, links: links)
    }

    private func content(_ blocks: [ArticleContent.Block]) -> ArticleContent {
        ArticleContent(title: "Title", blocks: blocks)
    }

    private func prose(_ words: Int = 20) -> ArticleContent.Block {
        block(.paragraph, (0..<words).map { "w\($0)" }.joined(separator: " "))
    }

    private func heuristicResult(dropped: Set<Int> = []) -> AudioTrimHeuristics.Result {
        AudioTrimHeuristics.Result(droppedBlockIndices: dropped, reasons: [:], didDegradeForGlobalCap: false)
    }

    // MARK: - Basic acceptance

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

    // MARK: - Positional rule

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

    // MARK: - Global cap (combined heuristic + LLM)

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

    // MARK: - Error handling

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
}
