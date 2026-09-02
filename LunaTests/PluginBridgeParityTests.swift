//
//  PluginBridgeParityTests.swift
//  LunaTests
//

import LunaPluginKit
import LunaPluginRuntime
import LunaPluginUI
import XCTest

/// One probe script, run through BOTH JavaScript backings a plugin can meet.
///
/// `PluginJSFixtureRunner` runs it over the shipped JavaScriptCore bridges (the
/// app and the share/action extensions); `SafariJSTestHarness` runs the same
/// text through `plugin_host.js` the way `content.js` loads it — the host's
/// source concatenated ahead of the plugin's own inside one `new Function`
/// body. Each case asserts the two answered the same thing, which is what
/// `PluginHTMLParityTests` already does for `luna.html` and this extends to
/// error shape, storage semantics and settings.
///
/// The JavaScriptCore side runs as a SHARE process, because Safari's `luna`
/// is the extension contract rather than the app's: `luna.settings.set` is the
/// app's alone in both worlds.
///
/// What a case may compare: everything the two BRIDGES decide. The rules the
/// native handler applies before answering (a settings default, a secret
/// masked to `""`, `capability-not-declared` versus `bad-argument`) live in
/// `LunaSafari/SafariPluginMessages+Luna.swift`, which no test can link —
/// `SafariPluginHandlerSourceTests` pins those.
@MainActor
final class PluginBridgeParityTests: XCTestCase {

    private var runner: PluginJSFixtureRunner!
    private var previousSettings: PluginSettingsStoring?
    private lazy var js = SafariJSTestHarness(self)

    private static let pluginHostSource =
        SafariJSTestHarness.source("LunaSafari/Resources/plugin_host.js")

    private static let capabilities = ["storage", "settings", "ui"]

    override func setUp() {
        super.setUp()
        XCTAssertFalse(Self.pluginHostSource.isEmpty, "plugin_host.js is missing from disk")
        runner = PluginJSFixtureRunner(processKind: .share)
        previousSettings = PluginPlatformServices.settings
        PluginPlatformServices.settings = runner.kv
        js.load(html: SafariJSTestHarness.blankPage, urlString: "https://example.com/page",
                scripts: [Self.pluginHostSource])
    }

    override func tearDown() {
        PluginPlatformServices.settings = previousSettings
        runner.cleanUp()
        runner = nil
        super.tearDown()
    }

    // MARK: - The probe

    /// What one probe answered, in the one shape both backings report.
    private struct ProbeAnswer: Decodable {
        let settled: String
        var type: String?
        var json: String?
        var code: String?
        var message: String?
    }

    /// The plugin both backings load: the SAME text, differing only in the id
    /// its store needs and the expression under test.
    private static func pluginSource(id: String, expression: String) -> String {
        """
        /* luna-plugin
        { "id": "\(id)", "name": "Parity", "version": "1.0.0", "api": 1,
          "capabilities": ["storage", "settings", "ui"],
          "settings": [{ "key": "quality", "type": "text", "label": "Quality",
                         "default": "1080p" }] }
        */
        luna.register({
            async onAction() {
                try {
                    const value = await (\(expression));
                    return {
                        settled: "fulfilled", type: typeof value,
                        json: value === undefined ? "" : JSON.stringify(value)
                    };
                } catch (error) {
                    return {
                        settled: "rejected",
                        code: String(error && error.code),
                        message: String(error && error.message)
                    };
                }
            }
        });
        """
    }

    private func javaScriptCoreAnswer(
        _ expression: String, id: String,
        file: StaticString = #filePath, line: UInt = #line
    ) async -> ProbeAnswer? {
        do {
            try runner.load(
                Self.pluginSource(id: id, expression: expression), file: file, line: line)
        } catch {
            return nil
        }
        return await runner.invoke(
            .onAction, pluginID: id, as: ProbeAnswer.self, file: file, line: line)
    }

    /// Loads the same plugin the way `content.js`'s `loadPluginRuntime` does,
    /// over a `sendNative` that answers the reply SHAPES
    /// `SafariPluginMessages+Luna.swift` answers with. The rules that pick
    /// between those shapes are the thing under test on the other side of the
    /// message, so the stub holds none of them — it is a store, not a second
    /// implementation.
    private func safariAnswer(
        _ expression: String, id: String,
        settings: [String: String] = [:],
        file: StaticString = #filePath, line: UInt = #line
    ) -> ProbeAnswer? {
        let source = Self.pluginSource(id: id, expression: expression)
        _ = js.evaluate("""
            window.__lunaNativeStore = {};
            window.__lunaNativeSettings = \(Self.jsLiteral(settings));
            window.__lunaProbe = null;
            var body = \(Self.jsLiteral(Self.pluginHostSource)) + "\\n;\\n"
                + "var luna = LunaPluginHost.createBridge(__pluginConfig, __pluginSendNative);\\n"
                + \(Self.jsLiteral(source)) + "\\n"
                + "return luna;";
            var factory = new Function("__pluginConfig", "__pluginSendNative", body);
            var config = {
                pluginId: \(Self.jsLiteral(id)), version: "1.0.0",
                capabilities: \(Self.jsLiteral(Self.capabilities)), locale: "en"
            };
            var sendNative = function (type, payload) {
                var store = window.__lunaNativeStore;
                switch (type) {
                case "plugins.storage.get":
                    return Promise.resolve(
                        payload.key in store ? { value: store[payload.key] } : {});
                case "plugins.storage.set":
                    store[payload.key] = payload.value;
                    return Promise.resolve({ ok: true });
                case "plugins.storage.delete":
                    delete store[payload.key];
                    return Promise.resolve({ ok: true });
                case "plugins.storage.keys":
                    return Promise.resolve({ keys: Object.keys(store).sort() });
                case "plugins.settings.get":
                    return Promise.resolve(
                        payload.key in window.__lunaNativeSettings
                            ? { value: window.__lunaNativeSettings[payload.key] } : {});
                default:
                    return Promise.resolve({});
                }
            };
            var luna = factory(config, sendNative);
            luna.__registeredHooks.onAction().then(function (answer) {
                window.__lunaProbe = JSON.stringify(answer);
            }, function (error) {
                window.__lunaProbe = JSON.stringify(
                    { settled: "threw", message: String(error && error.message) });
            });
            "kicked"
            """)
        // The hook settles on a microtask after one relayed round trip, so the
        // answer is polled rather than waited out for a fixed duration.
        var json: String?
        for _ in 0..<200 {
            json = js.string("window.__lunaProbe")
            if json != nil { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        guard let json, let data = json.data(using: .utf8),
              let answer = try? JSONDecoder().decode(ProbeAnswer.self, from: data)
        else {
            XCTFail("the Safari probe never answered", file: file, line: line)
            return nil
        }
        return answer
    }

    /// Runs one expression through both backings and asserts they agree.
    /// A fulfilled answer must carry the same type and the same JSON; a
    /// rejected one the same `code` — the message is prose each process writes
    /// for its own reader.
    private func assertBackingsAgree(
        _ expression: String, id: String, settings: [String: String] = [:],
        file: StaticString = #filePath, line: UInt = #line
    ) async -> ProbeAnswer? {
        guard let core = await javaScriptCoreAnswer(expression, id: id, file: file, line: line),
              let safari = safariAnswer(
                expression, id: id, settings: settings, file: file, line: line)
        else { return nil }
        XCTAssertEqual(
            core.settled, safari.settled,
            "\(expression): JavaScriptCore \(core.settled), Safari \(safari.settled) "
                + "(\(core.message ?? core.json ?? "") / \(safari.message ?? safari.json ?? ""))",
            file: file, line: line)
        if core.settled == "fulfilled" {
            XCTAssertEqual(core.type, safari.type, expression, file: file, line: line)
            XCTAssertEqual(core.json, safari.json, expression, file: file, line: line)
        } else {
            XCTAssertEqual(core.code, safari.code, expression, file: file, line: line)
        }
        return core
    }

    private static func jsLiteral(_ value: Any) -> String {
        let data = try? JSONSerialization.data(
            withJSONObject: ["v": value], options: [.fragmentsAllowed])
        let text = data.flatMap { String(data: $0, encoding: .utf8) } ?? "{\"v\":null}"
        return String(text.dropFirst(5).dropLast())
    }

    // MARK: - LunaError

    /// `new luna.LunaError(code, message)` — the argument order every bundled
    /// plugin and `docs/plugins/api.md` use. Reading the message as the code
    /// is what made a plugin branching on `error.code` behave differently in
    /// Safari.
    func testTheErrorConstructorTakesTheCodeFirstInBothBackings() async {
        let answer = await assertBackingsAgree(
            """
            (function () {
                const error = new luna.LunaError("hard", "the reader refused it", { at: 2 });
                return {
                    name: error.name, code: error.code, message: error.message,
                    details: error.details, isError: error instanceof Error
                };
            })()
            """,
            id: "app.luna.parity.error")
        XCTAssertEqual(
            answer?.json,
            #"{"name":"LunaError","code":"hard","message":"the reader refused it","details":{"at":2},"isError":true}"#)
    }

    /// A hook that throws a `LunaError` is the shape `PluginExportStage
    /// .isTerminal` reads a `"hard:"` prefix off, so a thrown error must carry
    /// its code in both worlds.
    func testAThrownLunaErrorKeepsItsCodeInBothBackings() async {
        let answer = await assertBackingsAgree(
            """
            Promise.reject(new luna.LunaError("hard", "the address is wrong"))
            """,
            id: "app.luna.parity.throw")
        XCTAssertEqual(answer?.code, "hard")
    }

    // MARK: - luna.storage

    func testAKeyThatHoldsNothingAnswersUndefinedInBothBackings() async {
        let answer = await assertBackingsAgree(
            #"luna.storage.get("never-written")"#, id: "app.luna.parity.missing")
        XCTAssertEqual(answer?.type, "undefined")
    }

    /// `undefined` is not a value. A native message drops an undefined field,
    /// so Safari used to store JSON null and answer `{ok:true}`.
    func testStoringUndefinedRejectsBadArgumentInBothBackings() async {
        let answer = await assertBackingsAgree(
            #"luna.storage.set("k", undefined)"#, id: "app.luna.parity.undef")
        XCTAssertEqual(answer?.code, "bad-argument")
    }

    func testAValueComesBackAsTheShapeItWasStoredAsInBothBackings() async {
        let answer = await assertBackingsAgree(
            """
            luna.storage.set("profile", { name: "a", tags: [1, 2] })
                .then(function () { return luna.storage.get("profile"); })
            """,
            id: "app.luna.parity.roundtrip")
        XCTAssertEqual(answer?.json, #"{"name":"a","tags":[1,2]}"#)
    }

    func testStoredKeysListTheSameWayInBothBackings() async {
        let answer = await assertBackingsAgree(
            """
            Promise.all([luna.storage.set("b", 1), luna.storage.set("a", 2)])
                .then(function () { return luna.storage.keys(); })
                .then(function (keys) { return keys.slice().sort(); })
            """,
            id: "app.luna.parity.keys")
        XCTAssertEqual(answer?.json, #"["a","b"]"#)
    }

    /// A nameless collection rejects rather than throwing synchronously, so a
    /// plugin reads a code off it in either process.
    func testANamelessCollectionRejectsBadArgumentInBothBackings() async {
        let answer = await assertBackingsAgree(
            #"luna.storage.collection("")"#, id: "app.luna.parity.collection")
        XCTAssertEqual(answer?.code, "bad-argument")
    }

    // MARK: - luna.settings

    func testASettingReadsBackItsStoredValueInBothBackings() async {
        try? PluginPlatformServices.settings?.setValueJSON(
            "\"720p\"", pluginID: "app.luna.parity.settings", key: "quality")
        let answer = await assertBackingsAgree(
            #"luna.settings.get("quality")"#,
            id: "app.luna.parity.settings", settings: ["quality": "720p"])
        XCTAssertEqual(answer?.json, "\"720p\"")
    }

    /// Writing a setting from an extension or a page would change what the
    /// user sees in Settings from a process they cannot see.
    func testWritingASettingOutsideTheAppRejectsUnavailableHereInBothBackings() async {
        let answer = await assertBackingsAgree(
            #"luna.settings.set("quality", "720p")"#, id: "app.luna.parity.settingsset")
        XCTAssertEqual(answer?.code, "unavailable-here")
    }

    // MARK: - The unavailable-here stand-in

    /// A capability the plugin DECLARED that this process cannot serve still
    /// exists, and every call on it rejects a `LunaError` — never a TypeError
    /// the author cannot branch on by code.
    func testADeclaredButUnservedNamespaceRejectsUnavailableHereInBothBackings() async {
        let member = await assertBackingsAgree(
            #"luna.ui.choose({ title: "x", options: [] })"#, id: "app.luna.parity.ui")
        XCTAssertEqual(member?.code, "unavailable-here")
        let called = await assertBackingsAgree(
            "luna.ui()", id: "app.luna.parity.uicall")
        XCTAssertEqual(called?.code, "unavailable-here")
    }
}
