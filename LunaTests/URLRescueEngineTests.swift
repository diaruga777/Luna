//
//  URLRescueEngineTests.swift
//  LunaTests
//

import XCTest
import LunaIngest
import LunaModels
@testable import LunaURLRescue

final class URLRescueEngineTests: XCTestCase {
    private let url = URL(string: "https://www.example.com/story")!

    private func request(hint: RescueHint? = .article,
                         failure: RescueRequest.FailureKind = .articleFailed,
                         html: String? = "<html><body>digest body content here for reroute example with 129.99 price</body></html>") -> RescueRequest {
        RescueRequest(url: url, source: .manual, failureKind: failure, hint: hint, fetchedHTML: html)
    }

    private func makeEngine(
        session: RescueModelSession,
        scriptRunner: RescueScriptRunning = FakeRescueScriptRunner(),
        ruleStore: RescueRuleStoring = InMemoryRescueRuleStore(),
        media: FakeMediaResolver = FakeMediaResolver(),
        pipeline: RecordingPipeline = RecordingPipeline(results: [IngestResult(url: URL(string: "https://www.example.com/story")!, outcome: .failed(nil))])
    ) -> (URLRescueEngine, RecordingPipeline) {
        let engine = URLRescueEngine(
            session: session, scriptRunner: scriptRunner, ruleStore: ruleStore,
            fetcher: FakeRescueHTMLFetcher(html: "<html></html>"), mediaResolver: media,
            runPipeline: { await pipeline.run($0) })
        return (engine, pipeline)
    }

    func testUnavailableSession() async {
        let (engine, _) = makeEngine(session: FakeRescueModelSession(available: false))
        let outcome = await engine.rescue(request())
        guard case .unavailable = outcome else { return XCTFail("expected unavailable") }
    }

    func testGuardrailIsUnrescuable() async {
        let session = FakeRescueModelSession(responses: [.failure(.guardrailViolation)])
        let (engine, _) = makeEngine(session: session)
        let outcome = await engine.rescue(request())
        guard case .unrescuable = outcome else { return XCTFail("guardrail → unrescuable") }
    }

    func testQuotaExhausted() async {
        let session = FakeRescueModelSession(responses: [.failure(.quotaLimitReached)])
        let (engine, _) = makeEngine(session: session)
        let outcome = await engine.rescue(request())
        guard case .quotaExhausted = outcome else { return XCTFail("quota → quotaExhausted") }
    }

    // MARK: - Stage progress

    /// The card's eclipse bar is driven entirely by these reports, so the engine
    /// must always open with `.queued` and always close with `.finished` — even
    /// on the paths that bail early.
    func testProgressAlwaysStartsQueuedAndEndsFinished() async {
        let session = FakeRescueModelSession(responses: [.plan(RescuePlanResponse(kind: "give_up"))])
        let (engine, _) = makeEngine(session: session)
        var stages: [RescueStage] = []
        _ = await engine.rescue(request()) { stages.append($0) }
        XCTAssertEqual(stages.first, .queued)
        XCTAssertEqual(stages.last, .finished)
        XCTAssertTrue(stages.contains(.thinking), "the model call must be announced")
    }

    func testProgressFinishesEvenWhenTheSessionIsUnavailable() async {
        let (engine, _) = makeEngine(session: FakeRescueModelSession(available: false))
        var stages: [RescueStage] = []
        _ = await engine.rescue(request()) { stages.append($0) }
        XCTAssertEqual(stages, [.queued, .finished])
    }

    /// The digest is built from HTML the failing pass already had, so no fetch
    /// stage should be claimed — a bar that shows work nobody did is a lie.
    func testProgressSkipsFetchingWhenHTMLWasHandedOver() async {
        let session = FakeRescueModelSession(responses: [.plan(RescuePlanResponse(kind: "give_up"))])
        let (engine, _) = makeEngine(session: session)
        var stages: [RescueStage] = []
        _ = await engine.rescue(request()) { stages.append($0) }
        XCTAssertFalse(stages.contains(.fetching))
    }

    func testProgressReportsFetchingWhenItHasToRefetch() async {
        let session = FakeRescueModelSession(responses: [.plan(RescuePlanResponse(kind: "give_up"))])
        let (engine, _) = makeEngine(session: session)
        var stages: [RescueStage] = []
        _ = await engine.rescue(request(html: nil)) { stages.append($0) }
        XCTAssertTrue(stages.contains(.fetching))
    }

    func testPrewarmedOnce() async {
        let session = FakeRescueModelSession(responses: [.plan(RescuePlanResponse(kind: "give_up"))])
        let (engine, _) = makeEngine(session: session)
        _ = await engine.rescue(request())
        XCTAssertEqual(session.prewarmCount, 1)
    }

    /// Prewarming is what CREATES the underlying `LanguageModelSession`, so it has
    /// to be handed the same instructions the plan call will rely on. Warming
    /// first and passing instructions later built an instruction-less session that
    /// the plan call then silently reused, dropping its task contract.
    func testPrewarmReceivesThePlanInstructions() async {
        let session = FakeRescueModelSession(responses: [.plan(RescuePlanResponse(kind: "give_up"))])
        let (engine, _) = makeEngine(session: session)
        _ = await engine.rescue(request())
        XCTAssertEqual(session.prewarmInstructions, session.planInstructions)
        XCTAssertFalse(session.prewarmInstructions.isEmpty)
    }

    /// The engine is a process-lifetime singleton, so each attempt must start from
    /// a fresh model session instead of inheriting the previous rescue's
    /// transcript — or a response an earlier timeout cancelled mid-flight.
    func testEachAttemptBeginsAFreshModelSession() async {
        let session = FakeRescueModelSession(responses: [
            .plan(RescuePlanResponse(kind: "give_up")),
            .plan(RescuePlanResponse(kind: "give_up")),
        ])
        let (engine, _) = makeEngine(session: session)
        _ = await engine.rescue(request())
        _ = await engine.rescue(request())
        XCTAssertEqual(session.beginAttemptCount, 2)
    }

    func testRerouteReentersPipelineWithForceArticle() async {
        let good = IngestResult(url: URL(string: "https://amp.example.com/story")!,
                                outcome: .article(ArticleContent(title: "T", blocks: [
                                    .init(kind: .paragraph, text: String(repeating: "word ", count: 300), links: [])
                                ]), html: "h"))
        let pipeline = RecordingPipeline(results: [good])
        let session = FakeRescueModelSession(responses: [
            .plan(RescuePlanResponse(kind: "reroute", rerouteURLString: "https://amp.example.com/story"))
        ])
        let (engine, pipe) = makeEngine(session: session, pipeline: pipeline)
        let outcome = await engine.rescue(request(hint: .article))
        guard case .rescued(_, let method) = outcome else { return XCTFail("expected rescued") }
        XCTAssertEqual(method, .reroute)
        XCTAssertEqual(pipe.inputs.count, 1, "pipeline must be re-entered exactly once")
        XCTAssertTrue(pipe.inputs.first?.forceArticle == true)
        XCTAssertFalse(pipe.inputs.first?.trustsPrefetchedHTML == true)
    }

    func testRerouteSecondPassStillFailedIsUnrescuable() async {
        let session = FakeRescueModelSession(responses: [
            .plan(RescuePlanResponse(kind: "reroute", rerouteURLString: "https://amp.example.com/story"))
        ])
        // Default pipeline returns .failed.
        let (engine, pipe) = makeEngine(session: session)
        let outcome = await engine.rescue(request(hint: .article))
        guard case .unrescuable = outcome else { return XCTFail("failed second pass → unrescuable") }
        XCTAssertEqual(pipe.inputs.count, 1, "no loop — pipeline called at most once")
    }

    func testWebJSHTMLResultFedAsPrefetch() async {
        let article = ArticleContent(title: "T", blocks: [
            .init(kind: .paragraph, text: String(repeating: "word ", count: 300), links: [])
        ])
        let pipeline = RecordingPipeline(results: [IngestResult(url: url, outcome: .article(article, html: "h"))])
        let runner = FakeRescueScriptRunner(result: "<html><body>rendered</body></html>")
        let session = FakeRescueModelSession(responses: [
            .plan(RescuePlanResponse(kind: "webjs", javascript: "return document.body.outerHTML;", scriptResultKind: "html"))
        ])
        let (engine, pipe) = makeEngine(session: session, scriptRunner: runner, pipeline: pipeline)
        let outcome = await engine.rescue(request(hint: .article))
        guard case .rescued(_, .webJS) = outcome else { return XCTFail("expected webJS rescue") }
        XCTAssertEqual(pipe.inputs.first?.prefetchedHTML, "<html><body>rendered</body></html>")
    }

    func testMediaJSResultProducesAssets() async {
        let media = FakeMediaResolver(assets: [])
        let runner = FakeRescueScriptRunner(result: "https://cdn.net/clip.mp4")
        let session = FakeRescueModelSession(responses: [
            .plan(RescuePlanResponse(kind: "webjs", javascript: "return url;", scriptResultKind: "media_url"))
        ])
        let (engine, _) = makeEngine(session: session, scriptRunner: runner, media: media)
        let outcome = await engine.rescue(request(hint: .media, failure: .mediaNoAssets))
        guard case .rescuedMedia(let assets, .webJS) = outcome else { return XCTFail("expected media rescue") }
        XCTAssertEqual(assets.first?.url.absoluteString, "https://cdn.net/clip.mp4")
    }

    func testSuccessfulRerouteStoresRule() async {
        let good = IngestResult(url: URL(string: "https://amp.example.com/story")!,
                                outcome: .article(ArticleContent(title: "T", blocks: [
                                    .init(kind: .paragraph, text: String(repeating: "word ", count: 300), links: [])
                                ]), html: "h"))
        let ruleStore = InMemoryRescueRuleStore()
        let session = FakeRescueModelSession(responses: [
            .plan(RescuePlanResponse(kind: "reroute", rerouteURLString: "https://amp.example.com/story"))
        ])
        let (engine, _) = makeEngine(session: session, ruleStore: ruleStore,
                                     pipeline: RecordingPipeline(results: [good]))
        _ = await engine.rescue(request(hint: .article))
        XCTAssertNotNil(ruleStore.rule(forHost: "example.com", hint: .article), "a working reroute should be learned")
    }

    func testCachedRuleTriedBeforeLLM() async {
        let good = IngestResult(url: URL(string: "https://amp.example.com/story")!,
                                outcome: .article(ArticleContent(title: "T", blocks: [
                                    .init(kind: .paragraph, text: String(repeating: "word ", count: 300), links: [])
                                ]), html: "h"))
        let ruleStore = InMemoryRescueRuleStore()
        let now = Date()
        ruleStore.store(RescueLearnedRule(host: "example.com", hint: "article",
                                          rewrite: .hostReplace("amp.example.com"),
                                          createdAt: now, lastSuccessAt: now))
        let session = FakeRescueModelSession(responses: [])  // must never be called
        let (engine, _) = makeEngine(session: session, ruleStore: ruleStore,
                                     pipeline: RecordingPipeline(results: [good]))
        let outcome = await engine.rescue(request(hint: .article))
        guard case .rescued(_, .cachedRule) = outcome else { return XCTFail("expected cached-rule rescue") }
        XCTAssertEqual(session.prewarmCount, 0, "cache hit must not touch the model")
    }

    func testContextOverflowHalvesDigestAndRetriesOnce() async {
        let article = ArticleContent(title: "T", blocks: [
            .init(kind: .paragraph, text: String(repeating: "word ", count: 300), links: [])
        ])
        let session = FakeRescueModelSession(responses: [
            .failure(.exceededContextWindowSize),
            .plan(RescuePlanResponse(kind: "reroute", rerouteURLString: "https://amp.example.com/story")),
        ])
        let (engine, _) = makeEngine(session: session,
                                     pipeline: RecordingPipeline(results: [IngestResult(url: url, outcome: .article(article, html: "h"))]))
        let outcome = await engine.rescue(request(hint: .article))
        // First call overflowed, second (halved) succeeded → rescued.
        guard case .rescued = outcome else { return XCTFail("expected retry to succeed") }
        XCTAssertEqual(session.planPrompts.count, 2, "exactly one retry after overflow")
    }
}
