//
//  PluginResumeTests.swift
//  LunaTests
//

import Foundation
import LunaIngest
import LunaModels
import LunaPluginIngest
import LunaPluginKit
import LunaArchiveReader
import LunaPluginUI
import LunaReaderUI
import LunaSaves
import LunaStorage
import LunaURLClassification
import UIKit
import XCTest

/// Finishing a locked save (`claudedocs/plans/plugin-platform.md` §8.3): the
/// browser's answer is written against the save, the same id is re-run, and the
/// walk tells the plugin it is a resume.
final class PluginResumeTests: XCTestCase {

    private final class FakeResumer: PluginLockedSaveResuming {
        private let lock = NSLock()
        private var stored: [UUID] = []

        var resumed: [UUID] {
            lock.lock(); defer { lock.unlock() }
            return stored
        }

        func resumePluginLockedSave(id: UUID) async {
            lock.lock(); stored.append(id); lock.unlock()
        }
    }

    private var directory: URL!
    private var saves: SavesStore!
    private var requests: PluginBrowserRequestStore!
    private var resumer: FakeResumer!
    private var previousResumer: (any PluginLockedSaveResuming)?

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        saves = SavesStore(containerURL: directory)
        requests = PluginBrowserRequestStore(saves: saves)
        resumer = FakeResumer()
        previousResumer = PluginResumeSeams.resumer
        PluginResumeSeams.resumer = resumer
    }

    override func tearDown() {
        PluginResumeSeams.resumer = previousResumer
        requests = nil
        saves = nil
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func lockedSave(url: String = "https://gate.test/a") -> SavedItem {
        let item = saves.add(urlString: url)
        saves.markPluginLocked(item.id, pluginID: "app.luna.gate", title: "Waiting")
        let request = PluginBrowserRequest(url: URL(string: url)!, detect: "'done'")
        requests.put(
            saveID: item.id, pluginID: "app.luna.gate", requestJSON: request.jsonText ?? "")
        return saves.item(withID: item.id) ?? item
    }

    private func result(html: String) -> PluginBrowserResult {
        PluginBrowserResult(
            url: "https://gate.test/a", html: html, title: "A", cookieHeader: "", cookies: [])
    }

    // MARK: - The sweep

    @MainActor
    func testALockedSaveWithAnAnsweredBrowserStepIsResumedByItsOwnID() async {
        let waiting = lockedSave()
        requests.complete(saveID: waiting.id, resultJSON: result(html: "<a/>").jsonText ?? "")
        // A second locked save whose step has NOT been answered stays locked.
        let untouched = lockedSave(url: "https://gate.test/b")

        PluginUnlockFlowRunner(store: saves, requests: requests).resumeCompleted()

        await waitFor("the answered save is resumed") { self.resumer.resumed == [waiting.id] }
        XCTAssertFalse(resumer.resumed.contains(untouched.id))
    }

    @MainActor
    func testForegroundRepairsPreviouslyDowngradedLocksWithoutOpeningBrowser() {
        let locked = lockedSave()
        requests.clear(saveID: locked.id)
        saves.markPlainLink(locked.id)
        let bookmark = saves.add(urlString: "https://bookmark.test/ordinary")
        saves.markPlainLink(bookmark.id)
        PluginUnlockFlowRunner(store: saves, requests: requests).resumeCompleted()
        XCTAssertTrue(saves.item(withID: locked.id)?.isPluginLocked == true)
        XCTAssertEqual(saves.item(withID: bookmark.id)?.state, .link)
        XCTAssertTrue(resumer.resumed.isEmpty)
    }

    @MainActor
    func testASaveLockedByTheArchiveFlowIsNeverResumedByThePluginSweep() async {
        let item = saves.add(urlString: "https://paywall.test/a")
        saves.markNeedsCaptcha(item.id, title: "Locked")
        requests.put(saveID: item.id, pluginID: "app.luna.gate", requestJSON: "{}")
        requests.complete(saveID: item.id, resultJSON: result(html: "<a/>").jsonText ?? "")

        PluginUnlockFlowRunner(store: saves, requests: requests).resumeCompleted()

        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(
            resumer.resumed.isEmpty, "no plugin owns that lock, so nothing resumes it")
    }

    @MainActor
    func testFinishingTheStepWritesTheAnswerAgainstTheSaveAndResumesThatSameSave() async {
        let item = lockedSave()
        let pages = FakePageMaker()
        let runner = PluginUnlockFlowRunner(
            store: saves, requests: requests, pageMaker: pages)

        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let root = UIViewController()
        window.rootViewController = root
        window.isHidden = false
        // Exercise the presentation-only fallback. Composed apps retry their
        // current pipeline instead (covered below).
        PluginResumeSeams.resumer = nil
        runner.present(for: item, from: root)
        PluginResumeSeams.resumer = resumer

        guard let browser = pages.made.first else {
            return XCTFail("the pending request should have opened a browser step")
        }
        runner.pluginBrowser(browser.controller, didFinishWith: result(html: "<b/>"))

        XCTAssertEqual(
            requests.record(for: item.id).flatMap { $0.resultJSON }
                .flatMap(PluginBrowserResult.init(json:))?.html,
            "<b/>",
            "the answer is written against the save so the resumed run can take it")
        await waitFor("the same save is resumed") { self.resumer.resumed == [item.id] }
    }

    @MainActor
    func testASaveWithNoPendingRequestStillRetriesTheCurrentPipeline() async {
        let item = saves.add(urlString: "https://gate.test/none")
        saves.markPluginLocked(item.id, pluginID: "app.luna.gate", title: "Waiting")
        let pages = FakePageMaker()
        let flow = PluginUnlockFlowRunner(store: saves, requests: requests, pageMaker: pages)
        flow.present(for: saves.item(withID: item.id) ?? item, from: UIViewController())
        flow.present(for: saves.item(withID: item.id) ?? item, from: UIViewController())
        await waitFor("the lock is retried once despite repeated taps") {
            self.resumer.resumed == [item.id]
        }
        XCTAssertTrue(pages.made.isEmpty)
    }

    @MainActor
    func testRetryDisplaysProgressSynchronouslyBeforeTheResumerStarts() async {
        let item = lockedSave()
        let flow = PluginUnlockFlowRunner(store: saves, requests: requests)
        let presenter = UIViewController()
        flow.present(for: item, from: presenter)
        XCTAssertTrue(presenter.view.subviews.contains { $0.accessibilityIdentifier == "PluginUnlockProgress" })
        XCTAssertTrue(resumer.resumed.isEmpty, "feedback precedes async work")
        await waitFor("progress removed after completion") {
            !presenter.view.subviews.contains { $0.accessibilityIdentifier == "PluginUnlockProgress" }
        }
        XCTAssertEqual(resumer.resumed, [item.id])
    }

    func testDeclinedOrFailedRetryPreservesLockAcrossStoreReopen() async throws {
        let originalPolicy = URLBehaviorPolicy.pluginsOnly
        URLBehaviorPolicy.pluginsOnly = true
        defer { URLBehaviorPolicy.pluginsOnly = originalPolicy }
        let item = lockedSave()
        let ingestor = SavesIngestor(store: saves, surfaceGate: ScriptedIngestGate.supported)
        for outcome in [Outcome.link, .failed(.timedOut)] {
            _ = await ingestor.applyRescued(IngestResult(url: item.url!, outcome: outcome),
                                          forItemID: item.id, interactive: true)
            let reopened = SavesStore(containerURL: directory)
            let restored = try XCTUnwrap(reopened.item(withID: item.id))
            XCTAssertTrue(restored.isPluginLocked)
            XCTAssertEqual(restored.title, item.title)
            XCTAssertEqual(restored.urlString, item.urlString)
        }
    }

    @MainActor
    func testExistingDailyBeastLockUsesFixedPluginBeforeStaleBrowserRequest() async throws {
        let fixture = PluginJSFixtureRunner()
        let previousStage = IngestPipeline.pluginStage
        let previousHandler = IngestorKindHandlers.article
        let previousPolicy = URLBehaviorPolicy.pluginsOnly
        let scope = PluginAdopterScope()
        defer {
            IngestPipeline.pluginStage = previousStage
            IngestorKindHandlers.article = previousHandler
            URLBehaviorPolicy.pluginsOnly = previousPolicy
            scope.restore()
            fixture.cleanUp()
        }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        try fixture.load(String(contentsOf: root.appendingPathComponent(
            "LunaLibraries/Sources/LunaBundledPlugins/Plugins/publisher-access.js"), encoding: .utf8))
        let url = "https://www.thedailybeast.com/animated-pete-hegseth-snaps-at-press-during-wild-pentagon-briefing"
        fixture.fetcher.respond(to: url, body: try String(contentsOf: root.appendingPathComponent(
            "LunaTests/Fixtures/Plugins/dailybeast-astro.html"), encoding: .utf8))
        URLBehaviorPolicy.pluginsOnly = true
        PluginModelAdopters.article = ArticleModelAdopter()
        IngestPipeline.pluginStage = PluginIngestStage(invoker: fixture.runtime, processKind: .app)
        IngestorKindHandlers.article = RecoveryArticleHandler()
        PluginResumeSeams.resumer = SavesIngestor(store: saves, surfaceGate: ScriptedIngestGate.supported)

        // Both a never-answered step and an answer left by a previous session
        // must recover in place. Neither should replay the old wait-only probe.
        for answered in [false, true] {
            let saved = saves.add(urlString: url)
            saves.markPluginLocked(saved.id, pluginID: "app.luna.publisher-access", title: "Locked")
            let stale = PluginBrowserRequest(url: URL(string: url)!, detect: "'wait'")
            requests.put(saveID: saved.id, pluginID: "app.luna.publisher-access", requestJSON: stale.jsonText!)
            if answered { requests.complete(saveID: saved.id, resultJSON: result(html: "<p>Old teaser</p>").jsonText!) }
            let pages = FakePageMaker()
            let flow = PluginUnlockFlowRunner(store: saves, requests: requests, pageMaker: pages)
            flow.present(for: try XCTUnwrap(saves.item(withID: saved.id)), from: UIViewController())

            await waitFor("the existing save recovers with the current plugin") {
                self.saves.item(withID: saved.id)?.state == .ready && self.requests.record(for: saved.id) == nil
            }
            let recovered = try XCTUnwrap(saves.item(withID: saved.id))
            let content = try XCTUnwrap(saves.content(for: recovered))
            XCTAssertEqual(recovered.id, saved.id)
            XCTAssertEqual(recovered.pluginID, "app.luna.publisher-access")
            XCTAssertEqual(recovered.title, "Daily Beast regression")
            XCTAssertTrue(content.blocks.contains { $0.text.contains("Paragraph 6.") })
            XCTAssertTrue(pages.made.isEmpty, "stale detection scripts must never be opened")
            XCTAssertEqual(saves.items().count, 1, "recovery replaces the existing row")
            saves.delete(recovered)
        }
        XCTAssertTrue(fixture.fetcher.requests.allSatisfy { $0.url.absoluteString == url })
    }

    private struct RecoveryArticleHandler: IngestorArticleHandling {
        func persistArticle(_ content: ArticleContent, html: String, for item: SavedItem,
                            url: URL, store: SavesStore) async { _ = store.saveContent(content, for: item) }
        func ingestDocument(_ item: SavedItem, store: SavesStore) async {}
        func backfillMissingWebArchives(store: SavesStore) {}
        func backfillMissingThumbnails(store: SavesStore) {}
        func preloadPasteboard(content: ArticleContent, sourceURL: URL) {}
        func doubleSaveDestinationIDs() -> [String] { [] }
        func sendToDestination(_ item: SavedItem, destinationID: String) async {}
        func isDestinationConfigured(_ destinationID: String) -> Bool { false }
    }

    /// A page maker that hands out inert pages and remembers them, so the flow
    /// can be driven without a WebContent process.
    @MainActor
    private final class FakePageMaker: PluginBrowserPageMaking {
        struct Made { let page: InertPage; let controller: PluginBrowserViewController }
        private(set) var made: [Made] = []

        func makePage(for request: PluginBrowserRequest) -> any PluginBrowserPageDriving {
            let page = InertPage()
            made.append(Made(
                page: page,
                controller: PluginBrowserViewController(
                    request: request, title: "Finishing", page: page,
                    poller: DOMProbePoller(interval: 3_600))))
            return page
        }
    }

    @MainActor
    private final class InertPage: PluginBrowserPageDriving {
        let pageView = UIView()
        var currentURL: URL? { nil }
        func load(_ request: PluginBrowserRequest) {}
        func probe(_ source: String, completion: @escaping (String?) -> Void) { completion(nil) }
        func capture(completion: @escaping (PluginBrowserResult?) -> Void) { completion(nil) }
        func stopLoading() {}
    }

    // MARK: - The walk's reason

    /// A scripted invoker that records the save scope a bridge would read, so
    /// the walk's own binding is asserted rather than assumed.
    private final class ScopeRecordingInvoker: PluginHookInvoking {
        var loadedPlugins: [PluginSummary] = []
        var disabledPlugins: [String: String] = [:]
        private(set) var reasons: [String] = []
        private(set) var saveIDs: [String?] = []
        private(set) var scopedSaveIDs: [UUID?] = []

        func matchedPlugins(forHost host: String) -> [PluginSummary] { loadedPlugins }

        func invoke<T: Decodable>(
            _ hook: PluginHook, pluginID: String, argument: Encodable,
            timeout: TimeInterval, decode: T.Type
        ) async -> Result<T, PluginInvocationFailure> {
            if hook == .ingest {
                scopedSaveIDs.append(PluginIngestScope.saveIDs(pluginID: pluginID).last)
                let data = (try? JSONEncoder().encode(argument)) ?? Data()
                let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                reasons.append(object?["reason"] as? String ?? "")
                saveIDs.append(object?["saveId"] as? String)
            }
            let json = hook == .classify ? #"{"kind":"media"}"# : "null"
            guard let value = try? JSONDecoder().decode(T.self, from: Data(json.utf8))
            else { return .failure(.malformedResult("fixture")) }
            return .success(value)
        }

        func reloadAll() {}
    }

    private func runWalk(
        saveID: UUID?, witness: (any PluginBrowserDeferring)?
    ) async -> ScopeRecordingInvoker {
        let previous = PluginBrowserDeferral.witness
        PluginBrowserDeferral.witness = witness
        defer { PluginBrowserDeferral.witness = previous }
        let invoker = ScopeRecordingInvoker()
        invoker.loadedPlugins = [.fake(id: "app.luna.gate", hosts: ["gate.test"])]
        let stage = PluginIngestStage(invoker: invoker, processKind: .app)
        let input = IngestInput(url: URL(string: "https://gate.test/a")!, source: .manual)
        let recorder = saveID.map { SaveDiagnosticsRecorder(itemID: $0) }
        await SaveDiagnostics.$recorder.withValue(recorder) {
            _ = await stage.run(input, fetcher: MockArticleFetcher())
        }
        return invoker
    }

    func testTheWalkNamesTheSaveAndSaysWhichRunThisIs() async {
        let saveID = UUID()
        let first = await runWalk(saveID: saveID, witness: FakeDeferral(completed: []))
        XCTAssertEqual(first.reasons, ["save"])
        XCTAssertEqual(first.saveIDs, [saveID.uuidString])
        XCTAssertEqual(first.scopedSaveIDs, [saveID], "the bridge reads the scope, not the task")

        let second = await runWalk(saveID: saveID, witness: FakeDeferral(completed: [saveID]))
        XCTAssertEqual(
            second.reasons, ["resume"],
            "a save already holding a browser answer is being finished, not saved")
    }

    /// A deferral witness with a fixed set of answered saves.
    private final class FakeDeferral: PluginBrowserDeferring {
        private let completed: Set<UUID>
        private(set) var stored: [UUID: String] = [:]

        init(completed: Set<UUID>) { self.completed = completed }

        func defer_(request json: String, pluginID: String, saveID: UUID) -> Bool {
            stored[saveID] = json
            return true
        }

        func takeResult(saveID: UUID) -> String? { nil }

        func hasCompletedResult(saveID: UUID) -> Bool { completed.contains(saveID) }
    }

    // MARK: - Safari's hand-off link

    func testTheSaveLinkCarriesThePageAndOnlyThePage() {
        let link = LunaDeepLink.saveLink(
            scheme: "luna",
            urlString: "https://gate.test/über?a=1&next=https://x.test/?q=a+b#part")
        XCTAssertEqual(
            link.flatMap(LunaDeepLink.saveURL(from:)),
            "https://gate.test/über?a=1&next=https://x.test/?q=a+b#part")
    }

    func testAnythingThatIsNotASaveLinkIsNotOne() {
        for text in [
            "luna://read?url=https://gate.test/a",
            "luna://save",
            "luna://save?url=",
            "https://luna.test/save?url=https://gate.test/a",
        ] {
            let url = URL(string: text)!
            XCTAssertNil(LunaDeepLink.saveURL(from: url), "\(text) is not a save link")
        }
    }

    func testEveryLunaSchemeAnswersItsOwnSaveLink() {
        for scheme in LunaDeepLink.allSchemes {
            let url = URL(string: "\(scheme)://save?url=https://gate.test/a")!
            XCTAssertEqual(LunaDeepLink.saveURL(from: url), "https://gate.test/a")
        }
    }

    // MARK: - Helpers

    private func waitFor(
        _ description: String, timeout: TimeInterval = 3,
        file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("\(description) did not happen within \(timeout)s", file: file, line: line)
    }
}
