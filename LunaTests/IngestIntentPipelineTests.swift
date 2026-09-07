//
//  IngestIntentPipelineTests.swift
//  LunaTests
//

import XCTest
import LunaIngest
import LunaModels
import LunaPluginIngest
import LunaPluginKit

/// The one pipeline rule an intent adds (`claudedocs/plans/transcription-plugins.md`
/// decision 5): a transcribe request that every plugin passed on FAILS, where a
/// plain save of the same URL reaches the Swift classifier and becomes a
/// download.
///
/// The URL is a YouTube watch link, which the Swift classifier decides from the
/// URL alone, so neither run touches the network; the session refuses every
/// request anyway.
final class IngestIntentPipelineTests: XCTestCase {

    private var previousStage: PluginIngestStaging?
    private let url = URL(string: "https://www.youtube.com/watch?v=dQw4w9WgXcQ")!

    override func setUp() {
        super.setUp()
        previousStage = IngestPipeline.pluginStage
    }

    override func tearDown() {
        IngestPipeline.pluginStage = previousStage
        super.tearDown()
    }

    private func installDecliningStage() -> FakePluginInvoker {
        let invoker = FakePluginInvoker()
        invoker.loadedPlugins = [.fake(id: "media", hosts: ["www.youtube.com", "youtube.com"])]
        invoker.classifyAnswers["media"] = .json("false")
        IngestPipeline.pluginStage = PluginIngestStage(invoker: invoker, processKind: .app)
        return invoker
    }

    private func process(intent: IngestIntent?) async -> Outcome {
        await IngestPipeline.process(
            IngestInput(url: url, source: .manual, intent: intent),
            timeout: 10, session: RefusingProtocol.session(), fetcher: MockArticleFetcher(),
            articleProcessor: nil, productProcessor: nil, socialTextProcessor: nil)
    }

    func testATranscribeIntentNoPluginServesFailsRatherThanDownloading() async {
        let invoker = installDecliningStage()
        let outcome = await process(intent: .transcribe)
        XCTAssertEqual(outcome, .failed(.noTranscriptSource))
        XCTAssertEqual(invoker.calls.map(\.hook), [.classify], "the plugin was asked, and declined")
    }

    func testAPlainSaveOfTheSameURLStillReachesTheSwiftClassifier() async {
        _ = installDecliningStage()
        let outcome = await process(intent: nil)
        guard case let .video(platform, itemID) = outcome else {
            return XCTFail("expected the Swift floor's .video, got \(outcome)")
        }
        XCTAssertEqual(platform, .youtube)
        XCTAssertEqual(itemID, "dQw4w9WgXcQ")
    }

    /// With no plugin stage installed at all (the three sibling apps), an
    /// intent cannot change anything: there is no plugin to serve it and the
    /// rule only fires after a stage has passed.
    func testWithoutAStageTheIntentRuleNeverFires() async {
        IngestPipeline.pluginStage = nil
        let outcome = await process(intent: .transcribe)
        guard case .video(.youtube, _) = outcome else {
            return XCTFail("expected the Swift floor's .video, got \(outcome)")
        }
    }
}

/// A session whose every request fails at once, so a test that must stay off
/// the network fails loudly if something tries to reach it.
private final class RefusingProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }
    override func stopLoading() {}

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RefusingProtocol.self]
        return URLSession(configuration: configuration)
    }
}
