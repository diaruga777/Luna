//
//  SafariPluginHostTests.swift
//  LunaTests
//

import XCTest

/// The content-script bridge `plugin_host.js` builds
/// (`claudedocs/plans/plugin-platform.md` §6, §13.1), driven the same way
/// `content.js` drives it: `plugin_host.js`'s text and a toy plugin's text
/// concatenated into one `new Function` body, called with a `sendNative` stub
/// instead of a real native-messaging round trip.
@MainActor
final class SafariPluginHostTests: XCTestCase {

    private lazy var js = SafariJSTestHarness(self)

    private static let pluginHostSource = SafariJSTestHarness.source("LunaSafari/Resources/plugin_host.js")

    override func setUp() {
        super.setUp()
        XCTAssertFalse(Self.pluginHostSource.isEmpty, "plugin_host.js is missing from disk")
        js.load(html: SafariJSTestHarness.blankPage, urlString: "https://example.com/reel/abc",
                scripts: [Self.pluginHostSource])
    }

    /// Wires one plugin's source into a `new Function` exactly as `content.js`'s
    /// `loadPluginRuntime` does, with a fake `sendNative` that records every
    /// message and answers a canned reply.
    private func loadPlugin(capabilities: [String], source: String) {
        _ = js.evaluate("""
            window.__lunaSendNativeCalls = [];
            window.__lunaSendNativeReplies = {};
            window.__lunaSetSendNativeReply = function (type, reply) {
                window.__lunaSendNativeReplies[type] = reply;
            };
            var body = \(json(Self.pluginHostSource)) + "\\n;\\n"
                + "var luna = LunaPluginHost.createBridge(__pluginConfig, __pluginSendNative);\\n"
                + \(json(source)) + "\\n"
                + "return luna;";
            var factory = new Function("__pluginConfig", "__pluginSendNative", body);
            var config = { pluginId: "app.luna.test", version: "1.0.0", capabilities: \(json(capabilities)), locale: "en" };
            var sendNative = function (type, payload) {
                window.__lunaSendNativeCalls.push({ type: type, payload: payload });
                var reply = window.__lunaSendNativeReplies[type];
                return Promise.resolve(reply !== undefined ? reply : {});
            };
            window.__lunaTestLuna = factory(config, sendNative);
            "loaded"
            """)
    }

    private func json(_ value: Any) -> String {
        let data = try? JSONSerialization.data(withJSONObject: ["v": value], options: [.fragmentsAllowed])
        let text = data.flatMap { String(data: $0, encoding: .utf8) } ?? "{\"v\":null}"
        return String(text.dropFirst(5).dropLast())
    }

    // MARK: - register + classify

    func testAPluginRegistersAndItsClassifyHookRuns() {
        loadPlugin(capabilities: [], source: """
            /* luna-plugin
            { "id": "app.luna.test", "name": "Test", "version": "1.0.0", "api": 1,
              "produces": ["media"], "match": { "hosts": ["example.com"] } }
            */
            luna.register({
                classify: function (input) {
                    var parts = input.url.split("/reel/");
                    return parts.length === 2 ? { kind: "media", itemId: parts[1] } : false;
                }
            });
            """)
        let claimed = js.evaluate("""
            window.__lunaTestLuna.__registeredHooks.classify(
                { url: "https://example.com/reel/abc", context: "safari" }
            )
            """)
        // `evaluateJavaScript` resolves a returned plain value synchronously;
        // the hook above is synchronous, so no promise unwrap is needed.
        guard let dict = claimed as? [String: Any] else {
            return XCTFail("expected the classify verdict object, got \(String(describing: claimed))")
        }
        XCTAssertEqual(dict["kind"] as? String, "media")
        XCTAssertEqual(dict["itemId"] as? String, "abc")
    }

    // MARK: - capability gating

    func testObjectKeysMatchesOnlyTheDeclaredCapabilitiesPlusAlwaysPresent() {
        loadPlugin(capabilities: ["html", "storage"], source: """
            /* luna-plugin
            { "id": "app.luna.test", "name": "Test", "version": "1.0.0", "api": 1,
              "capabilities": ["html", "storage"] }
            */
            luna.register({});
            """)
        let keys = js.evaluate("Object.keys(window.__lunaTestLuna).sort()") as? [String] ?? []
        XCTAssertTrue(keys.contains("html"), "declared capability must be present")
        XCTAssertTrue(keys.contains("storage"), "declared capability must be present")
        XCTAssertTrue(keys.contains("register"), "always-present namespace missing")
        XCTAssertTrue(keys.contains("parseURL"), "always-present namespace missing")
        XCTAssertTrue(keys.contains("log"), "always-present namespace missing")
        XCTAssertTrue(keys.contains("env"), "always-present namespace missing")
        XCTAssertFalse(keys.contains("fetch"), "undeclared capability must be absent, not a stub")
        XCTAssertFalse(keys.contains("browser"), "undeclared capability must be absent, not a stub")
        XCTAssertFalse(keys.contains("secrets"), "secrets is never available in Safari")
        XCTAssertFalse(keys.contains("ui"), "ui is never available in Safari")
    }

    // MARK: - luna.html subset (smoke; PluginHTMLParityTests is the full spec)

    func testLunaHtmlParsesAndQueries() {
        loadPlugin(capabilities: ["html"], source: """
            /* luna-plugin
            { "id": "app.luna.test", "name": "Test", "version": "1.0.0", "api": 1,
              "capabilities": ["html"] }
            */
            luna.register({});
            """)
        let text = js.evaluate("""
            window.__lunaTestLuna.html.parse("<p class='a'>hi</p>", "https://example.com/x")
                .querySelector(".a").textContent
            """) as? String
        XCTAssertEqual(text, "hi")
    }

    // MARK: - browser capability always defers

    func testLunaBrowserOpenAlwaysRejectsWithBrowserDeferred() {
        loadPlugin(capabilities: ["browser"], source: """
            /* luna-plugin
            { "id": "app.luna.test", "name": "Test", "version": "1.0.0", "api": 1,
              "capabilities": ["browser"] }
            */
            luna.register({});
            """)
        _ = js.evaluate("""
            window.__lunaBrowserOutcome = "pending";
            window.__lunaTestLuna.browser.open({ url: "https://example.com/x", detect: "'done'" })
                .then(function () { window.__lunaBrowserOutcome = "resolved"; },
                      function (e) { window.__lunaBrowserOutcome = e.code; });
            "kicked"
            """)
        _ = js.evaluate("void 0") // let the microtask settle
        XCTAssertEqual(js.string("window.__lunaBrowserOutcome"), "browser-deferred")
    }

    // MARK: - localization (parity with PluginLocalizedText.resolve)

    /// `LunaPluginHost.resolveLocalized` and `PluginLocalizedText.resolve`
    /// (`PluginLocalizedTextTests`) apply the same rule to the same table and
    /// preferred-language list — an exact tag, then that tag's language, then
    /// `"en"`. This pins the JS side to that same answer.
    func testResolveLocalizedMatchesTheSwiftRule() {
        let table = "{ en: 'Hello', 'de-AT': 'Servus', de: 'Hallo' }"

        XCTAssertEqual(
            js.string("LunaPluginHost.resolveLocalized(\(table), ['de-AT'])"), "Servus",
            "an exact tag wins")
        XCTAssertEqual(
            js.string("LunaPluginHost.resolveLocalized(\(table), ['de-CH'])"), "Hallo",
            "an unmatched tag falls back to its language prefix")
        XCTAssertEqual(
            js.string("LunaPluginHost.resolveLocalized(\(table), ['fr'])"), "Hello",
            "no match at all falls back to \"en\"")
        XCTAssertEqual(
            js.string("LunaPluginHost.resolveLocalized('Hello', ['fr'])"), "Hello",
            "a plain string passes through")
    }

    func testEnvLanguagesIsANonEmptyArrayAndLocaleIsItsFirstEntry() {
        loadPlugin(capabilities: [], source: """
            /* luna-plugin
            { "id": "app.luna.test", "name": "Test", "version": "1.0.0", "api": 1 }
            */
            luna.register({});
            """)
        let ok = js.evaluate("""
            Array.isArray(window.__lunaTestLuna.env.languages)
                && window.__lunaTestLuna.env.languages.length > 0
                && window.__lunaTestLuna.env.locale === window.__lunaTestLuna.env.languages[0]
            """) as? Bool
        XCTAssertEqual(ok, true)
    }

    func testLunaLocalizeResolvesAgainstEnvLanguages() {
        loadPlugin(capabilities: [], source: """
            /* luna-plugin
            { "id": "app.luna.test", "name": "Test", "version": "1.0.0", "api": 1 }
            */
            luna.register({});
            """)
        let resolved = js.string("window.__lunaTestLuna.localize({ en: 'Hello' })")
        XCTAssertEqual(resolved, "Hello")
        let passthrough = js.string("window.__lunaTestLuna.localize('Hello')")
        XCTAssertEqual(passthrough, "Hello")
    }
}
