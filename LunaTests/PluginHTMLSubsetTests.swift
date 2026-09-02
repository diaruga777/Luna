//
//  PluginHTMLSubsetTests.swift
//  LunaTests
//

import JavaScriptCore
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

    /// One case from the spec file.
    private struct SubsetCase: Decodable {
        let name: String
        let html: String
        let script: String
        let baseURL: String?
        /// The expected answer as JSON text, so a case may expect null, a
        /// number, a string or a list without a Swift type per shape.
        let expectedJSON: String
    }

    static let defaultBaseURL = "https://example.com/dir/page.html"

    /// The spec file's cases, read from the repository beside this test.
    private func specCases(file: StaticString = #filePath, line: UInt = #line) -> [SubsetCase] {
        let specURL = URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Plugins/html-subset.spec.js")
        guard let text = try? String(contentsOf: specURL, encoding: .utf8) else {
            XCTFail("missing html-subset.spec.js at \(specURL.path)", file: file, line: line)
            return []
        }
        // The file evaluates to the case list, so one evaluation reads it — the
        // same way the Safari and node runners consume it.
        let context = JSContext()!
        guard let list = context.evaluateScript("(\(text))"), list.isObject,
              let count = list.objectForKeyedSubscript("length")?.toNumber()?.intValue
        else {
            XCTFail("html-subset.spec.js did not evaluate to a list", file: file, line: line)
            return []
        }
        var cases: [SubsetCase] = []
        for index in 0..<count {
            guard let entry = list.objectAtIndexedSubscript(index) else { continue }
            let expected = context.objectForKeyedSubscript("JSON")?
                .objectForKeyedSubscript("stringify")?
                .call(withArguments: [entry.objectForKeyedSubscript("expected") as Any])
            cases.append(SubsetCase(
                name: entry.objectForKeyedSubscript("name")?.toString() ?? "case \(index)",
                html: entry.objectForKeyedSubscript("html")?.toString() ?? "",
                script: entry.objectForKeyedSubscript("script")?.toString() ?? "",
                baseURL: entry.objectForKeyedSubscript("baseURL").flatMap {
                    $0.isString ? $0.toString() : nil
                },
                expectedJSON: expected?.toString() ?? "null"))
        }
        return cases
    }

    /// A plugin that runs one case's script and answers its JSON.
    private func pluginSource(for spec: SubsetCase) -> String {
        let base = spec.baseURL ?? Self.defaultBaseURL
        return """
        /* luna-plugin
        { "id": "app.luna.htmlsubset", "name": "HTML subset", "version": "1.0.0", "api": 1,
          "capabilities": ["html"] }
        */
        luna.register({
            async onAction() {
                const doc = luna.html.parse(\(jsString(spec.html)), \(jsString(base)));
                const run = new Function("doc", "luna", \(jsString(spec.script)));
                return { answer: run(doc, luna) };
            }
        });
        """
    }

    /// A JS string literal for arbitrary text. `JSONSerialization` escapes what
    /// a hand-rolled quote would miss.
    private func jsString(_ text: String) -> String {
        guard let data = try? JSONSerialization.data(
            withJSONObject: text, options: [.fragmentsAllowed])
        else { return "\"\"" }
        return String(decoding: data, as: UTF8.self)
    }

    func testTheSubsetSpecHasEnoughCasesToBeASpecification() {
        XCTAssertGreaterThanOrEqual(specCases().count, 40)
    }

    func testEverySpecCaseAgreesWithTheSwiftSoupBacking() async throws {
        let cases = specCases()
        XCTAssertFalse(cases.isEmpty)
        for spec in cases {
            let isolated = PluginJSFixtureRunner()
            defer { isolated.cleanUp() }
            do {
                try isolated.load(pluginSource(for: spec))
            } catch {
                XCTFail("\(spec.name): the case plugin did not load: \(error)")
                continue
            }
            let outcome = await isolated.runtime.invoke(
                .onAction, pluginID: "app.luna.htmlsubset", argument: PluginEmptyArgument(),
                timeout: 5, decode: SubsetAnswer.self)
            switch outcome {
            case .failure(let failure):
                XCTFail("\(spec.name): \(failure)")
            case .success(let answer):
                XCTAssertEqual(
                    Self.canonical(answer.answerJSON), Self.canonical(spec.expectedJSON),
                    "\(spec.name)")
            }
        }
    }

    /// The case's answer, kept as JSON text so a comparison does not need a
    /// Swift type per shape.
    private struct SubsetAnswer: Decodable {
        let answerJSON: String

        private enum CodingKeys: String, CodingKey { case answer }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let value = try container.decode(PluginJSONValue.self, forKey: .answer)
            answerJSON = value.jsonText
        }
    }

    /// Re-encodes JSON text with sorted keys and unescaped slashes, so two
    /// spellings of the same value compare equal.
    static func canonical(_ json: String) -> String {
        struct Box: Decodable { let value: PluginJSONValue }
        guard let box = try? JSONDecoder().decode(
            Box.self, from: Data("{\"value\":\(json)}".utf8))
        else { return json }
        return box.value.jsonText
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
