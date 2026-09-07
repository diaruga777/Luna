//
//  PluginTranscriptionReresolverTests.swift
//  LunaTests
//

import XCTest
import LunaIngest
import LunaModels
import LunaPluginIngest
import LunaPluginKit

/// The re-resolution walk the runner asks for when a recording URL expired
/// (`claudedocs/plans/transcription-plugins.md` §5.3), driven by a scripted
/// invoker so no JavaScript runs.
final class PluginTranscriptionReresolverTests: XCTestCase {

    private var scope = PluginAdopterScope()
    private var article = FakeArticleModelAdopter()
    private let url = URL(string: "https://example.com/watch/abc")!
    private let saveID = UUID()

    override func setUp() {
        super.setUp()
        scope = PluginAdopterScope()
        article = FakeArticleModelAdopter()
        PluginModelAdopters.article = article
    }

    override func tearDown() {
        scope.restore()
        super.tearDown()
    }

    private static let claim = #"{"kind":"article","itemId":"abc"}"#
    private static let model = """
        {"kind":"article","title":"A talk",
         "transcription":{"url":"https://cdn.example.com/fresh.m4a","type":"audio"}}
        """
    private static let request = TranscriptionRequest(
        mediaURL: URL(string: "https://cdn.example.com/fresh.m4a")!, mediaKind: .audio,
        title: "A talk", pluginID: "t")

    private func invoker(pluginID: String = "t") -> FakePluginInvoker {
        let invoker = FakePluginInvoker()
        invoker.loadedPlugins = [.fake(id: pluginID, produces: [.article])]
        invoker.classifyAnswers[pluginID] = .json(Self.claim)
        invoker.ingestAnswers[pluginID] = .json(Self.model)
        return invoker
    }

    private func reresolver(_ invoker: FakePluginInvoker) -> PluginTranscriptionReresolver {
        PluginTranscriptionReresolver(invoker: invoker, processKind: .app)
    }

    func testAFreshRecordingComesBackAsARequestWithReresolveReasonAndIntent() async {
        let invoker = invoker()
        article.outcome = .transcription(Self.request)

        let answer = await reresolver(invoker).reresolve(
            sourceURL: url, pluginID: "t", saveID: saveID)

        XCTAssertEqual(answer, .request(Self.request))
        XCTAssertEqual(invoker.ingestReasons, ["reresolve"])
        XCTAssertEqual(
            invoker.encodedArguments.map { $0.json["intent"] as? String },
            ["transcribe", "transcribe"],
            "a re-resolution is always a transcribe request, so the plugin's media twin declines")
        XCTAssertEqual(
            invoker.encodedArguments.last?.json["saveId"] as? String, saveID.uuidString)
    }

    /// Captions appeared since the save: the plugin now hands over text, and the
    /// runner persists it without a download.
    func testAnArticleAdoptionComesBackAsContent() async {
        let content = ArticleContent(
            title: "A talk", blocks: [.init(kind: .paragraph, text: "Now with captions.", links: [])])
        article.outcome = .article(content, sourceHTML: nil)

        let answer = await reresolver(invoker()).reresolve(
            sourceURL: url, pluginID: "t", saveID: saveID)

        XCTAssertEqual(answer, .article(content))
    }

    func testOnlyTheOwningPluginIsAsked() async {
        let invoker = invoker(pluginID: "other")
        article.outcome = .transcription(Self.request)

        let answer = await reresolver(invoker).reresolve(
            sourceURL: url, pluginID: "t", saveID: saveID)

        XCTAssertNil(answer)
        XCTAssertTrue(invoker.calls.isEmpty, "a plugin that did not produce the save is never run")
    }

    func testADeclineOrABrokenPluginAnswersNothing() async {
        let declining = invoker()
        article.outcome = .declined
        let declined = await reresolver(declining).reresolve(
            sourceURL: url, pluginID: "t", saveID: saveID)
        XCTAssertNil(declined)

        let broken = invoker()
        broken.ingestAnswers["t"] = .failure(.timedOut)
        article.outcome = .transcription(Self.request)
        let failed = await reresolver(broken).reresolve(
            sourceURL: url, pluginID: "t", saveID: saveID)
        XCTAssertNil(failed)
    }
}
