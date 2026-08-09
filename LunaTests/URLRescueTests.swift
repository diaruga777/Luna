//
//  URLRescueTests.swift
//  LunaTests
//

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
