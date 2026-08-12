//
//  URLRescueTests.swift
//  LunaTests
//

import LunaFetch
import LunaIngest
import LunaModels
import LunaShareSurface
import LunaStorage
import UIKit
import XCTest
@testable import Luna
@testable import LunaURLRescue

/// Marked `@MainActor` for the `ShareSurfaceDriverRescue` section below, which
/// drives UIKit-hosting fakes; the other sections run fine under the main actor.
@MainActor
final class URLRescueTests: XCTestCase {
    private let url = URL(string: "https://www.example.com/story")!
    private let builder = RescueDigestBuilder()

    private var scratch: URL!
    private var store: ReadingListStore!

    override func setUp() {
        super.setUp()
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShareRescue-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        store = ReadingListStore(containerURL: scratch)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: scratch)
        super.tearDown()
    }

    // MARK: - URLRescueEngine

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
        fetcher: HTMLFetching = FakeRescueHTMLFetcher(html: "<html></html>"),
        traceStore: RescueTraceStoring = FakeRescueTraceStore(),
        stats: RescueStatsStore? = nil,
        search: FakeRescueSearch = FakeRescueSearch(),
        pipeline: RecordingPipeline = RecordingPipeline(results: [IngestResult(url: URL(string: "https://www.example.com/story")!, outcome: .failed(nil))])
    ) -> (URLRescueEngine, RecordingPipeline) {
        let engine = URLRescueEngine(
            session: session, scriptRunner: scriptRunner, ruleStore: ruleStore,
            fetcher: fetcher, mediaResolver: media,
            traceStore: traceStore, stats: stats ?? RescueStatsStore(containerURL: scratch),
            search: { await search.run($0) },
            runPipeline: { await pipeline.run($0) })
        return (engine, pipeline)
    }

    func testUnavailableSession() async {
        let (engine, _) = makeEngine(session: FakeRescueModelSession(available: false))
        let outcome = await engine.rescue(request())
        guard case .unavailable = outcome else { return XCTFail("expected unavailable") }
    }

    /// A guardrail is a verdict on the prompt, and the prompt is derived from the
    /// page — so it must surface as its own PERMANENT failure rather than the
    /// ordinary "couldn't do it" that leaves the card offering a retry.
    func testGuardrailIsAPermanentFailureRatherThanPlainUnrescuable() async {
        let session = FakeRescueModelSession(responses: [.failure(.guardrailViolation)])
        let (engine, _) = makeEngine(session: session)
        let outcome = await engine.rescue(request())
        guard case .failed(.guardrailViolation) = outcome else {
            return XCTFail("guardrail → failed(.guardrailViolation)")
        }
        XCTAssertTrue(outcome.isPermanentlyBlocked)
    }

    /// A flat refusal is the same kind of verdict and used to vanish into an
    /// anonymous `.other`.
    func testRefusalIsAlsoPermanent() async {
        let session = FakeRescueModelSession(responses: [.failure(.refusal)])
        let (engine, _) = makeEngine(session: session)
        let outcome = await engine.rescue(request())
        XCTAssertTrue(outcome.isPermanentlyBlocked)
    }

    /// The model never saw the page in either case, so neither may spend the
    /// item's one visible attempt.
    func testTransientModelErrorsDoNotSpendTheVersionAttempt() async {
        for error in [RescueModelError.assetsUnavailable, .concurrentRequests] {
            let session = FakeRescueModelSession(responses: [.failure(error)])
            let (engine, _) = makeEngine(session: session)
            let outcome = await engine.rescue(request())
            XCTAssertFalse(outcome.spendsVersionAttempt,
                           "\(error.logToken) must not spend the attempt")
        }
    }

    /// …while a plain "I looked and nothing works" does.
    func testAGenuineGiveUpSpendsTheVersionAttempt() async {
        let session = FakeRescueModelSession(responses: [.plan(RescuePlanResponse(kind: "give_up"))])
        let (engine, _) = makeEngine(session: session)
        let outcome = await engine.rescue(request())
        XCTAssertTrue(outcome.spendsVersionAttempt)
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

    // MARK: - Failure evidence in the prompt

    private func traceStore(_ trace: String, for itemID: UUID) -> FakeRescueTraceStore {
        FakeRescueTraceStore(traces: [itemID: trace])
    }

    /// The default reason is deliberately NOT one of the client-refusal codes:
    /// those take the deterministic browser fast-path and never reach the model,
    /// which is its own test below.
    private func evidenceRequest(
        itemID: UUID, reason: SaveFailureReason? = .notReadable,
        html: String? = "<html><body>page body</body></html>"
    ) -> RescueRequest {
        RescueRequest(
            url: url, source: .manual, failureKind: .articleFailed, hint: nil,
            fetchedHTML: html, itemID: itemID, failureReason: reason,
            pageTitle: "The Vanishing Middle Class of Rome")
    }

    /// The whole point of work item 1: what the pipeline already learned reaches
    /// the model, fenced as untrusted page-derived content.
    func testTracedFailureReachesThePromptFencedAsUntrusted() async {
        let itemID = UUID()
        let trace = """
        2026-08-13T10:00:00Z [fetch] start https://www.example.com/story
        2026-08-13T10:00:01Z [fetch] status=403 blocked by DataDome
        2026-08-13T10:00:02Z [bypass] strategy=googlebot status=403
        """
        let session = FakeRescueModelSession(responses: [.plan(RescuePlanResponse(kind: "give_up"))])
        let (engine, _) = makeEngine(session: session, traceStore: traceStore(trace, for: itemID))
        _ = await engine.rescue(evidenceRequest(itemID: itemID))

        guard let prompt = session.planPrompts.first else { return XCTFail("no prompt") }
        XCTAssertTrue(prompt.contains("--- WHAT THE APP ALREADY TRIED (log excerpt, untrusted) ---"))
        XCTAssertTrue(prompt.contains("--- END LOG EXCERPT ---"))
        XCTAssertTrue(prompt.contains("strategy=googlebot"), "the bypass ladder is the evidence")
        // The excerpt is page-derived, so it must be in the PROMPT and never the
        // task contract.
        XCTAssertFalse(session.planInstructions.first?.contains("DataDome") == true)
    }

    /// An install with no trace for this item — every failure recorded before the
    /// trace file existed — must produce exactly the prompt it always did.
    ///
    /// This is also the guard on a subtler thing: the engine WRITES its own
    /// decisions to the same file, so reading the trace after the attempt's first
    /// log line would feed the rescue its own "start" back as evidence of what
    /// already failed. The excerpt has to be the state of the world before this
    /// attempt, not a mirror of it.
    func testNoTraceMeansNoEvidenceSection() async {
        let session = FakeRescueModelSession(responses: [.plan(RescuePlanResponse(kind: "give_up"))])
        let store = FakeRescueTraceStore()
        let (engine, _) = makeEngine(session: session, traceStore: store)
        _ = await engine.rescue(evidenceRequest(itemID: UUID()))
        XCTAssertFalse(session.planPrompts.first?.contains("LOG EXCERPT") == true)
        XCTAssertFalse(store.appended.isEmpty, "the rescue still wrote its own lines")
    }

    /// The recorded reason, not one of three canned sentences: the model is told
    /// WHICH refusal it is looking at.
    func testTheFailureSentenceCarriesTheRecordedStatusCode() async {
        let session = FakeRescueModelSession(responses: [.plan(RescuePlanResponse(kind: "give_up"))])
        let (engine, _) = makeEngine(session: session)
        _ = await engine.rescue(evidenceRequest(itemID: UUID(), reason: .httpStatus(404)))
        XCTAssertTrue(session.planPrompts.first?.contains("HTTP 404") == true)
    }

    func testTheFailureSentenceNamesASubscribeRedirect() async {
        let session = FakeRescueModelSession(responses: [.plan(RescuePlanResponse(kind: "give_up"))])
        let (engine, _) = makeEngine(session: session)
        _ = await engine.rescue(evidenceRequest(itemID: UUID(), reason: .subscribeRedirect))
        XCTAssertTrue(session.planPrompts.first?.contains("subscribe") == true)
    }

    /// Overflow halves the whole budget, so the evidence must shrink with the
    /// digest rather than crowding the retry out of the window it just made room in.
    func testContextOverflowHalvesTheEvidenceToo() async {
        let itemID = UUID()
        let trace = (0..<400).map { "2026-08-13T10:00:00Z [fetch] status=403 attempt \($0)" }
            .joined(separator: "\n")
        let session = FakeRescueModelSession(responses: [
            .failure(.exceededContextWindowSize),
            .plan(RescuePlanResponse(kind: "give_up")),
        ])
        let (engine, _) = makeEngine(session: session, traceStore: traceStore(trace, for: itemID))
        _ = await engine.rescue(evidenceRequest(itemID: itemID))

        XCTAssertEqual(session.planPrompts.count, 2)
        let first = Self.evidenceSection(of: session.planPrompts[0])
        let second = Self.evidenceSection(of: session.planPrompts[1])
        XCTAssertFalse(first.isEmpty)
        XCTAssertLessThan(second.count, first.count, "the retry must shrink the evidence too")
    }

    private static func evidenceSection(of prompt: String) -> String {
        guard let start = prompt.range(of: "--- WHAT THE APP ALREADY TRIED (log excerpt, untrusted) ---"),
              let end = prompt.range(of: "--- END LOG EXCERPT ---") else { return "" }
        return String(prompt[start.upperBound..<end.lowerBound])
    }

    /// The rescue's own decisions join the trace the failed card exports, so the
    /// file explains the rescue and not just the first pass.
    func testRescueDecisionsAreAppendedToTheItemsTrace() async {
        let itemID = UUID()
        let store = FakeRescueTraceStore()
        let session = FakeRescueModelSession(responses: [.plan(RescuePlanResponse(kind: "give_up"))])
        let (engine, _) = makeEngine(session: session, traceStore: store)
        _ = await engine.rescue(evidenceRequest(itemID: itemID))

        let written = store.appendedText(for: itemID)
        XCTAssertTrue(written.contains("[rescue] start"))
        XCTAssertTrue(written.contains("plan kind=give_up"))
    }

    /// No item, no trace: the price editor's ad-hoc resolution has no reading-list
    /// row to write against and must not invent one.
    func testAnItemlessRequestWritesNoTrace() async {
        let store = FakeRescueTraceStore()
        let session = FakeRescueModelSession(responses: [.plan(RescuePlanResponse(kind: "give_up"))])
        let (engine, _) = makeEngine(session: session, traceStore: store)
        _ = await engine.rescue(request())
        XCTAssertTrue(store.appended.isEmpty)
    }

    // MARK: - No HTML is no longer instant death

    /// The pages most in need of rescue are the ones whose refetch fails. Dying
    /// here without asking meant never asking about the cases that matter most.
    func testAFailedRefetchStillAsksTheModel() async {
        let session = FakeRescueModelSession(responses: [
            .plan(RescuePlanResponse(kind: "reroute", rerouteURLString: "https://amp.example.com/story"))
        ])
        let good = IngestResult(url: URL(string: "https://amp.example.com/story")!,
                                outcome: .article(ArticleContent(title: "T", blocks: [
                                    .init(kind: .paragraph, text: String(repeating: "word ", count: 300), links: [])
                                ]), html: "h"))
        let (engine, _) = makeEngine(
            session: session, fetcher: FakeRescueHTMLFetcher(html: nil),
            pipeline: RecordingPipeline(results: [good]))
        let outcome = await engine.rescue(request(html: nil))

        XCTAssertEqual(session.planPrompts.count, 1, "the model must be asked anyway")
        XCTAssertTrue(session.planPrompts.first?.contains("PAGE DIGEST: unavailable") == true)
        guard case .rescued = outcome else { return XCTFail("a reroute needs no page HTML") }
    }

    /// …and the marker has to say the page is gone, or the model will happily
    /// answer "product" about a digest that isn't there.
    func testTheUnavailableDigestMarkerNamesWhatIsImpossible() async {
        let session = FakeRescueModelSession(responses: [.plan(RescuePlanResponse(kind: "give_up"))])
        let (engine, _) = makeEngine(session: session, fetcher: FakeRescueHTMLFetcher(html: nil))
        _ = await engine.rescue(request(html: nil))
        let prompt = session.planPrompts.first ?? ""
        XCTAssertTrue(prompt.contains("reroute, search"))
        XCTAssertTrue(prompt.contains("impossible"))
    }

    // MARK: - search

    private func searchResult(_ urlString: String, _ title: String) -> RescueSearchResult {
        RescueSearchResult(url: URL(string: urlString)!, title: title)
    }

    /// The model emits a QUERY; the engine runs it and the model picks from the
    /// real results. Two rounds, and the second prompt is the result listing.
    func testSearchRunsTheQueryThenLetsTheModelPick() async {
        let search = FakeRescueSearch(results: [
            searchResult("https://www.example.com/2024/story-full", "The Vanishing Middle Class of Rome"),
        ])
        let good = IngestResult(url: URL(string: "https://www.example.com/2024/story-full")!,
                                outcome: .article(ArticleContent(title: "T", blocks: [
                                    .init(kind: .paragraph, text: String(repeating: "word ", count: 300), links: [])
                                ]), html: "h"))
        let session = FakeRescueModelSession(responses: [
            .plan(RescuePlanResponse(kind: "search", searchQuery: "vanishing middle class rome")),
            .plan(RescuePlanResponse(kind: "reroute", rerouteURLString: "https://www.example.com/2024/story-full")),
        ])
        let (engine, pipe) = makeEngine(
            session: session, search: search, pipeline: RecordingPipeline(results: [good]))
        let outcome = await engine.rescue(evidenceRequest(itemID: UUID()))

        XCTAssertEqual(search.queries, ["vanishing middle class rome"])
        guard case .rescued(_, let method) = outcome else { return XCTFail("expected a rescue") }
        XCTAssertEqual(method, .search, "a search-sourced reroute is its own method")
        XCTAssertEqual(pipe.inputs.count, 1, "still exactly one pipeline re-entry")
        XCTAssertEqual(session.planPrompts.count, 2)
        XCTAssertTrue(session.planPrompts[1].contains("--- SEARCH RESULTS (untrusted) ---"))
        XCTAssertTrue(session.planPrompts[1].contains("story-full"))
    }

    /// The relaxation is for URLs the ENGINE offered, not for any URL the model
    /// can name — otherwise "search" would be a hole straight through the reroute
    /// host policy.
    func testAModelInventedURLIsRejectedEvenInASearchRound() async {
        let search = FakeRescueSearch(results: [
            searchResult("https://www.example.com/2024/story-full", "The Vanishing Middle Class of Rome"),
        ])
        let session = FakeRescueModelSession(responses: [
            .plan(RescuePlanResponse(kind: "search", searchQuery: "middle class rome")),
            .plan(RescuePlanResponse(kind: "reroute", rerouteURLString: "https://attacker.test/exfiltrate")),
        ])
        let (engine, pipe) = makeEngine(session: session, search: search)
        let outcome = await engine.rescue(evidenceRequest(itemID: UUID()))
        guard case .unrescuable = outcome else { return XCTFail("an off-list URL must be refused") }
        XCTAssertTrue(pipe.inputs.isEmpty)
    }

    /// A cross-domain result is a DIFFERENT thing unless the title says otherwise —
    /// and for a product or a media post it is a different thing regardless.
    func testCrossDomainCandidatesNeedATitleMatch() {
        let request = RescueRequest(
            url: url, source: .manual, failureKind: .articleFailed,
            pageTitle: "The Vanishing Middle Class of Rome")
        let validator = RescueDirectiveValidator()
        let kept = RescueSearchCandidates.filter([
            searchResult("https://syndicated.test/rome", "The Vanishing Middle Class of Rome"),
            searchResult("https://unrelated.test/other", "Cheap Flights to Rome"),
        ], request: request, registrableDomain: { validator.registrableDomain($0) })
        XCTAssertEqual(kept.map(\.url.host), ["syndicated.test"])
    }

    func testAProductSearchNeverLeavesTheOriginalDomain() {
        let request = RescueRequest(
            url: url, source: .manual, failureKind: .productNoPrice, hint: .product,
            pageTitle: "Acme Widget Pro 3000")
        let validator = RescueDirectiveValidator()
        let kept = RescueSearchCandidates.filter([
            searchResult("https://otherseller.test/widget", "Acme Widget Pro 3000"),
            searchResult("https://www.example.com/widget", "Acme Widget Pro 3000"),
        ], request: request, registrableDomain: { validator.registrableDomain($0) })
        XCTAssertEqual(kept.map(\.url.host), ["www.example.com"])
    }

    func testASearchThatFindsNothingIsUnrescuableRatherThanFreeform() async {
        let session = FakeRescueModelSession(responses: [
            .plan(RescuePlanResponse(kind: "search", searchQuery: "nothing at all")),
        ])
        let (engine, _) = makeEngine(session: session, search: FakeRescueSearch(results: []))
        let outcome = await engine.rescue(evidenceRequest(itemID: UUID()))
        guard case .unrescuable = outcome else { return XCTFail("no candidates → unrescuable") }
        XCTAssertEqual(session.planPrompts.count, 1, "no second call without candidates")
    }

    // MARK: - inspect_url

    func testInspectRoundDigestsThePageAndThenCommits() async {
        let good = IngestResult(url: URL(string: "https://amp.example.com/story")!,
                                outcome: .article(ArticleContent(title: "T", blocks: [
                                    .init(kind: .paragraph, text: String(repeating: "word ", count: 300), links: [])
                                ]), html: "h"))
        let session = FakeRescueModelSession(responses: [
            .plan(RescuePlanResponse(kind: "inspect_url", rerouteURLString: "https://amp.example.com/index")),
            .plan(RescuePlanResponse(kind: "reroute", rerouteURLString: "https://amp.example.com/story")),
        ])
        let (engine, _) = makeEngine(
            session: session,
            fetcher: FakeRescueHTMLFetcher(html: "<html><body>the index page</body></html>"),
            pipeline: RecordingPipeline(results: [good]))
        let outcome = await engine.rescue(evidenceRequest(itemID: UUID()))

        guard case .rescued = outcome else { return XCTFail("expected a rescue after inspection") }
        XCTAssertEqual(session.planPrompts.count, 2)
        XCTAssertTrue(session.planPrompts[1].contains("You asked to inspect: https://amp.example.com/index"))
        XCTAssertTrue(session.planPrompts[1].contains("INSPECTED PAGE DIGEST"))
    }

    /// The round cap is structural — the follow-up call is validated with
    /// intermediate kinds refused, so a model that asks to inspect again is
    /// rejected instead of looping. This is the test that would catch someone
    /// moving the bound into the prompt.
    func testASecondInspectRequestIsRefusedRatherThanLooping() async {
        let session = FakeRescueModelSession(responses: [
            .plan(RescuePlanResponse(kind: "inspect_url", rerouteURLString: "https://amp.example.com/a")),
            .plan(RescuePlanResponse(kind: "inspect_url", rerouteURLString: "https://amp.example.com/b")),
            .plan(RescuePlanResponse(kind: "reroute", rerouteURLString: "https://amp.example.com/story")),
        ])
        let (engine, pipe) = makeEngine(
            session: session,
            fetcher: FakeRescueHTMLFetcher(html: "<html><body>page</body></html>"))
        let outcome = await engine.rescue(evidenceRequest(itemID: UUID()))
        guard case .unrescuable = outcome else { return XCTFail("a second inspect must be refused") }
        XCTAssertEqual(session.planPrompts.count, 2, "exactly one inspect round")
        XCTAssertTrue(pipe.inputs.isEmpty)
    }

    /// Likewise for search: one intermediate round, whichever kind it was.
    func testASearchInsideASearchRoundIsRefused() async {
        let search = FakeRescueSearch(results: [
            searchResult("https://www.example.com/other", "The Vanishing Middle Class of Rome"),
        ])
        let session = FakeRescueModelSession(responses: [
            .plan(RescuePlanResponse(kind: "search", searchQuery: "one")),
            .plan(RescuePlanResponse(kind: "search", searchQuery: "two")),
        ])
        let (engine, _) = makeEngine(session: session, search: search)
        let outcome = await engine.rescue(evidenceRequest(itemID: UUID()))
        guard case .unrescuable = outcome else { return XCTFail("nested search must be refused") }
        XCTAssertEqual(search.queries, ["one"])
    }

    /// An inspect URL is held to the same host policy as a reroute — the round is
    /// a free fetch, and a free fetch of any host the model names is an
    /// exfiltration channel.
    func testAnOffHostInspectURLIsRejectedBeforeAnyFetch() async {
        let session = FakeRescueModelSession(responses: [
            .plan(RescuePlanResponse(kind: "inspect_url", rerouteURLString: "https://attacker.test/collect")),
        ])
        let (engine, _) = makeEngine(session: session)
        let outcome = await engine.rescue(evidenceRequest(itemID: UUID()))
        guard case .unrescuable = outcome else { return XCTFail("off-host inspect must be rejected") }
        XCTAssertEqual(session.planPrompts.count, 1)
    }

    // MARK: - open_in_browser

    func testTheModelCanRouteToTheBrowserUnlockTier() async {
        let session = FakeRescueModelSession(responses: [
            .plan(RescuePlanResponse(kind: "open_in_browser")),
        ])
        let (engine, pipe) = makeEngine(session: session)
        let outcome = await engine.rescue(evidenceRequest(itemID: UUID(), reason: .notReadable))
        guard case .needsBrowser = outcome else { return XCTFail("expected the browser handoff") }
        XCTAssertTrue(pipe.inputs.isEmpty, "nothing is fetched — that is the whole finding")
        XCTAssertFalse(outcome.spendsVersionAttempt)
    }

    /// The deterministic leg: a client-refusal status with an untried archive
    /// tier goes straight there, ahead of the model.
    func testABrowserRecoverableRefusalSkipsTheModelEntirely() async {
        let session = FakeRescueModelSession(responses: [])
        let (engine, _) = makeEngine(session: session)
        let outcome = await engine.rescue(evidenceRequest(itemID: UUID(), reason: .httpStatus(403)))
        guard case .needsBrowser = outcome else { return XCTFail("expected the fast path") }
        XCTAssertEqual(session.prewarmCount, 0, "the fast path must not touch the model")
    }

    /// Once the user has been offered the unlock screen, a second handoff would
    /// just re-park a card they already chose not to unlock — so the model gets
    /// its turn instead.
    func testASecondBrowserHandoffFallsThroughToTheModel() async {
        let session = FakeRescueModelSession(responses: [.plan(RescuePlanResponse(kind: "give_up"))])
        let (engine, _) = makeEngine(session: session)
        let request = RescueRequest(
            url: url, source: .manual, failureKind: .articleFailed, hint: nil,
            fetchedHTML: "<html><body>x</body></html>", itemID: UUID(),
            failureReason: .httpStatus(403), browserHandoffTried: true)
        let outcome = await engine.rescue(request)
        guard case .unrescuable = outcome else { return XCTFail("expected the model's give_up") }
        XCTAssertEqual(session.planPrompts.count, 1)
    }

    /// A 404 is not a refusal — the page is gone and no client can conjure it, so
    /// the fast path must not fire.
    func testAGoneStatusDoesNotTakeTheBrowserFastPath() async {
        let session = FakeRescueModelSession(responses: [.plan(RescuePlanResponse(kind: "give_up"))])
        let (engine, _) = makeEngine(session: session)
        let outcome = await engine.rescue(evidenceRequest(itemID: UUID(), reason: .httpStatus(404)))
        guard case .unrescuable = outcome else { return XCTFail("404 must reach the model") }
    }

    // MARK: - Stats

    func testEachOutcomeIncrementsItsOwnCounter() async {
        let stats = RescueStatsStore(containerURL: scratch)
        let session = FakeRescueModelSession(responses: [
            .plan(RescuePlanResponse(kind: "give_up")),
            .failure(.guardrailViolation),
        ])
        let (engine, _) = makeEngine(session: session, stats: stats)
        _ = await engine.rescue(request())
        _ = await engine.rescue(request())

        let snapshot = stats.snapshot()
        XCTAssertEqual(snapshot.attempts, 2)
        XCTAssertEqual(snapshot.outcome(.unrescuable), 1)
        XCTAssertEqual(snapshot.outcome(.guardrailed), 1)
    }

    func testASuccessfulRescueIsCountedByItsMethod() async {
        let stats = RescueStatsStore(containerURL: scratch)
        let good = IngestResult(url: URL(string: "https://amp.example.com/story")!,
                                outcome: .article(ArticleContent(title: "T", blocks: [
                                    .init(kind: .paragraph, text: String(repeating: "word ", count: 300), links: [])
                                ]), html: "h"))
        let session = FakeRescueModelSession(responses: [
            .plan(RescuePlanResponse(kind: "reroute", rerouteURLString: "https://amp.example.com/story"))
        ])
        let (engine, _) = makeEngine(session: session, stats: stats,
                                     pipeline: RecordingPipeline(results: [good]))
        _ = await engine.rescue(request(hint: .article))

        XCTAssertEqual(stats.snapshot().outcome(.rescued), 1)
        XCTAssertEqual(stats.snapshot().methods["reroute"], 1)
        XCTAssertTrue(stats.summaryLine().contains("rescued=1"))
    }

    // MARK: - RescueDigestBuilder

    func testRespectsCharacterBudget() {
        let big = String(repeating: "<p>lorem ipsum dolor sit amet consectetur adipiscing elit </p>", count: 5000)
        let html = "<html><head><title>T</title></head><body>\(big)</body></html>"
        let digest = builder.buildDigest(url: url, html: html, hint: .article, budget: .onDevice)
        XCTAssertLessThanOrEqual(digest.count, RescueDigestBudget.onDevice.maxCharacters)
    }

    func testHeadMetadataIncluded() {
        let html = """
        <html><head><title>Headline</title>
        <meta name="description" content="A great story">
        <meta property="og:title" content="OG Headline">
        <link rel="canonical" href="https://www.example.com/story">
        </head><body><p>Body text here.</p></body></html>
        """
        let digest = builder.buildDigest(url: url, html: html, hint: .article, budget: .privateCloud)
        XCTAssertTrue(digest.contains("Headline"))
        XCTAssertTrue(digest.contains("A great story"))
        XCTAssertTrue(digest.contains("canonical"))
    }

    func testJSONLDProductRankedFirst() {
        let html = """
        <html><head>
        <script type="application/ld+json">{"@type":"WebPage","name":"generic"}</script>
        <script type="application/ld+json">{"@type":"Product","offers":{"price":"9.99"}}</script>
        </head><body></body></html>
        """
        let digest = builder.buildDigest(url: url, html: html, hint: .product, budget: .privateCloud)
        let productIdx = digest.range(of: "\"Product\"")?.lowerBound
        let genericIdx = digest.range(of: "\"generic\"")?.lowerBound
        XCTAssertNotNil(productIdx)
        XCTAssertNotNil(genericIdx)
        if let p = productIdx, let g = genericIdx { XCTAssertLessThan(p, g) }
    }

    func testMediaHintGrepsMediaURLs() {
        let html = """
        <html><body><script>var x = {"playable_url":"https://cdn.net/v.mp4"};</script></body></html>
        """
        let digest = builder.buildDigest(url: url, html: html, hint: .media, budget: .privateCloud)
        XCTAssertTrue(digest.contains("playable_url") || digest.contains("v.mp4"))
    }

    func testCandidateURLsCappedAt30() {
        var links = ""
        for i in 0..<60 { links += "<a href=\"https://www.example.com/amp/\(i)\">l</a>" }
        let html = "<html><body>\(links)</body></html>"
        let digest = builder.buildDigest(url: url, html: html, hint: .article, budget: .privateCloud)
        let count = digest.components(separatedBy: "link: ").count - 1
        XCTAssertLessThanOrEqual(count, 30)
    }

    func testMalformedHTMLDegradesGracefully() {
        let html = "<<<not really html >>> plain text body content here for the digest"
        let digest = builder.buildDigest(url: url, html: html, hint: .article, budget: .onDevice)
        XCTAssertFalse(digest.isEmpty)
    }

    func testHalvedBudgetIsSmaller() {
        XCTAssertLessThan(RescueDigestBudget.onDevice.halved.maxCharacters, RescueDigestBudget.onDevice.maxCharacters)
    }

    func testTokenEstimate() {
        XCTAssertEqual(RescueDigestBudget.estimatedTokens(forCharacters: 400), 100)
    }

    // MARK: - RescueWebScriptWrapping
    //
    // Pure tests of the JS wrapper + the applier's JSON-shell wrapping. The
    // WebView itself isn't unit-tested (same as WebViewPriceRenderer).

    func testWrapProducesTryCatchIIFE() {
        let wrapped = RescueWebScriptRunner.wrap("return 'hi';")
        XCTAssertTrue(wrapped.contains("try"))
        XCTAssertTrue(wrapped.contains("catch"))
        XCTAssertTrue(wrapped.contains("return 'hi';"))
        // Always yields a string / empty-string, never throws out.
        XCTAssertTrue(wrapped.contains("typeof r"))
    }

    func testJSONResultWrappedAsJSONLDShell() {
        let shell = RescueDirectiveApplier.wrapJSONAsHTML("{\"@type\":\"Product\"}")
        XCTAssertTrue(shell.contains("application/ld+json"))
        XCTAssertTrue(shell.contains("{\"@type\":\"Product\"}"))
    }

    func testDirectAssetKindInference() {
        XCTAssertEqual(RescueDirectiveApplier.directAsset(from: URL(string: "https://x/y.mp4")!)?.kind, .video)
        XCTAssertEqual(RescueDirectiveApplier.directAsset(from: URL(string: "https://x/y.jpg")!)?.kind, .image)
        XCTAssertEqual(RescueDirectiveApplier.directAsset(from: URL(string: "https://x/y.mp3")!)?.kind, .audio)
        XCTAssertNil(RescueDirectiveApplier.directAsset(from: URL(string: "https://x/y.html")!))
    }

    func testOpenGraphContentExtraction() {
        let html = "<meta property=\"og:video\" content=\"https://cdn/v.mp4\">"
        XCTAssertEqual(RescueDirectiveApplier.openGraphContent(named: "og:video", in: html), "https://cdn/v.mp4")
    }

    // MARK: - ShareSurfaceDriverRescue
    //
    // The `.failed` rescue-handoff behavior of `ShareSurfaceDriver`: the action
    // extension presents the rescue card (and marks the row failed); the zero-UI
    // share extension completes silently (and marks it failed) with no card.

    private final class FakeHost: ExtensionHost {
        var readerMode: ExtensionReaderMode?
        private(set) var presented: [UIViewController] = []
        private(set) var completedSilently = 0
        private(set) var openedURLs: [URL] = []
        init(isActionExtension: Bool) { readerMode = isActionExtension ? .reader : nil }
        func presentModally(_ vc: UIViewController) { presented.append(vc) }
        func confirmSavedThenComplete() {}
        func completeSilently() { completedSilently += 1 }
        func autoDownloadThenComplete(urlString: String) {}
        func failOrComplete(_ message: String) {}
        func openURL(_ url: URL) { openedURLs.append(url) }
    }

    /// The extension no longer asks what the save should become — the model
    /// classifies the page when the app drains the queue — so the queued record
    /// must carry NO hint. A hint here would silently pin the answer and undo the
    /// classification (a nil hint).
    func testQueuedRescueRequestCarriesNoContentHint() {
        _ = PendingRescueRequestStore.shared.takeAll()   // start from a clean queue
        let host = FakeHost(isActionExtension: true)
        let driver = ShareSurfaceDriver(host: host, store: store, surfaceDecision: { _ in .supported })
        let url = URL(string: "https://example.com/broken")!
        _ = store.add(urlString: url.absoluteString)

        driver.present(.failed(nil), url: url)
        guard let card = host.presented.compactMap({ $0 as? RescueFailureViewController }).first
        else { return XCTFail("expected the rescue card") }
        card.recordPendingRescueForTesting()

        let queued = PendingRescueRequestStore.shared.takeAll()
        guard let request = queued.first(where: { $0.urlString == url.absoluteString }) else {
            return XCTFail("expected a queued rescue request")
        }
        XCTAssertNil(request.hint)
    }
}
