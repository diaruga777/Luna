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
        runner.present(for: item, from: root)

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
    func testASaveWithNoPendingRequestOpensNothing() {
        let item = saves.add(urlString: "https://gate.test/none")
        saves.markPluginLocked(item.id, pluginID: "app.luna.gate", title: "Waiting")
        let pages = FakePageMaker()
        PluginUnlockFlowRunner(store: saves, requests: requests, pageMaker: pages)
            .present(for: saves.item(withID: item.id) ?? item, from: UIViewController())
        XCTAssertTrue(pages.made.isEmpty)
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
