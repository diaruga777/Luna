//
//  PluginHTMLParityTests.swift
//  LunaTests
//

import XCTest

/// Runs `LunaTests/Fixtures/Plugins/html-subset.spec.js` against `plugin_host.js`'s
/// `DOMParser` backing, inside the shared bare `WKWebView` harness.
///
/// `PluginHTMLSubsetTests` runs the SAME file against the SwiftSoup backing in
/// JSC; `tools/plugin-sim/spec.mjs` runs it a third time under `linkedom`. The
/// spec file is the specification of the §6.3 subset, not a copy of any one
/// suite's expectations — a disagreement here is a defect in `plugin_host.js`'s
/// `html` implementation, never a reason to special-case Safari.
@MainActor
final class PluginHTMLParityTests: XCTestCase {

    private lazy var js = SafariJSTestHarness(self)

    private static let pluginHostSource = SafariJSTestHarness.source("LunaSafari/Resources/plugin_host.js")
    private static let specSource = SafariJSTestHarness.source("LunaTests/Fixtures/Plugins/html-subset.spec.js")

    override func setUp() {
        super.setUp()
        XCTAssertFalse(Self.pluginHostSource.isEmpty, "plugin_host.js is missing from disk")
        XCTAssertFalse(Self.specSource.isEmpty, "html-subset.spec.js is missing from disk")
        // Evaluating plugin_host.js at the page's top level makes its `var
        // LunaPluginHost = …` a global, exactly as `content.js` would see it if
        // it were loaded as a plain script rather than concatenated into a
        // `new Function` body with one plugin's source.
        js.load(html: SafariJSTestHarness.blankPage, urlString: "https://example.com/dir/page.html",
                scripts: [Self.pluginHostSource])
    }

    /// Every case run against `LunaPluginHost.html`, each answer and its
    /// expectation compared by `JSON.stringify` — every expectation in the
    /// spec file is a plain value (string/number/bool/array/null), so a
    /// literal string compare is exact, not an approximation.
    private func runSpec() -> [(name: String, ok: Bool, detail: String)] {
        let script = """
            (function () {
                var cases = (\(Self.specSource));
                var defaultBase = "https://example.com/dir/page.html";
                var results = [];
                cases.forEach(function (c) {
                    try {
                        var doc = LunaPluginHost.html.parse(c.html, c.baseURL || defaultBase);
                        var run = new Function("doc", "luna", c.script);
                        var answer = run(doc, { html: LunaPluginHost.html, text: LunaPluginHost.text });
                        var got = JSON.stringify(answer === undefined ? null : answer);
                        var want = JSON.stringify(c.expected === undefined ? null : c.expected);
                        results.push({ name: c.name, ok: got === want, detail: got + " vs " + want });
                    } catch (e) {
                        results.push({ name: c.name, ok: false, detail: "threw: " + e });
                    }
                });
                return JSON.stringify(results);
            })();
            """
        guard let json = js.evaluate(script) as? String,
              let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([SpecResult].self, from: data)
        else {
            XCTFail("the spec runner script did not answer a result list")
            return []
        }
        return decoded.map { ($0.name, $0.ok, $0.detail) }
    }

    private struct SpecResult: Decodable {
        let name: String
        let ok: Bool
        let detail: String
    }

    func testTheSubsetSpecHasEnoughCasesToBeASpecification() {
        XCTAssertGreaterThanOrEqual(runSpec().count, 100)
    }

    func testEverySpecCaseAgreesWithTheDOMParserBacking() {
        let results = runSpec()
        XCTAssertFalse(results.isEmpty)
        for result in results {
            XCTAssertTrue(result.ok, "\(result.name): \(result.detail)")
        }
    }
}
