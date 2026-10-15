//
//  PluginBrowserBridgeTests.swift
//  LunaTests
//

import Foundation
import LunaModels
import LunaPluginIngest
import LunaPluginKit
import LunaPluginRuntime
import LunaPluginUI
import LunaStorage
import XCTest

/// `luna.browser.open`'s three answers (`claudedocs/plans/plugin-platform.md`
/// §6.10, §8): an extension defers and locks, the app serves a stored result
/// without showing anything, and a call with nowhere to park a request refuses.
final class PluginBrowserBridgeTests: XCTestCase {

    private var runner: PluginJSFixtureRunner!
    private var directory: URL!
    private var saves: SavesStore!
    private var requests: PluginBrowserRequestStore!
    private var previousWitness: (any PluginBrowserDeferring)?
    private var saveID = UUID()

    private static let pluginID = "app.luna.browse"
    private static let gateURL = "https://gate.test/x"

    private struct Answer: Decodable { let value: String }

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        saves = SavesStore(containerURL: directory)
        // The request row is a child of a save, so the save has to exist.
        saveID = saves.add(urlString: Self.gateURL).id
        requests = PluginBrowserRequestStore(saves: saves)
        previousWitness = PluginBrowserDeferral.witness
        PluginBrowserDeferral.witness = StoredPluginBrowserDeferral(store: requests)
    }

    override func tearDown() {
        PluginBrowserDeferral.witness = previousWitness
        runner?.cleanUp()
        runner = nil
        requests = nil
        saves = nil
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    // MARK: - Driving one call

    private func install(
        processKind: PluginProcessKind, presenter: (any PluginBrowserPresenting)? = nil,
        requestURL: String = PluginBrowserBridgeTests.gateURL
    ) {
        runner = PluginJSFixtureRunner(processKind: processKind)
        runner.capabilities.register(PluginBrowserBridge(
            processKind: processKind, scheduler: runner.runtime, requests: requests,
            presenter: presenter, diagnostics: DiscardedPluginDiagnostics()))
        try? runner.load("""
        /* luna-plugin
        { "id": "\(Self.pluginID)", "name": "Browse", "version": "1.0.0", "api": 1,
          "capabilities": ["browser"] }
        */
        luna.register({
          async onAction() {
            try {
              const answer = await luna.browser.open({
                url: "\(requestURL)", detect: "'done'" });
              return { value: "html:" + answer.html };
            } catch (error) {
              return { value: "code:" + error.code };
            }
          }
        });
        """)
    }

    /// One `onAction` call, inside a save's scope unless `saveID` is nil.
    private func answer(scopedTo saveID: UUID?) async -> String? {
        await PluginIngestScope.run(saveID: saveID, pluginID: Self.pluginID) {
            await runner.invoke(
                .onAction, pluginID: Self.pluginID, as: Answer.self)?.value
        }
    }

    private func storeRequest(url: String) {
        let request = PluginBrowserRequest(url: URL(string: url)!, detect: "'done'")
        requests.put(
            saveID: saveID, pluginID: Self.pluginID, requestJSON: request.jsonText ?? "")
    }

    private func storeResult(html: String) {
        let result = PluginBrowserResult(
            url: Self.gateURL, html: html, title: "Gate", cookieHeader: "a=b", cookies: [])
        requests.complete(saveID: saveID, resultJSON: result.jsonText ?? "")
    }

    // MARK: - An extension defers

    func testAShareExtensionStoresTheRequestAndRejectsWithBrowserDeferred() async {
        install(processKind: .share)
        let answer = await answer(scopedTo: saveID)
        XCTAssertEqual(answer, "code:browser-deferred")
        let pending = requests.pending(for: saveID)
        XCTAssertEqual(pending?.pluginID, Self.pluginID)
        XCTAssertEqual(
            pending.flatMap { PluginBrowserRequest(json: $0.requestJSON) }?.url.absoluteString,
            Self.gateURL,
            "the stored request must name the page the app has to open")
    }

    func testAnActionExtensionDefersTheSameWay() async {
        install(processKind: .action)
        let answer = await answer(scopedTo: saveID)
        XCTAssertEqual(answer, "code:browser-deferred")
        XCTAssertNotNil(requests.pending(for: saveID))
    }

    // MARK: - The app resumes

    func testTheAppServesAStoredResultForTheSamePageWithoutPresenting() async {
        storeRequest(url: Self.gateURL)
        storeResult(html: "<html>unlocked</html>")
        // No presenter: reaching the modal at all would refuse instead.
        install(processKind: .app, presenter: nil)

        let answer = await answer(scopedTo: saveID)
        XCTAssertEqual(answer, "html:<html>unlocked</html>")
        XCTAssertNil(
            requests.record(for: saveID),
            "a served result is taken once, so a second ask opens the browser")
    }

    func testAStoredResultForAnotherPageIsLeftAloneAndTheBrowserIsAskedFor() async {
        storeRequest(url: "https://gate.test/other")
        storeResult(html: "<html>stale</html>")
        install(processKind: .app, presenter: nil)

        let answer = await answer(scopedTo: saveID)
        XCTAssertEqual(answer, "code:unavailable-here", "the modal was needed, and none exists here")
        XCTAssertNotNil(
            requests.record(for: saveID), "the other page's answer must survive untouched")
    }

    @MainActor
    func testRetryThatStillNeedsBrowserUsesCurrentRequestInsteadOfStoredScripts() async {
        let stale = PluginBrowserRequest(url: URL(string: Self.gateURL)!, detect: "'wait'")
        requests.put(saveID: saveID, pluginID: Self.pluginID, requestJSON: stale.jsonText!)
        let browser = RecordingBrowser()
        install(processKind: .app, presenter: browser)

        let value = await answer(scopedTo: saveID)

        XCTAssertEqual(value, "html:recovered")
        XCTAssertEqual(browser.detectScripts, ["'done'"])
        XCTAssertNil(requests.record(for: saveID))
    }

    @MainActor
    private final class RecordingBrowser: PluginBrowserPresenting {
        var detectScripts: [String] = []
        func presentBrowserStep(_ request: PluginBrowserRequest, pluginID: String) async -> PluginBrowserResult? {
            detectScripts.append(request.detect)
            return PluginBrowserResult(url: request.url.absoluteString, html: "recovered",
                                       title: "", cookieHeader: "", cookies: [])
        }
    }

    @MainActor
    private final class CancelledBrowser: PluginBrowserPresenting {
        let requests: PluginBrowserRequestStore
        let saveID: UUID
        var checkpointWasPresent = false
        init(requests: PluginBrowserRequestStore, saveID: UUID) {
            self.requests = requests
            self.saveID = saveID
        }
        func presentBrowserStep(_ request: PluginBrowserRequest, pluginID: String) async -> PluginBrowserResult? {
            checkpointWasPresent = requests.pending(for: saveID) != nil
            return nil
        }
    }

    @MainActor
    func testCancelledAppBrowserKeepsTheCurrentCheckpointAndReturnsALock() async throws {
        let browser = CancelledBrowser(requests: requests, saveID: saveID)
        install(processKind: .app, presenter: browser)
        let value = await answer(scopedTo: saveID)
        XCTAssertEqual(value, "code:browser-deferred")
        XCTAssertTrue(browser.checkpointWasPresent, "killing the app while the browser is up must be recoverable")
        let record = try XCTUnwrap(requests.pending(for: saveID))
        XCTAssertEqual(PluginBrowserRequest(json: record.requestJSON)?.url.absoluteString, Self.gateURL)
    }

    // MARK: - Outside a save

    func testACallWithNoSaveToParkAgainstRefuses() async {
        install(processKind: .share)
        let answer = await answer(scopedTo: nil)
        XCTAssertEqual(answer, "code:unavailable-here")
        XCTAssertNil(requests.record(for: saveID))
    }

    @MainActor
    private final class SlowBrowser: PluginBrowserPresenting {
        func presentBrowserStep(_ request: PluginBrowserRequest, pluginID: String) async -> PluginBrowserResult? {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            return PluginBrowserResult(url: request.url.absoluteString, html: "complete", title: "", cookieHeader: "", cookies: [])
        }
    }

    @MainActor
    func testBrowserProgressKeepsHookAndOuterPipelineAlive() async throws {
        install(processKind: .app, presenter: SlowBrowser())
        try runner.load("""
        /* luna-plugin
        {"id":"\(Self.pluginID)","name":"Browse","version":"1.0.1","api":1,"capabilities":["browser"]}
        */
        luna.register({async ingest() {
            const result = await luna.browser.open({url:"\(Self.gateURL)",detect:"'done'",timeout:5});
            return {value:result.html};
        }});
        """)
        let value = await IdleTimeLimit.run(0.8) { [self] in
            await PluginIngestScope.run(saveID: saveID, pluginID: Self.pluginID) {
                await runner.invoke(.ingest, pluginID: Self.pluginID, timeout: 0.8, as: Answer.self)?.value
            }
        }
        XCTAssertEqual(value ?? nil, "complete")
    }
}
