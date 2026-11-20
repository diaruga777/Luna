//
//  PluginHTMLSubsetTests.swift
//  LunaTests
//

import LunaPluginKit
import LunaPluginRuntime
import XCTest

/// Runs `LunaTests/Fixtures/Plugins/html-subset.spec.js` against the SwiftSoup
/// backing of `luna.html`.
///
/// The spec file is the SPECIFICATION of the §6.3 subset, not a copy of this
/// suite's expectations: Wave 2's Safari runner evaluates the same file against
/// the `DOMParser` backing, and a disagreement between the two is a defect in
/// one backing rather than a reason for a second expectation.
final class PluginHTMLSubsetTests: XCTestCase {

    private let pluginID = "app.luna.htmlsubset"

    private func pluginSource() -> String {
        let cases = SafariJSSource.read("LunaTests/Fixtures/Plugins/html-subset.spec.js")
        let helper = SafariJSSource.read("docs/plugins/lib/web.js")
        XCTAssertFalse(cases.isEmpty)
        XCTAssertFalse(helper.isEmpty)
        return """
        /* luna-plugin
        { "id": "\(pluginID)", "name": "HTML subset", "version": "1.0.0", "api": 1,
          "capabilities": ["html"] }
        */
        \(helper)
        const cases = (\(cases));
        luna.register({
            onAction({ index }) {
                if (index === undefined) return { names: cases.map(spec => spec.name) };
                const spec = cases[index];
                const doc = luna.html.parse(spec.html, spec.baseURL ?? "https://example.com/dir/page.html");
                const run = new Function("doc", "luna", "LunaWeb", spec.script);
                return { actual: run(doc, luna, LunaWeb) ?? null, expected: spec.expected };
            }
        });
        """
    }

    func testEverySpecCaseAgreesWithTheSwiftSoupBacking() async throws {
        // Read the fixture and run all its cases on one VM and context. The
        // shared VM may have handled hundreds of unrelated plugin fixtures.
        let runner = PluginJSFixtureRunner(isolated: true)
        defer { runner.cleanUp() }
        try runner.load(pluginSource())
        let list = await runner.invoke(.onAction, pluginID: pluginID, as: CaseList.self)
        let names = try XCTUnwrap(list).names
        XCTAssertGreaterThanOrEqual(names.count, 100)
        for (index, name) in names.enumerated() {
            let result = await runner.invoke(
                .onAction, pluginID: pluginID, argument: CaseIndex(index: index), as: CaseResult.self)
            let answer = try XCTUnwrap(result, name)
            XCTAssertEqual(answer.actual.jsonText, answer.expected.jsonText, name)
        }
    }

    private struct CaseList: Decodable {
        let names: [String]
    }

    private struct CaseIndex: Encodable {
        let index: Int
    }

    private struct CaseResult: Decodable {
        let actual: PluginJSONValue
        let expected: PluginJSONValue
    }

}

/// Any JSON value, kept as its text. It exists so a test can compare a hook's
/// answer without naming its shape.
struct PluginJSONValue: Decodable {
    let jsonText: String

    /// A JSON string literal. `JSONEncoder` is asked NOT to escape slashes, so
    /// a URL reads as a plugin author wrote it.
    static func quoted(_ text: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard let data = try? encoder.encode([text]) else { return "\"\"" }
        let array = String(decoding: data, as: UTF8.self)
        return String(array.dropFirst().dropLast())
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            jsonText = "null"
        } else if let value = try? container.decode(Bool.self) {
            jsonText = value ? "true" : "false"
        } else if let value = try? container.decode(Double.self) {
            jsonText = value == value.rounded() && abs(value) < 1e15
                ? String(Int(value)) : String(value)
        } else if let value = try? container.decode(String.self) {
            jsonText = PluginJSONValue.quoted(value)
        } else if let value = try? container.decode([PluginJSONValue].self) {
            jsonText = "[\(value.map(\.jsonText).joined(separator: ","))]"
        } else if let value = try? container.decode([String: PluginJSONValue].self) {
            let pairs = value.keys.sorted().map { key -> String in
                "\(PluginJSONValue.quoted(key)):\(value[key]!.jsonText)"
            }
            jsonText = "{\(pairs.joined(separator: ","))}"
        } else {
            jsonText = "null"
        }
    }
}
