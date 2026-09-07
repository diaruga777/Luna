//
//  PluginIngestStageTests.swift
//  LunaTests
//

import XCTest
import LunaIngest
import LunaModels
import LunaPluginIngest
import LunaPluginKit

/// The plugin walk's behaviour (`claudedocs/plans/plugin-platform.md` §7.4),
/// driven by a scripted invoker so no JavaScript runs.
final class PluginIngestStageTests: XCTestCase {

    private var scope = PluginAdopterScope()
    private var adopter = FakeMediaModelAdopter()
    private let url = URL(string: "https://example.com/p/abc")!

    override func setUp() {
        super.setUp()
        scope = PluginAdopterScope()
        adopter = FakeMediaModelAdopter()
        PluginModelAdopters.media = adopter
        PluginModelAdopters.article = nil
        PluginModelAdopters.product = nil
    }

    override func tearDown() {
        scope.restore()
        super.tearDown()
    }

    private func stage(_ invoker: FakePluginInvoker) -> PluginIngestStage {
        PluginIngestStage(invoker: invoker, processKind: .app)
    }

    private func run(_ invoker: FakePluginInvoker) async -> PluginIngestVerdict {
        await run(invoker, input: IngestInput(url: url, source: .manual))
    }

    private func run(_ invoker: FakePluginInvoker, input: IngestInput) async -> PluginIngestVerdict {
        await stage(invoker).run(input, fetcher: MockArticleFetcher())
    }

    private static let articleClaim = #"{"kind":"article","itemId":"abc"}"#
    private static let transcriptionModel = """
        {"kind":"article","title":"A talk","author":"Someone","language":"en",
         "transcription":{"url":"https://cdn.example.com/a.m4a","type":"audio"}}
        """
    private static let sampleRequest = TranscriptionRequest(
        mediaURL: URL(string: "https://cdn.example.com/a.m4a")!, mediaKind: .audio,
        title: "A talk", pluginID: "t")

    private static let mediaClaim = #"{"kind":"media","itemId":"abc"}"#
    private static let mediaModel = """
        {"kind":"media","title":"A clip","platform":"instagram",
         "assets":[{"url":"https://cdn.example.com/v.mp4","type":"video","quality":"1080p"}]}
        """

    // MARK: - Order and the floor

    func testNoMatchedPluginPassesToTheSwiftClassifier() async {
        let invoker = FakePluginInvoker()
        invoker.loadedPlugins = [.fake(id: "a", hosts: ["other.test"])]
        guard case .passed = await run(invoker) else { return XCTFail("expected .passed") }
        XCTAssertTrue(invoker.calls.isEmpty, "an unmatched plugin must not be asked anything")
    }

    func testTheWalkFollowsTheInvokersOrderAndStopsAtTheFirstClaim() async {
        let invoker = FakePluginInvoker()
        invoker.loadedPlugins = [.fake(id: "first"), .fake(id: "second")]
        invoker.classifyAnswers["first"] = .json("false")
        invoker.classifyAnswers["second"] = .json(Self.mediaClaim)
        invoker.ingestAnswers["second"] = .json(Self.mediaModel)

        guard case let .outcome(_, pluginID) = await run(invoker) else {
            return XCTFail("expected an outcome")
        }
        XCTAssertEqual(pluginID, "second")
        XCTAssertEqual(
            invoker.calls.map { "\($0.hook.rawValue):\($0.pluginID)" },
            ["classify:first", "classify:second", "ingest:second"],
            "the walk asks classify in order and ingests only the first claimant")
    }

    func testEveryPluginDecliningFallsThroughToTheSwiftClassifier() async {
        let invoker = FakePluginInvoker()
        invoker.loadedPlugins = [.fake(id: "a"), .fake(id: "b")]
        invoker.classifyAnswers["a"] = .json("false")
        invoker.classifyAnswers["b"] = .json("false")
        guard case .passed = await run(invoker) else { return XCTFail("expected .passed") }
    }

    /// The blocker the plan calls "claimed, then declined": a plugin that reads
    /// the page and answers `null` must not consume the URL.
    func testNullFromIngestContinuesTheWalk() async {
        let invoker = FakePluginInvoker()
        invoker.loadedPlugins = [.fake(id: "a"), .fake(id: "b")]
        invoker.classifyAnswers["a"] = .json(Self.mediaClaim)
        invoker.ingestAnswers["a"] = .json("null")
        invoker.classifyAnswers["b"] = .json(Self.mediaClaim)
        invoker.ingestAnswers["b"] = .json(Self.mediaModel)

        guard case let .outcome(_, pluginID) = await run(invoker) else {
            return XCTFail("expected an outcome")
        }
        XCTAssertEqual(pluginID, "b")
    }

    /// A plugin that throws, times out or wedges must never fail a save the
    /// Swift floor could have made.
    func testABrokenPluginDoesNotFailTheSave() async {
        for failure: PluginInvocationFailure in [
            .timedOut, .wedged, .exception(message: "boom", stack: nil), .runtime("bridge"),
        ] {
            let invoker = FakePluginInvoker()
            invoker.loadedPlugins = [.fake(id: "a")]
            invoker.classifyAnswers["a"] = .json(Self.mediaClaim)
            invoker.ingestAnswers["a"] = .failure(failure)
            guard case .passed = await run(invoker) else {
                return XCTFail("expected .passed for \(failure)")
            }
        }
    }

    /// An adopter answering `.failed` is the same case: the plugin's Model was
    /// unreadable, and the Swift floor has not had its turn yet.
    func testAnAdopterFailureDoesNotFailTheSave() async {
        let invoker = FakePluginInvoker()
        invoker.loadedPlugins = [.fake(id: "a")]
        invoker.classifyAnswers["a"] = .json(Self.mediaClaim)
        invoker.ingestAnswers["a"] = .json(Self.mediaModel)
        adopter.outcome = .failed(.notReadable)
        guard case .passed = await run(invoker) else { return XCTFail("expected .passed") }
    }

    func testAnAdopterFailureLetsTheNextMatchedPluginTry() async {
        let invoker = FakePluginInvoker()
        invoker.loadedPlugins = [.fake(id: "a"), .fake(id: "b")]
        invoker.classifyAnswers["a"] = .json(Self.mediaClaim)
        invoker.ingestAnswers["a"] = .json(Self.mediaModel)
        invoker.classifyAnswers["b"] = .json(Self.mediaClaim)
        invoker.ingestAnswers["b"] = .json(Self.mediaModel)
        PluginModelAdopters.media = FailingForOnePluginMediaAdopter(failingPluginID: "a")

        guard case let .outcome(_, pluginID) = await run(invoker) else {
            return XCTFail("expected an outcome")
        }
        XCTAssertEqual(pluginID, "b")
    }

    // MARK: - The intent

    /// A plugin written before intents existed must see the input it always
    /// saw: no `intent` key at all for an ordinary save.
    func testAnOrdinarySaveCarriesNoIntentKeyToEitherHook() async {
        let invoker = FakePluginInvoker()
        invoker.loadedPlugins = [.fake(id: "a")]
        invoker.classifyAnswers["a"] = .json(Self.mediaClaim)
        invoker.ingestAnswers["a"] = .json(Self.mediaModel)

        _ = await run(invoker)

        XCTAssertEqual(invoker.encodedArguments.count, 2)
        for argument in invoker.encodedArguments {
            XCTAssertNil(argument.json["intent"], "\(argument.hook) carried an intent for a plain save")
        }
    }

    func testTheTranscribeIntentReachesBothHooksAsAString() async {
        let invoker = FakePluginInvoker()
        invoker.loadedPlugins = [.fake(id: "a")]
        invoker.classifyAnswers["a"] = .json(Self.mediaClaim)
        invoker.ingestAnswers["a"] = .json(Self.mediaModel)

        _ = await run(invoker, input: IngestInput(url: url, source: .manual, intent: .transcribe))

        let intents = invoker.encodedArguments.map { $0.json["intent"] as? String }
        XCTAssertEqual(intents, ["transcribe", "transcribe"])
    }

    /// A media plugin that declines the transcribe intent (as every bundled one
    /// does) lets the transcript plugin behind it claim.
    func testADecliningMediaPluginLetsTheTranscriptPluginClaim() async {
        let invoker = FakePluginInvoker()
        invoker.loadedPlugins = [
            .fake(id: "media", priority: 100),
            .fake(id: "t", priority: 90, produces: [.article]),
        ]
        invoker.classifyAnswers["media"] = .json("false")
        invoker.classifyAnswers["t"] = .json(Self.articleClaim)
        invoker.ingestAnswers["t"] = .json(Self.transcriptionModel)
        let article = FakeArticleModelAdopter()
        article.outcome = .transcription(Self.sampleRequest)
        PluginModelAdopters.article = article

        guard case let .outcome(outcome, pluginID) = await run(
            invoker, input: IngestInput(url: url, source: .manual, intent: .transcribe))
        else { return XCTFail("expected an outcome") }
        XCTAssertEqual(pluginID, "t")
        XCTAssertEqual(outcome, .transcription(Self.sampleRequest))
        XCTAssertEqual(article.seen.first?.transcription?.type, .audio)
    }

    // MARK: - The browser lock

    func testBrowserDeferredLocksTheSaveAndNamesTheOwner() async {
        let invoker = FakePluginInvoker()
        invoker.loadedPlugins = [.fake(id: "locker"), .fake(id: "later")]
        invoker.classifyAnswers["locker"] = .json(Self.mediaClaim)
        invoker.ingestAnswers["locker"] = .failure(.browserDeferred)
        invoker.classifyAnswers["later"] = .json(Self.mediaClaim)
        invoker.ingestAnswers["later"] = .json(Self.mediaModel)

        guard case let .locked(pluginID) = await run(invoker) else {
            return XCTFail("expected .locked")
        }
        XCTAssertEqual(pluginID, "locker")
        XCTAssertFalse(
            invoker.calls.contains { $0.pluginID == "later" },
            "a lock ends the walk — the save waits for its browser step")
    }

    // MARK: - `produces`

    func testAModelOfAnUndeclaredKindIsRefused() async {
        let invoker = FakePluginInvoker()
        invoker.loadedPlugins = [.fake(id: "a", produces: [.media])]
        invoker.classifyAnswers["a"] = .json(Self.mediaClaim)
        // Claims media, returns an article.
        invoker.ingestAnswers["a"] = .json(#"{"kind":"article","title":"T","html":"<p>x</p>"}"#)
        guard case .passed = await run(invoker) else { return XCTFail("expected .passed") }
    }

    func testAClaimOfAnUndeclaredKindIsNotIngested() async {
        let invoker = FakePluginInvoker()
        invoker.loadedPlugins = [.fake(id: "a", produces: [.media])]
        invoker.classifyAnswers["a"] = .json(#"{"kind":"product"}"#)
        invoker.ingestAnswers["a"] = .json(Self.mediaModel)
        guard case .passed = await run(invoker) else { return XCTFail("expected .passed") }
        XCTAssertFalse(invoker.calls.contains { $0.hook == .ingest })
    }

    func testAKindWithNoAdopterInThisAppIsSkipped() async {
        PluginModelAdopters.media = nil
        let invoker = FakePluginInvoker()
        invoker.loadedPlugins = [.fake(id: "a")]
        invoker.classifyAnswers["a"] = .json(Self.mediaClaim)
        invoker.ingestAnswers["a"] = .json(Self.mediaModel)
        guard case .passed = await run(invoker) else { return XCTFail("expected .passed") }
    }

    // MARK: - Relative URLs

    func testRelativeModelURLsAreResolvedAgainstTheSaveURL() async {
        let invoker = FakePluginInvoker()
        invoker.loadedPlugins = [.fake(id: "a")]
        invoker.classifyAnswers["a"] = .json(Self.mediaClaim)
        invoker.ingestAnswers["a"] = .json("""
            {"kind":"media","assets":[{"url":"/media/v.mp4","type":"video"}]}
            """)
        let capture = CapturingMediaAdopter()
        PluginModelAdopters.media = capture

        _ = await run(invoker)
        XCTAssertEqual(
            capture.seen?.assets.first?.url.absoluteString,
            "https://example.com/media/v.mp4",
            "a path a plugin wrote is made absolute before any kind module sees it")
    }

    func testAnAbsoluteModelURLIsUnchanged() async {
        let invoker = FakePluginInvoker()
        invoker.loadedPlugins = [.fake(id: "a")]
        invoker.classifyAnswers["a"] = .json(Self.mediaClaim)
        invoker.ingestAnswers["a"] = .json(Self.mediaModel)
        let capture = CapturingMediaAdopter()
        PluginModelAdopters.media = capture

        _ = await run(invoker)
        XCTAssertEqual(
            capture.seen?.assets.first?.url.absoluteString, "https://cdn.example.com/v.mp4")
    }

    // MARK: - The outcome shape

    func testAVideoAssetProducesTheSameOutcomeTheSwiftPathProduces() async {
        let invoker = FakePluginInvoker()
        invoker.loadedPlugins = [.fake(id: "a")]
        invoker.classifyAnswers["a"] = .json(Self.mediaClaim)
        invoker.ingestAnswers["a"] = .json(Self.mediaModel)

        guard case let .outcome(outcome, _) = await run(invoker) else {
            return XCTFail("expected an outcome")
        }
        guard case let .video(platform, itemID) = outcome else {
            return XCTFail("expected .video, got \(outcome)")
        }
        XCTAssertEqual(platform, .web)
        XCTAssertEqual(itemID, "abc")
    }

    func testAnImageOnlyModelProducesASocialOutcome() async {
        let invoker = FakePluginInvoker()
        invoker.loadedPlugins = [.fake(id: "a")]
        invoker.classifyAnswers["a"] = .json(Self.mediaClaim)
        invoker.ingestAnswers["a"] = .json("""
            {"kind":"media","assets":[{"url":"https://cdn.example.com/i.jpg","type":"image"}]}
            """)
        adopter.outcome = .media(
            assets: [MediaAsset(url: URL(string: "https://cdn.example.com/i.jpg")!, kind: .image)],
            platform: .instagram, itemID: "abc", title: nil, thumbnailURL: nil)

        guard case let .outcome(outcome, _) = await run(invoker),
              case let .social(platform, _) = outcome
        else { return XCTFail("expected .social") }
        XCTAssertEqual(platform, .instagram)
    }

    func testAnAdopterThatKeptNothingContinuesTheWalk() async {
        let invoker = FakePluginInvoker()
        invoker.loadedPlugins = [.fake(id: "a")]
        invoker.classifyAnswers["a"] = .json(Self.mediaClaim)
        invoker.ingestAnswers["a"] = .json(Self.mediaModel)
        adopter.outcome = .declined
        guard case .passed = await run(invoker) else { return XCTFail("expected .passed") }
    }

    // MARK: - The hook argument

    /// A plugin names the item once, in `classify`; the Model need not repeat it.
    func testTheClaimsItemIDReachesTheAdopterWhenTheModelOmitsIt() async {
        let invoker = FakePluginInvoker()
        invoker.loadedPlugins = [.fake(id: "a")]
        invoker.classifyAnswers["a"] = .json(Self.mediaClaim)
        invoker.ingestAnswers["a"] = .json(Self.mediaModel)
        let capture = CapturingMediaAdopter()
        PluginModelAdopters.media = capture

        _ = await run(invoker)
        XCTAssertEqual(capture.seen?.itemID, "abc")
    }

    func testASaveCallsIngestWithTheSaveReason() async {
        let invoker = FakePluginInvoker()
        invoker.loadedPlugins = [.fake(id: "a")]
        invoker.classifyAnswers["a"] = .json(Self.mediaClaim)
        invoker.ingestAnswers["a"] = .json(Self.mediaModel)
        _ = await run(invoker)
        XCTAssertEqual(invoker.ingestReasons, ["save"])
    }
}

/// Fails adoption for one plugin id and adopts for every other, so a test can
/// watch the walk carry on past a failed adoption.
private final class FailingForOnePluginMediaAdopter: MediaModelAdopting {
    private let failingPluginID: String

    init(failingPluginID: String) { self.failingPluginID = failingPluginID }

    func adopt(_ model: MediaModel, url: URL, pluginID: String) async -> PluginAdoptedOutcome {
        guard pluginID != failingPluginID else { return .failed(.notReadable) }
        return .media(
            assets: model.assets.map { MediaAsset(url: $0.url, kind: .video) },
            platform: .web, itemID: model.itemID, title: model.title, thumbnailURL: nil)
    }
}

/// Records the Model the stage handed over, so a test can assert what the
/// adopter actually saw.
private final class CapturingMediaAdopter: MediaModelAdopting {
    var seen: MediaModel?

    func adopt(_ model: MediaModel, url: URL, pluginID: String) async -> PluginAdoptedOutcome {
        seen = model
        return .media(
            assets: model.assets.map { MediaAsset(url: $0.url, kind: .video) },
            platform: .web, itemID: model.itemID, title: model.title,
            thumbnailURL: model.thumbnailURL)
    }
}
