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
    private var previousURLPolicy = true
    private let url = URL(string: "https://www.youtube.com/watch?v=dQw4w9WgXcQ")!

    override func setUp() {
        super.setUp()
        previousStage = IngestPipeline.pluginStage
        previousURLPolicy = URLBehaviorPolicy.pluginsOnly
        // These legacy-floor tests explicitly exercise sibling/native policy.
        URLBehaviorPolicy.pluginsOnly = false
    }

    override func tearDown() {
        IngestPipeline.pluginStage = previousStage
        URLBehaviorPolicy.pluginsOnly = previousURLPolicy
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

    /// Under legacy/native policy with no plugin stage, intent-specific failure
    /// only applies after a stage has actually declined. Reader's current
    /// plugin-only policy is covered separately below.
    func testWithoutAStageTheIntentRuleNeverFires() async {
        IngestPipeline.pluginStage = nil
        let outcome = await process(intent: .transcribe)
        guard case .video(.youtube, _) = outcome else {
            return XCTFail("expected the Swift floor's .video, got \(outcome)")
        }
    }
    func testPluginOnlyReaderKeepsPlainSavesAsLinksWhenPluginsDecline() async {
        URLBehaviorPolicy.pluginsOnly = true
        _ = installDecliningStage()
        let outcome = await process(intent: nil)
        XCTAssertEqual(outcome, .link)
    }

    func testPluginOnlyReaderCannotUseNativeDownloadAsTranscriptionFallback() async {
        URLBehaviorPolicy.pluginsOnly = true
        IngestPipeline.pluginStage = nil
        let outcome = await process(intent: .transcribe)
        XCTAssertEqual(outcome, .failed(.noTranscriptSource))
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
