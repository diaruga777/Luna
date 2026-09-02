//
//  PluginJSFixtureRunner.swift
//  LunaTests
//

import Foundation
import JavaScriptCore
import LunaModels
import LunaPluginKit
import LunaPluginRuntime
import LunaStorage
import XCTest

/// Runs plugin JavaScript in `LunaTests` the way the app runs it.
///
/// Everything the app wires at launch is wired here from the SAME types: a real
/// `PluginStore` on a scratch directory, a real `PluginRuntime` on an isolated
/// virtual machine, and the shipped bridges — with a stub network unless the
/// test hands one over. So a test asserts on the shipped bridge, not on a
/// double of it.
///
/// The virtual machine is isolated so a fixture that wedges its own runtime
/// does not stall every other plugin in the test host.
final class PluginJSFixtureRunner {

    let runtime: PluginRuntime
    let store: PluginStore
    let kv: PluginKVStore
    let scratch: PluginScratchStore
    let fetcher: StubPluginFetcher
    let capabilities = PluginCapabilityRegistry()
    let containerURL: URL

    private let fileManager = FileManager.default

    init(
        processKind: PluginProcessKind = .app,
        fetcher: StubPluginFetcher = StubPluginFetcher(),
        installBridges: Bool = true
    ) {
        self.fetcher = fetcher
        containerURL = fileManager.temporaryDirectory
            .appendingPathComponent("plugin-fixture-\(UUID().uuidString)", isDirectory: true)
        try? fileManager.createDirectory(at: containerURL, withIntermediateDirectories: true)
        store = PluginStore(rootURL: containerURL.appendingPathComponent("Plugins"))
        kv = PluginKVStore(fileURL: containerURL.appendingPathComponent("saves.sqlite"))
        scratch = PluginScratchStore(
            pluginID: "fixture", rootURL: containerURL.appendingPathComponent("scratch"))
        runtime = PluginRuntime(
            store: store,
            bundled: BundledPluginCatalog(bundle: nil, store: store),
            capabilities: capabilities,
            processContext: PluginProcessContext(kind: processKind),
            diagnostics: DiscardedPluginDiagnostics(),
            virtualMachine: .isolated)
        guard installBridges else { return }
        capabilities.register(PluginFetchBridge(
            fetcher: fetcher, scheduler: runtime,
            diagnostics: DiscardedPluginDiagnostics()))
        capabilities.register(PluginHTMLBridge())
        capabilities.register(PluginStorageBridge(store: kv, scheduler: runtime))
        capabilities.register(PluginCryptoBridge(scheduler: runtime))
        capabilities.register(PluginFilesBridge(scratch: scratch, scheduler: runtime))
        capabilities.register(PluginSecretsBridge(
            scheduler: runtime, processKind: processKind))
    }

    /// Removes the scratch container. Call from `tearDown`.
    func cleanUp() {
        try? fileManager.removeItem(at: containerURL)
    }

    // MARK: - Installing

    /// Writes a plugin's source into the store and returns its manifest.
    @discardableResult
    func install(
        _ source: String, file: StaticString = #filePath, line: UInt = #line
    ) throws -> PluginManifest {
        switch PluginManifestParser.parse(source: source) {
        case .failure(let error):
            XCTFail("fixture header did not parse: \(error)", file: file, line: line)
            throw error
        case .success(let manifest):
            try store.install(source: source, manifest: manifest, origin: .paste)
            return manifest
        }
    }

    /// Installs and loads, failing the test on a rejection the caller did not
    /// ask for.
    @discardableResult
    func load(
        _ sources: String..., expectingFailures: Bool = false,
        file: StaticString = #filePath, line: UInt = #line
    ) throws -> [PluginLoadReport] {
        for source in sources { try install(source, file: file, line: line) }
        let reports = runtime.loadAll()
        guard !expectingFailures else { return reports }
        for report in reports where !report.isLoaded {
            XCTFail(
                "\(report.pluginID) did not load: \(report.failure?.message ?? "no reason")",
                file: file, line: line)
        }
        return reports
    }

    // MARK: - Calling

    /// Calls a hook and decodes its answer, failing the test on a rejection.
    func invoke<T: Decodable>(
        _ hook: PluginHook, pluginID: String, argument: Encodable = PluginEmptyArgument(),
        timeout: TimeInterval = 5, as type: T.Type,
        file: StaticString = #filePath, line: UInt = #line
    ) async -> T? {
        let outcome = await runtime.invoke(
            hook, pluginID: pluginID, argument: argument, timeout: timeout, decode: type)
        switch outcome {
        case .success(let value): return value
        case .failure(let failure):
            XCTFail("\(pluginID).\(hook.rawValue) failed: \(failure)", file: file, line: line)
            return nil
        }
    }

    /// Calls a hook and returns the failure, for the tests that assert on one.
    func invokeExpectingFailure<T: Decodable>(
        _ hook: PluginHook, pluginID: String, argument: Encodable = PluginEmptyArgument(),
        timeout: TimeInterval = 5, as type: T.Type,
        file: StaticString = #filePath, line: UInt = #line
    ) async -> PluginInvocationFailure? {
        let outcome = await runtime.invoke(
            hook, pluginID: pluginID, argument: argument, timeout: timeout, decode: type)
        switch outcome {
        case .success:
            XCTFail(
                "\(pluginID).\(hook.rawValue) was expected to fail", file: file, line: line)
            return nil
        case .failure(let failure):
            return failure
        }
    }

    /// Polls `condition` until it holds or the timeout passes. A fixed sleep is
    /// not a wait: a hook settles from another queue, and how long that takes
    /// depends on what else the test host is running.
    @discardableResult
    func awaitCondition(
        _ description: String, timeout: TimeInterval = 5,
        file: StaticString = #filePath, line: UInt = #line,
        _ condition: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTFail("\(description) did not happen within \(timeout)s", file: file, line: line)
        return false
    }
}

/// The hook argument for a fixture that reads none.
struct PluginEmptyArgument: Encodable {}

/// A network that answers from a table instead of the wire.
///
/// It records every request, so a test asserts on what the bridge ASKED for —
/// the cookie policy, the redirect policy, the headers — as well as on what the
/// plugin received.
final class StubPluginFetcher: PluginURLFetching, @unchecked Sendable {

    /// URL string → the response to answer with.
    var responses: [String: PluginFetchResponse] = [:]
    /// Answered when no entry matches.
    var fallback: Result<PluginFetchResponse, PluginFetchError> =
        .failure(PluginFetchError("no stub response"))
    /// Held before answering, so a test can watch a hook wait.
    var delay: TimeInterval = 0

    private let lock = NSLock()
    private var recorded: [PluginFetchRequest] = []

    /// Requests in the order they arrived.
    var requests: [PluginFetchRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    init() {}

    func respond(
        to urlString: String, status: Int = 200, body: String = "",
        finalURL: String? = nil, headers: [String: String] = [:]
    ) {
        responses[urlString] = PluginFetchResponse(
            status: status, finalURL: finalURL ?? urlString, headers: headers,
            body: Data(body.utf8), truncated: false, redirected: finalURL != nil)
    }

    func fetch(
        _ request: PluginFetchRequest,
        completion: @escaping (Result<PluginFetchResponse, PluginFetchError>) -> Void
    ) {
        lock.lock()
        recorded.append(request)
        let answer = responses[request.url.absoluteString].map { Result.success($0) } ?? fallback
        let delay = self.delay
        lock.unlock()
        // Off the calling thread, the way a real transfer answers.
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { completion(answer) }
    }
}
