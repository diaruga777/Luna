//
//  PluginRuntimeTests.swift
//  LunaTests
//

import LunaModels
import LunaIngest
import LunaPluginIngest
import LunaPluginKit
import LunaPluginRuntime
import LunaStorage
import XCTest

/// The runtime's contract with the stages: what loads, what is refused, what a
/// hook's answer decodes to, and what happens when a plugin does not finish.
final class PluginRuntimeTests: XCTestCase {

    private var runner: PluginJSFixtureRunner!

    override func setUp() {
        super.setUp()
        runner = PluginJSFixtureRunner()
    }

    override func tearDown() {
        runner.cleanUp()
        runner = nil
        super.tearDown()
    }

    // MARK: - Fixtures

    private func plugin(
        id: String = "app.luna.test", priority: Int? = nil, hosts: [String]? = ["example.com"],
        anyHost: Bool = false, capabilities: [String] = [], produces: [String]? = ["media"],
        body: String
    ) -> String {
        var header: [String] = [
            "\"id\": \"\(id)\"", "\"name\": \"Test\"", "\"version\": \"1.0.0\"", "\"api\": 1",
        ]
        if let produces {
            header.append("\"produces\": [\(produces.map { "\"\($0)\"" }.joined(separator: ", "))]")
            var match: [String] = []
            if let hosts {
                match.append("\"hosts\": [\(hosts.map { "\"\($0)\"" }.joined(separator: ", "))]")
            }
            if anyHost { match.append("\"any\": true") }
            header.append("\"match\": { \(match.joined(separator: ", ")) }")
        }
        if let priority { header.append("\"priority\": \(priority)") }
        if !capabilities.isEmpty {
            header.append(
                "\"capabilities\": [\(capabilities.map { "\"\($0)\"" }.joined(separator: ", "))]")
        }
        return """
        /* luna-plugin
        { \(header.joined(separator: ",\n  ")) }
        */
        \(body)
        """
    }

    private var claimingBody: String {
        """
        luna.register({
            classify({ url }) {
                const parsed = luna.parseURL(url);
                return parsed.pathname.startsWith("/v/")
                    ? { kind: "media", itemId: parsed.pathname.slice(3) }
                    : false;
            },
            async ingest({ url, claim }) {
                return {
                    kind: "media",
                    title: "Clip " + claim.itemId,
                    assets: [{ url: url + ".mp4", type: "video" }]
                };
            }
        });
        """
    }

    private struct ClassifyInput: Encodable {
        let url: String
        let context: String
    }

    private struct ClassifyClaim: Decodable, Equatable {
        let kind: String
        let itemId: String?
    }

    func testLaunchLoadHasADeadlineWithoutBlockingOtherIsolatedRuntimes() async throws {
        let store = runner.store
        let slow = plugin(body: """
            const until = Date.now() + 1800;
            while (Date.now() < until) {}
            \(claimingBody)
            """)
        let manifest = try PluginManifestParser.parse(source: slow).get()
        _ = try store.install(source: slow, manifest: manifest, origin: .paste)
        let isolated = PluginRuntime(
            store: store, bundled: BundledPluginCatalog(bundle: nil, store: store),
            processContext: PluginProcessContext(kind: .app), isolated: true)
        let started = Date()
        let reports = isolated.loadAll()
        XCTAssertEqual(reports.first?.failure?.reason, .timeout)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.6)
        // The abandoned draft still runs for another 0.8s. Live plugin work
        // must proceed immediately on a different VM and queue.
        let liveStart = Date()
        _ = try runner.load(plugin(body: claimingBody))
        XCTAssertLessThan(Date().timeIntervalSince(liveStart), 0.5)
        try? await Task.sleep(nanoseconds: 900_000_000)
    }

    // MARK: - Loading

    func testAPluginThatRegistersItsRequiredHooksLoads() throws {
        let reports = try runner.load(plugin(body: claimingBody))

        XCTAssertEqual(reports.map(\.pluginID), ["app.luna.test"])
        XCTAssertEqual(runner.runtime.loadedPlugins.map(\.id), ["app.luna.test"])
        XCTAssertEqual(runner.runtime.loadedPlugins.first?.hooks, [.classify, .ingest])
        XCTAssertTrue(runner.runtime.disabled.isEmpty)
    }

    func testAPluginThatNeverRegistersDoesNotLoadAndSaysSo() throws {
        let reports = try runner.load(
            plugin(body: "const nothing = 1;"), expectingFailures: true)

        XCTAssertEqual(reports.first?.isLoaded, false)
        XCTAssertEqual(reports.first?.failure?.reason, .missingHook)
        XCTAssertTrue(
            reports.first?.failure?.message.contains("never called luna.register") == true)
        guard case .loadFailed? = runner.runtime.disabled["app.luna.test"] else {
            return XCTFail("a failed load should be reported in Settings")
        }
    }

    func testAPluginThatRegistersTwiceDoesNotLoad() throws {
        let reports = try runner.load(
            plugin(body: "luna.register({}); luna.register({});"), expectingFailures: true)

        XCTAssertEqual(reports.first?.isLoaded, false)
        XCTAssertTrue(reports.first?.failure?.message.contains("exactly once") == true)
    }

    func testAPluginThatThrowsAtTopLevelDoesNotLoad() throws {
        let reports = try runner.load(
            plugin(body: "throw new Error(\"boom\");"), expectingFailures: true)

        XCTAssertEqual(reports.first?.isLoaded, false)
        XCTAssertEqual(reports.first?.failure?.reason, .exception)
        XCTAssertTrue(reports.first?.failure?.message.contains("boom") == true)
    }

    func testAnIngestManifestWithoutBothHooksDoesNotLoad() throws {
        let reports = try runner.load(
            plugin(body: "luna.register({ classify() { return false; } });"),
            expectingFailures: true)

        XCTAssertEqual(reports.first?.isLoaded, false)
        XCTAssertTrue(reports.first?.failure?.message.contains("ingest") == true)
    }

    func testADisabledPluginIsNotLoadedAndIsReportedAsOff() throws {
        try runner.install(plugin(body: claimingBody))
        runner.store.setEnabled(false, pluginID: "app.luna.test", isBundled: false)

        runner.runtime.loadAll()

        XCTAssertTrue(runner.runtime.loadedPlugins.isEmpty)
        XCTAssertEqual(runner.runtime.disabled["app.luna.test"], .userDisabled)
        XCTAssertEqual(runner.runtime.disabledPlugins["app.luna.test"], "off")
    }

    // MARK: - Grants

    func testRegisteringAgainFromAHookThrowsAlreadyRegistered() async throws {
        let body = """
        luna.register({
            classify() { return false; },
            async ingest() {
                let outcome = "no throw";
                try { luna.register({ ingest() { return null; } }); }
                catch (error) { outcome = error.name + "|" + error.code; }
                return { kind: "media", title: outcome,
                         assets: [{ url: "https://example.com/a.mp4", type: "video" }] };
            }
        });
        """
        try runner.load(plugin(body: body))

        struct Model: Decodable { let title: String }
        let first = await runner.invoke(.ingest, pluginID: "app.luna.test", as: Model.self)
        XCTAssertEqual(first?.title, "LunaError|already-registered")
        // The hook table is unchanged: the original ingest still answers.
        let second = await runner.invoke(.ingest, pluginID: "app.luna.test", as: Model.self)
        XCTAssertEqual(second?.title, "LunaError|already-registered")
    }

    func testOnlyDeclaredNamespacesReachThePlugin() async throws {
        let body = """
        luna.register({
            classify() { return false; },
            async ingest() {
                return { kind: "media", title: Object.keys(luna).sort().join(","),
                         assets: [{ url: "https://example.com/a.mp4", type: "video" }] };
            }
        });
        """
        try runner.load(plugin(capabilities: ["fetch", "html"], body: body))

        struct Model: Decodable { let title: String }
        let model = await runner.invoke(
            .ingest, pluginID: "app.luna.test", as: Model.self)

        // `text` is there without being declared: it is a COMPANION of `html`
        // (`PluginCapabilityName.companionNamespaces`), not a capability.
        XCTAssertEqual(
            model?.title, "LunaError,bytes,env,fetch,html,localize,log,parseURL,register,text")
    }

    func testACapabilityWithNoInstallerRejectsWithUnavailableHere() async throws {
        let isolated = PluginJSFixtureRunner(installBridges: false)
        defer { isolated.cleanUp() }
        let body = """
        luna.register({
            classify() { return false; },
            async ingest() {
                try {
                    await luna.fetch({ url: "https://example.com/" });
                    return { kind: "media", title: "no throw",
                             assets: [{ url: "https://example.com/a.mp4", type: "video" }] };
                } catch (error) {
                    return { kind: "media", title: error.code,
                             assets: [{ url: "https://example.com/a.mp4", type: "video" }] };
                }
            }
        });
        """
        try isolated.load(plugin(capabilities: ["fetch"], body: body))

        struct Model: Decodable { let title: String }
        let model = await isolated.invoke(.ingest, pluginID: "app.luna.test", as: Model.self)

        XCTAssertEqual(model?.title, "unavailable-here")
    }

    func testTheGrantIsReadBackFromTheContextRatherThanTheTable() throws {
        // A bridge that installs under a name the manifest never asked for is a
        // wiring fault, and the load refuses rather than degrading.
        runner.capabilities.register(MisnamingCapabilityBridge())
        let reports = try runner.load(
            plugin(capabilities: ["downloads"], body: claimingBody), expectingFailures: true)

        XCTAssertEqual(reports.first?.isLoaded, false)
        XCTAssertEqual(reports.first?.failure?.reason, .capabilityMismatch)
    }

    func testPluginCannotForgeHostInspectionOrResultSerialization() async throws {
        let body = """
        Object.keys = function () { return []; };
        JSON.stringify = function () { return '{"kind":"product"}'; };
        luna.parseURL = function () { return { hostname: 'forged.test' }; };
        luna.register({
          classify({ url }) {
            return { kind: luna.parseURL(url).hostname === 'example.com' ? 'media' : 'article' };
          },
          ingest() { return null; }
        });
        """
        let reports = try runner.load(plugin(body: body))
        XCTAssertEqual(reports.first?.isLoaded, true)

        let claim = await runner.invoke(
            .classify, pluginID: "app.luna.test",
            argument: ClassifyInput(url: "https://example.com/v/abc", context: "app"),
            as: ClassifyClaim.self)
        XCTAssertEqual(claim?.kind, "media")
    }

    // MARK: - Ordering and matching

    func testMatchedPluginsRunHighestPriorityFirstAndAnyHostLast() throws {
        try runner.load(
            plugin(id: "app.luna.low", priority: 10, body: claimingBody),
            plugin(id: "app.luna.high", priority: 100, body: claimingBody),
            plugin(id: "app.luna.any", priority: 500, hosts: nil, anyHost: true,
                   body: claimingBody))

        XCTAssertEqual(
            runner.runtime.matchedPlugins(forHost: "example.com").map(\.id),
            ["app.luna.high", "app.luna.low", "app.luna.any"])
    }

    func testTheHostPreFilterDropsPluginsThatDoNotClaimTheHost() throws {
        try runner.load(
            plugin(id: "app.luna.example", body: claimingBody),
            plugin(id: "app.luna.any", hosts: nil, anyHost: true, body: claimingBody))

        XCTAssertEqual(
            runner.runtime.matchedPlugins(forHost: "other.test").map(\.id), ["app.luna.any"])
    }

    // MARK: - Invoking

    func testAClassifyClaimDecodesFromTheHooksAnswer() async throws {
        try runner.load(plugin(body: claimingBody))

        let claim = await runner.invoke(
            .classify, pluginID: "app.luna.test",
            argument: ClassifyInput(url: "https://example.com/v/abc", context: "app"),
            as: ClassifyClaim?.self)

        XCTAssertEqual(claim ?? nil, ClassifyClaim(kind: "media", itemId: "abc"))
    }

    func testAClassifyPassDecodesAsFalseRatherThanAsAFailure() async throws {
        try runner.load(plugin(body: claimingBody))

        let outcome = await runner.runtime.invoke(
            .classify, pluginID: "app.luna.test",
            argument: ClassifyInput(url: "https://example.com/about", context: "app"),
            timeout: 5, decode: Bool.self)

        XCTAssertEqual(try? outcome.get(), false)
    }

    func testAnIngestHookThatDeclinesAnswersNull() async throws {
        let body = """
        luna.register({
            classify() { return { kind: "media" }; },
            async ingest() { return null; }
        });
        """
        try runner.load(plugin(body: body))

        let model = await runner.invoke(
            .ingest, pluginID: "app.luna.test", as: PluginModel?.self)

        XCTAssertNil(model ?? nil)
    }

    func testAnIngestModelDecodesThroughTheSharedModelType() async throws {
        try runner.load(plugin(body: claimingBody))

        struct IngestInput: Encodable {
            let url: String
            let claim: Claim
            struct Claim: Encodable { let kind: String; let itemId: String }
        }
        let model = await runner.invoke(
            .ingest, pluginID: "app.luna.test",
            argument: IngestInput(
                url: "https://example.com/v/abc",
                claim: .init(kind: "media", itemId: "abc")),
            as: PluginModel.self)

        guard case .media(let media)? = model else { return XCTFail("expected a media Model") }
        XCTAssertEqual(media.title, "Clip abc")
        XCTAssertEqual(media.assets.map(\.url.absoluteString), ["https://example.com/v/abc.mp4"])
    }

    func testRegistrationRejectsNonFunctionsAndArrays() throws {
        for hooks in ["{ classify: 42, ingest() {} }", "{ classify: {}, ingest() {} }", "[]"] {
            let reports = try runner.load(plugin(body: "luna.register(\(hooks));"), expectingFailures: true)
            XCTAssertEqual(reports.first?.isLoaded, false, hooks)
            XCTAssertTrue(reports.first?.failure?.message.contains(hooks == "[]" ? "object of hooks" : "must be a function") == true, hooks)
        }
    }

    func testRegistrationCapturesGettersOnce() async throws {
        try runner.load(plugin(body: """
            let reads = 0;
            luna.register({
                get classify() { reads++; return () => ({kind: "media", itemId: String(reads)}); },
                ingest() { return null; }
            });
            """))
        let claim = await runner.invoke(.classify, pluginID: "app.luna.test", as: ClassifyClaim.self)
        XCTAssertEqual(claim?.itemId, "1")
    }

    func testSerializationAndThenableErrorsAreReportedWithoutTimingOut() async throws {
        let cases = [
            "const value = {}; value.self = value; return value;",
            "return Promise.resolve({value: 1n});",
            "return {toJSON() { throw new Error('serialization failed'); }};",
            "return {get then() { throw new Error('then getter failed'); }};",
            "return {then() { throw new Error('then call failed'); }};",
            "return Promise.reject('plain rejection');",
        ]
        for body in cases {
            try runner.load(plugin(body: "luna.register({classify() { \(body) }, ingest() { return null; }});"))
            let failure = await runner.invokeExpectingFailure(
                .classify, pluginID: "app.luna.test", timeout: 1, as: ClassifyClaim?.self)
            guard case .exception(let message, _)? = failure else {
                XCTFail("Expected an exception for \(body), got \(String(describing: failure))")
                continue
            }
            XCTAssertFalse(message.contains("undefined:"), message)
            if body.contains("plain rejection") { XCTAssertEqual(message, "plain rejection") }
        }
    }

    func testThenableSettlesOnlyOnceAndIgnoresLaterThrow() async throws {
        try runner.load(plugin(body: """
            luna.register({
                classify() { return {then(resolve, reject) {
                    resolve({kind: "media", itemId: "first"});
                    reject(new Error("late rejection"));
                    throw new Error("late throw");
                }}; },
                ingest() { return null; }
            });
            """))
        let claim = await runner.invoke(.classify, pluginID: "app.luna.test", as: ClassifyClaim.self)
        XCTAssertEqual(claim?.itemId, "first")
    }

    func testAHookThatThrowsCarriesItsMessageToTheStage() async throws {
        let body = """
        luna.register({
            classify() { throw new Error("no idea"); },
            async ingest() { return null; }
        });
        """
        try runner.load(plugin(body: body))

        let failure = await runner.invokeExpectingFailure(
            .classify, pluginID: "app.luna.test",
            argument: ClassifyInput(url: "https://example.com/v/a", context: "app"),
            as: ClassifyClaim?.self)

        guard case .exception(let message, _)? = failure else {
            return XCTFail("expected an exception, got \(String(describing: failure))")
        }
        XCTAssertTrue(message.contains("no idea"))
    }

    func testActivationSurfacesTopLevelFailureWithoutUnloadingThePreviousPlugin() throws {
        try runner.load(plugin(body: claimingBody))
        let broken = plugin(body: "throw new Error(\"activation boom\");")
        let manifest = try XCTUnwrap(try? PluginManifestParser.parse(source: broken).get())
        try runner.store.install(source: broken, manifest: manifest, origin: .paste)

        XCTAssertThrowsError(try runner.runtime.activate(pluginID: manifest.id)) { error in
            guard let activation = error as? PluginActivationError else {
                return XCTFail("expected activation failure, got \(error)")
            }
            guard case let .exception(message, _) = activation.failure else {
                return XCTFail("expected an exception, got \(activation.failure)")
            }
            XCTAssertTrue(message.contains("activation boom"))
        }
        XCTAssertEqual(runner.runtime.loadedPlugins.map(\.id), [manifest.id])
    }

    func testActivationSurfacesMissingRegistrationWithoutChangingTheLiveRuntime() throws {
        try runner.load(plugin(body: claimingBody))
        let broken = plugin(body: "luna.register({});")
        let manifest = try XCTUnwrap(try? PluginManifestParser.parse(source: broken).get())
        try runner.store.install(source: broken, manifest: manifest, origin: .paste)

        XCTAssertThrowsError(try runner.runtime.activate(pluginID: manifest.id)) { error in
            guard let activation = error as? PluginActivationError else {
                return XCTFail("expected activation failure, got \(error)")
            }
            XCTAssertEqual(activation.failure, .missingHook)
        }
        XCTAssertEqual(runner.runtime.loadedPlugins.map(\.id), [manifest.id])
    }

    @MainActor
    func testActivateAsyncReturnsBoundedlyForANonterminatingTopLevelScript() async throws {
        let source = plugin(body: "while (true) {}")
        let manifest = try XCTUnwrap(try? PluginManifestParser.parse(source: source).get())
        try runner.store.install(source: source, manifest: manifest, origin: .paste)
        let started = Date()

        do {
            try await runner.runtime.activateAsync(pluginID: manifest.id)
            XCTFail("a nonterminating draft must not activate")
        } catch let error as PluginActivationError {
            XCTAssertEqual(error.failure, .timedOut)
        }
        XCTAssertLessThan(
            Date().timeIntervalSince(started), 2,
            "async activation should not wait indefinitely on the main actor")
    }

    func testPluginIngestStageCorrelatesOverlappingRuntimeBridgeLogs() async throws {
        let firstURL = URL(string: "https://example.com/first")!
        let secondURL = URL(string: "https://example.com/second")!
        let logRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("plugin-runtime-diagnostics-\(UUID().uuidString)")
        let fetcher = StubPluginFetcher()
        fetcher.respond(to: firstURL.absoluteString, body: "first")
        fetcher.respond(to: secondURL.absoluteString, body: "second")
        fetcher.delay = 0.05
        let host = PluginJSFixtureRunner(
            fetcher: fetcher,
            diagnostics: PluginDiagnostics(log: DiagnosticLog(containerURL: logRoot)))
        defer {
            host.cleanUp()
            try? FileManager.default.removeItem(at: logRoot)
        }
        let body = """
        luna.register({
            async classify({ url }) {
                await luna.fetch({ url });
                luna.log("classified " + url);
                return false;
            },
            async ingest() { return null; }
        });
        """
        try host.load(plugin(capabilities: ["fetch"], body: body))
        let stage = PluginIngestStage(invoker: host.runtime, processKind: .app)
        let firstRecorder = SaveDiagnosticsRecorder(itemID: UUID())
        let secondRecorder = SaveDiagnosticsRecorder(itemID: UUID())

        async let first = SaveDiagnostics.$recorder.withValue(firstRecorder) {
            await stage.run(IngestInput(url: firstURL, source: .manual), fetcher: MockArticleFetcher())
        }
        async let second = SaveDiagnostics.$recorder.withValue(secondRecorder) {
            await stage.run(IngestInput(url: secondURL, source: .manual), fetcher: MockArticleFetcher())
        }
        _ = await (first, second)

        let firstLines = firstRecorder.drainLines().joined(separator: "\n")
        let secondLines = secondRecorder.drainLines().joined(separator: "\n")
        XCTAssertTrue(firstLines.contains(firstURL.absoluteString), firstLines)
        XCTAssertFalse(firstLines.contains(secondURL.absoluteString), firstLines)
        XCTAssertTrue(secondLines.contains(secondURL.absoluteString), secondLines)
        XCTAssertFalse(secondLines.contains(firstURL.absoluteString), secondLines)
    }

    func testLateRuntimeBridgeCallbackOnlyReachesTheGlobalDiagnosticsSink() async throws {
        let url = URL(string: "https://example.com/late")!
        let logRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("plugin-runtime-diagnostics-\(UUID().uuidString)")
        let fetcher = StubPluginFetcher()
        fetcher.respond(to: url.absoluteString, body: "late")
        fetcher.delay = 0.2
        let host = PluginJSFixtureRunner(
            fetcher: fetcher,
            diagnostics: PluginDiagnostics(log: DiagnosticLog(containerURL: logRoot)))
        defer {
            host.cleanUp()
            try? FileManager.default.removeItem(at: logRoot)
        }
        let body = """
        luna.register({
            async classify({ url }) {
                await luna.fetch({ url });
                return false;
            },
            async ingest() { return null; }
        });
        """
        try host.load(plugin(capabilities: ["fetch"], body: body))
        let recorder = SaveDiagnosticsRecorder(itemID: UUID())
        let result = await host.runtime.invoke(
            .classify, pluginID: "app.luna.test",
            argument: ["url": url.absoluteString], timeout: 0.05,
            decode: Bool.self, invocationID: UUID(), diagnosticRecorder: recorder)
        guard case .failure(.timedOut) = result else {
            return XCTFail("expected a timeout, got \(result)")
        }

        try await Task.sleep(nanoseconds: 400_000_000)
        let lines = recorder.drainLines().joined(separator: "\n")
        XCTAssertTrue(lines.contains("fetch GET \(url.absoluteString)"), lines)
        XCTAssertFalse(lines.contains("fetch → 200"), "late response leaked into closed save: \(lines)")
    }

    func testAHookThatRejectsWithBrowserDeferredIsReadAsTheDeferralItIs() async throws {
        let body = """
        luna.register({
            classify() { return { kind: "media" }; },
            async ingest() {
                throw new luna.LunaError("browser-deferred", "open the browser");
            }
        });
        """
        try runner.load(plugin(body: body))

        let failure = await runner.invokeExpectingFailure(
            .ingest, pluginID: "app.luna.test", as: PluginModel?.self)

        XCTAssertEqual(failure, .browserDeferred)
    }

    func testAnAnswerOfTheWrongShapeIsAMalformedResultRatherThanACrash() async throws {
        let body = """
        luna.register({
            classify() { return { kind: "media" }; },
            async ingest() { return { kind: "media", assets: "not a list" }; }
        });
        """
        try runner.load(plugin(body: body))

        let failure = await runner.invokeExpectingFailure(
            .ingest, pluginID: "app.luna.test", as: PluginModel.self)

        guard case .malformedResult? = failure else {
            return XCTFail("expected malformedResult, got \(String(describing: failure))")
        }
    }

    func testCallingAHookThePluginNeverRegisteredSaysMissingHook() async throws {
        try runner.load(plugin(body: claimingBody))

        let failure = await runner.invokeExpectingFailure(
            .export, pluginID: "app.luna.test", as: PluginModel?.self)

        XCTAssertEqual(failure, .missingHook)
    }

    func testCallingAPluginThatIsNotLoadedSaysNotLoaded() async {
        let failure = await runner.invokeExpectingFailure(
            .classify, pluginID: "app.luna.absent", as: ClassifyClaim?.self)

        XCTAssertEqual(failure, .notLoaded)
    }

    // MARK: - Budgets

    func testAHookThatNeverSettlesIsAbandonedAtItsBudget() async throws {
        let body = """
        luna.register({
            classify() { return new Promise(function () {}); },
            async ingest() { return null; }
        });
        """
        try runner.load(plugin(body: body))

        let failure = await runner.invokeExpectingFailure(
            .classify, pluginID: "app.luna.test",
            argument: ClassifyInput(url: "https://example.com/v/a", context: "app"),
            timeout: 0.2, as: ClassifyClaim?.self)

        XCTAssertEqual(failure, .timedOut)
        // The queue is free: only the pending Promise was abandoned, not a body.
        XCTAssertFalse(runner.runtime.isWedged)
    }

    func testThreeAbandonedCallsStopThePlugin() async throws {
        let body = """
        luna.register({
            classify() { return new Promise(function () {}); },
            async ingest() { return null; }
        });
        """
        try runner.load(plugin(body: body))

        for _ in 0..<PluginRuntime.timeoutsBeforeDisable {
            _ = await runner.runtime.invoke(
                .classify, pluginID: "app.luna.test",
                argument: ClassifyInput(url: "https://example.com/v/a", context: "app"),
                timeout: 0.1, decode: ClassifyClaim?.self)
        }

        XCTAssertEqual(runner.runtime.disabled["app.luna.test"], .stopped)
        XCTAssertTrue(runner.runtime.loadedPlugins.isEmpty)
        let failure = await runner.invokeExpectingFailure(
            .classify, pluginID: "app.luna.test",
            argument: ClassifyInput(url: "https://example.com/v/a", context: "app"),
            as: ClassifyClaim?.self)
        XCTAssertEqual(failure, .notLoaded)
    }

    func testAHookThatSettlesResetsTheStrikeCount() async throws {
        let body = """
        let calls = 0;
        luna.register({
            classify() {
                calls += 1;
                return calls === 1 ? new Promise(function () {}) : { kind: "media" };
            },
            async ingest() { return null; }
        });
        """
        try runner.load(plugin(body: body))
        let input = ClassifyInput(url: "https://example.com/v/a", context: "app")

        _ = await runner.runtime.invoke(
            .classify, pluginID: "app.luna.test", argument: input, timeout: 0.1,
            decode: ClassifyClaim?.self)
        _ = await runner.runtime.invoke(
            .classify, pluginID: "app.luna.test", argument: input, timeout: 2,
            decode: ClassifyClaim?.self)
        _ = await runner.runtime.invoke(
            .classify, pluginID: "app.luna.test", argument: input, timeout: 0.1,
            decode: ClassifyClaim?.self)

        XCTAssertNil(runner.runtime.disabled["app.luna.test"])
    }

    /// A call that never reached the front of the shared queue executed
    /// nothing, so abandoning it must not charge the plugin a strike or report
    /// the runtime wedged. One slow plugin used to stop every healthy one.
    func testACallThatNeverStartsCostsItsPluginNothing() async throws {
        let blocker = """
        luna.register({
            classify() {
                const until = Date.now() + 1500;
                while (Date.now() < until) { /* holds the shared queue */ }
                return false;
            },
            async ingest() { return null; }
        });
        """
        let waiter = """
        luna.register({
            classify() { return { kind: "media" }; },
            async ingest() { return null; }
        });
        """
        try runner.load(
            plugin(id: "app.luna.blocker", body: blocker),
            plugin(id: "app.luna.waiter", body: waiter))
        let input = ClassifyInput(url: "https://example.com/v/a", context: "app")

        async let slow = runner.runtime.invoke(
            .classify, pluginID: "app.luna.blocker", argument: input, timeout: 5,
            decode: ClassifyClaim?.self)
        var failures: [PluginInvocationFailure?] = []
        for _ in 0..<PluginRuntime.timeoutsBeforeDisable {
            let outcome = await runner.runtime.invoke(
                .classify, pluginID: "app.luna.waiter", argument: input, timeout: 0.05,
                decode: ClassifyClaim?.self)
            if case .failure(let failure) = outcome { failures.append(failure) }
        }
        _ = await slow

        XCTAssertEqual(failures, Array(repeating: .timedOut, count: failures.count))
        XCTAssertFalse(failures.isEmpty, "the waiter's calls queued behind the blocker")
        XCTAssertNil(
            runner.runtime.disabled["app.luna.waiter"],
            "a call that never ran collects no strike")
        XCTAssertFalse(
            runner.runtime.isWedged, "a cancelled queue item holds nothing")
    }

    /// Two calls of ONE plugin overlap, and a bridge callback cannot tell which
    /// hook's continuation it belongs to, so a touch reaches both. The quiet
    /// call's one slow fetch outlasts its own idle budget and survives on the
    /// busy call's activity.
    func testTwoOverlappingCallsOfOnePluginKeepEachOtherAlive() async throws {
        runner.fetcher.delays = [
            "https://example.com/slow": 0.7, "https://example.com/fast": 0.03,
        ]
        runner.fetcher.respond(to: "https://example.com/slow", body: "ok")
        runner.fetcher.respond(to: "https://example.com/fast", body: "ok")
        let body = """
        luna.register({
            classify() { return { kind: "media" }; },
            async ingest({ url }) {
                if (url.indexOf("/quiet") >= 0) {
                    await luna.fetch("https://example.com/slow");
                    return null;
                }
                for (let i = 0; i < 40; i += 1) {
                    await luna.fetch("https://example.com/fast");
                }
                return null;
            }
        });
        """
        try runner.load(plugin(
            id: "app.luna.pair", capabilities: ["fetch"], body: body))

        async let busy = runner.runtime.invoke(
            .ingest, pluginID: "app.luna.pair",
            argument: OverlapInput(url: "https://example.com/busy"), timeout: 5,
            decode: PluginJSONValue?.self)
        async let quiet = runner.runtime.invoke(
            .ingest, pluginID: "app.luna.pair",
            argument: OverlapInput(url: "https://example.com/quiet"), timeout: 0.35,
            decode: PluginJSONValue?.self)
        let outcomes = await [busy, quiet]

        for outcome in outcomes {
            if case .failure(let failure) = outcome {
                XCTFail("both calls settle: \(failure)")
            }
        }
    }

    private struct OverlapInput: Encodable { let url: String }

    /// The scratch root a killed process left is cleared before the reloaded
    /// context can serve a handle out of it.
    func testALoadReapsWhatAnEarlierProcessLeftBehind() throws {
        try runner.load(plugin(id: "app.luna.test", body: claimingBody))
        let leftover = try runner.scratch.writeFile(
            Data("stale".utf8), suggestedName: "old.txt", mime: nil,
            pluginID: "app.luna.test", generation: PluginScratchStore.idleGeneration)
        XCTAssertNotNil(runner.scratch.fileURL(for: leftover))

        runner.runtime.reloadAll()

        XCTAssertNil(runner.scratch.fileURL(for: leftover))
    }

    func testAPluginThatBlocksItsQueueWedgesTheRuntime() async throws {
        let body = """
        luna.register({
            classify() {
                const until = Date.now() + 3000;
                while (Date.now() < until) { /* the runtime cannot stop this */ }
                return false;
            },
            async ingest() { return null; }
        });
        """
        try runner.load(plugin(body: body))
        let input = ClassifyInput(url: "https://example.com/v/a", context: "app")

        let first = await runner.invokeExpectingFailure(
            .classify, pluginID: "app.luna.test", argument: input, timeout: 0.2,
            as: ClassifyClaim?.self)
        let second = await runner.invokeExpectingFailure(
            .classify, pluginID: "app.luna.test", argument: input, timeout: 0.2,
            as: ClassifyClaim?.self)

        XCTAssertEqual(first, .timedOut)
        XCTAssertEqual(second, .wedged)
        XCTAssertTrue(runner.runtime.isWedged)
        // The wedge clears by itself once the abandoned body finally returns.
        runner.awaitCondition("the wedge clears", timeout: 8) { !runner.runtime.isWedged }
    }

    func testTheIngestBudgetIsIdleRatherThanWallClock() async throws {
        // Eight 250 ms fetches exceed the 1.5 s wall-clock budget. Leave
        // scheduling headroom when this runs alongside WebKit/simulator tests.
        runner.fetcher.delay = 0.25
        runner.fetcher.respond(to: "https://example.com/x", body: "ok")
        let body = """
        luna.register({
            classify() { return { kind: "media" }; },
            async ingest() {
                for (let i = 0; i < 8; i++) {
                    await luna.fetch({ url: "https://example.com/x" });
                }
                return { kind: "media", title: "slow but alive",
                         assets: [{ url: "https://example.com/a.mp4", type: "video" }] };
            }
        });
        """
        try runner.load(plugin(capabilities: ["fetch"], body: body))

        struct Model: Decodable { let title: String }
        let model = await runner.invoke(
            .ingest, pluginID: "app.luna.test", timeout: 1.5, as: Model.self)

        XCTAssertEqual(model?.title, "slow but alive")
        XCTAssertEqual(runner.fetcher.requests.count, 8)
    }

    // MARK: - Reloading

    func testTimeoutsFromRetiredGenerationDoNotDisableReplacement() async throws {
        runner.fetcher.delay = 0.4
        runner.fetcher.respond(to: "https://example.com/slow", body: "ok")
        let old = """
        luna.register({
          classify() { return { kind: "media", itemId: "old" }; },
          async ingest() { await luna.fetch("https://example.com/slow"); return null; }
        });
        """
        try runner.load(plugin(capabilities: ["fetch"], body: old))

        let calls = (0..<3).map { _ in
            Task { await runner.runtime.invoke(
                .ingest, pluginID: "app.luna.test", argument: PluginEmptyArgument(),
                timeout: 0.05, decode: PluginJSONValue?.self) }
        }
        runner.awaitCondition("all old calls reach fetch") { runner.fetcher.requests.count == 3 }

        let replacement = """
        luna.register({
          classify() { return { kind: "media", itemId: "new" }; },
          async ingest() { return null; }
        });
        """
        try runner.install(plugin(body: replacement))
        XCTAssertTrue(runner.runtime.reload(pluginID: "app.luna.test").isLoaded)
        for call in calls { _ = await call.value }

        let claim = await runner.invoke(
            .classify, pluginID: "app.luna.test",
            argument: ClassifyInput(url: "https://example.com/x", context: "app"),
            as: ClassifyClaim?.self)
        XCTAssertEqual(claim ?? nil, ClassifyClaim(kind: "media", itemId: "new"))
        XCTAssertNil(runner.runtime.disabled["app.luna.test"])
    }

    func testClosedRuntimeScratchGenerationCannotBeRecreatedByLateWork() throws {
        let generation = "retired-generation"
        _ = runner.scratch.openScratchGeneration(
            pluginID: "app.luna.test", generationID: generation)
        runner.scratch.closeScratchGeneration(
            pluginID: "app.luna.test", generationID: generation)

        XCTAssertThrowsError(try runner.scratch.writeFile(
            Data("late".utf8), suggestedName: "late.txt", mime: nil,
            pluginID: "app.luna.test", generation: generation)) {
                XCTAssertEqual($0 as? PluginScratchError, .generationClosed)
            }
        XCTAssertFalse(FileManager.default.fileExists(atPath:
            runner.scratch.directoryURL(
                pluginID: "app.luna.test", generation: generation).path))
    }

    func testReloadingPicksUpAReplacedFile() async throws {
        try runner.load(plugin(body: claimingBody))
        let replaced = """
        luna.register({
            classify() { return { kind: "media", itemId: "second" }; },
            async ingest() { return null; }
        });
        """
        try runner.install(plugin(body: replaced))

        runner.runtime.reloadAll()

        let claim = await runner.invoke(
            .classify, pluginID: "app.luna.test",
            argument: ClassifyInput(url: "https://example.com/about", context: "app"),
            as: ClassifyClaim?.self)
        XCTAssertEqual(claim ?? nil, ClassifyClaim(kind: "media", itemId: "second"))
    }
}

/// Installs its namespace under the wrong name, to prove the runtime reads the
/// grant back out of the context rather than trusting the table that filled it.
private final class MisnamingCapabilityBridge: PluginCapabilityInstalling {
    let capabilityName = PluginCapabilityName.downloads

    func install(into namespace: PluginCapabilityNamespace) {
        namespace.install([:] as [String: Any], as: "somethingElse")
    }
}
