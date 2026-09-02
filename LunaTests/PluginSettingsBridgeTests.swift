//
//  PluginSettingsBridgeTests.swift
//  LunaTests
//

import LunaPluginKit
import LunaPluginRuntime
import LunaPluginUI
import XCTest

/// `luna.settings`'s three real rules (`claudedocs/plugins.md` §5.4, §10.1):
/// an undeclared key is refused, an underscore-prefixed key is Luna's own and
/// always accepted even though no manifest may declare one, and a secret
/// field never hands its plaintext back to JavaScript.
final class PluginSettingsBridgeTests: XCTestCase {

    private var runner: PluginJSFixtureRunner!
    private var previousSettings: (any PluginSettingsStoring)?

    private static let pluginID = "app.luna.settingstest"

    private struct Answer: Decodable { let value: PluginJSONValue }

    override func setUp() {
        super.setUp()
        runner = PluginJSFixtureRunner()
        previousSettings = PluginPlatformServices.settings
        PluginPlatformServices.settings = runner.kv
        runner.capabilities.register(
            PluginSettingsBridge(processKind: .app, scheduler: runner.runtime))
    }

    override func tearDown() {
        PluginPlatformServices.settings = previousSettings
        runner.cleanUp()
        runner = nil
        super.tearDown()
    }

    private func answer(
        _ body: String, file: StaticString = #filePath, line: UInt = #line
    ) async -> String? {
        do {
            try runner.load(
                """
                /* luna-plugin
                { "id": "\(Self.pluginID)", "name": "Settings", "version": "1.0.0", "api": 1,
                  "capabilities": ["settings"],
                  "settings": [
                    { "key": "apiKey", "type": "password", "label": "API Key", "secret": true },
                    { "key": "mode", "type": "text", "label": "Mode", "default": "auto" }
                  ]
                }
                */
                luna.register({ async onAction() { \(body) } });
                """, file: file, line: line)
        } catch { return nil }
        guard let answer = await runner.invoke(
            .onAction, pluginID: Self.pluginID, as: Answer.self, file: file, line: line)
        else { return nil }
        return answer.value.jsonText
    }

    func testSetRefusesAKeyTheManifestDoesNotDeclare() async {
        let json = await answer("""
            try {
                await luna.settings.set("nope", "x");
                return { value: "no error" };
            } catch (error) {
                return { value: error.code };
            }
        """)
        XCTAssertEqual(json, "\"bad-argument\"")
    }

    /// `_status` is the one reserved key a destination plugin writes to drive
    /// its own share row's dot; no manifest may declare it, but `set` still
    /// takes it.
    func testSetAcceptsAnUnderscorePrefixedKeyEvenThoughNoFieldDeclaresIt() async {
        let json = await answer("""
            await luna.settings.set("_status", "off");
            return { value: await luna.settings.get("_status") };
        """)
        XCTAssertEqual(json, "\"off\"")
    }

    func testASecretFieldReadsBackAsAnEmptyStringOnceSet() async {
        let json = await answer("""
            await luna.settings.set("apiKey", "sk-real-value");
            return { value: await luna.settings.get("apiKey") };
        """)
        XCTAssertEqual(json, "\"\"", "the plaintext never reaches JavaScript")
    }

    func testGetAnswersTheFieldsDefaultWhenNothingIsStored() async {
        let json = await answer("""
            return { value: await luna.settings.get("mode") };
        """)
        XCTAssertEqual(json, "\"auto\"")
    }
}
