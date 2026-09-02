//
//  PluginConcurrencyTests.swift
//  LunaTests
//

import LunaPluginKit
import LunaPluginRuntime
import XCTest

/// What happens when two plugin calls overlap.
///
/// Every other plugin suite drives one call at a time, awaited to completion —
/// and the bookkeeping the runtime keeps per call is exactly what a serial test
/// cannot show. Hooks overlap in the product: `onBluetooth` runs an `export`
/// inside itself, and `SavesIngestor` spawns one save walk per pending row.
final class PluginConcurrencyTests: XCTestCase {

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

    private func plugin(id: String, capabilities: [String] = [], body: String) -> String {
        let caps = capabilities.isEmpty
            ? ""
            : ",\n  \"capabilities\": [\(capabilities.map { "\"\($0)\"" }.joined(separator: ", "))]"
        return """
        /* luna-plugin
        { "id": "\(id)", "name": "Concurrent", "version": "1.0.0", "api": 1\(caps) }
        */
        luna.register({ async onAction(input) { \(body) } });
        """
    }

    private struct Answer: Decodable { let value: PluginJSONValue }

    /// Two plugins asked at the same time each get their own answer back. One
    /// runtime slot for the pending call used to let the second erase the
    /// first's bookkeeping.
    func testTwoPluginsCalledAtOnceEachGetTheirOwnAnswer() async throws {
        runner.fetcher.delays = [
            "https://example.com/a": 0.15, "https://example.com/b": 0.05,
        ]
        runner.fetcher.respond(to: "https://example.com/a", body: "alpha")
        runner.fetcher.respond(to: "https://example.com/b", body: "beta")
        try runner.load(
            plugin(id: "app.luna.first", capabilities: ["fetch"], body: """
                const response = await luna.fetch("https://example.com/a");
                return { value: response.text };
            """),
            plugin(id: "app.luna.second", capabilities: ["fetch"], body: """
                const response = await luna.fetch("https://example.com/b");
                return { value: response.text };
            """))

        async let first = runner.runtime.invoke(
            .onAction, pluginID: "app.luna.first", argument: PluginEmptyArgument(),
            timeout: 5, decode: Answer.self)
        async let second = runner.runtime.invoke(
            .onAction, pluginID: "app.luna.second", argument: PluginEmptyArgument(),
            timeout: 5, decode: Answer.self)
        let outcomes = await [first, second]

        XCTAssertEqual(try outcomes[0].get().value.jsonText, "\"alpha\"")
        XCTAssertEqual(try outcomes[1].get().value.jsonText, "\"beta\"")
        XCTAssertFalse(runner.runtime.isWedged)
    }

    /// One hook's two fetches run at once and each promise settles with its own
    /// response.
    func testPromiseAllOverTwoFetchesSettlesEachWithItsOwnBody() async throws {
        runner.fetcher.delays = [
            "https://example.com/a": 0.12, "https://example.com/b": 0.02,
        ]
        runner.fetcher.respond(to: "https://example.com/a", body: "alpha")
        runner.fetcher.respond(to: "https://example.com/b", body: "beta")
        try runner.load(plugin(id: "app.luna.pair", capabilities: ["fetch"], body: """
            const both = await Promise.all([
                luna.fetch({ url: "https://example.com/a", cookies: "shared" }),
                luna.fetch({ url: "https://example.com/b", cookies: "none" })]);
            return { value: both.map(function (r) { return r.text; }) };
        """))

        let answer = await runner.invoke(
            .onAction, pluginID: "app.luna.pair", as: Answer.self)

        XCTAssertEqual(answer?.value.jsonText, "[\"alpha\",\"beta\"]")
    }

    /// Two calls of one plugin write into the SAME generation, so the first
    /// call's file is still readable while the second is running and both go
    /// when the last one ends.
    func testFilesOfTwoOverlappingCallsShareOneGenerationAndGoTogether() async throws {
        runner.fetcher.delays = ["https://example.com/hold": 0.3]
        runner.fetcher.respond(to: "https://example.com/hold", body: "ok")
        try runner.load(plugin(
            id: "app.luna.files", capabilities: ["fetch", "files"], body: """
                const handle = await luna.files.write("note.txt", "hello");
                if (input && input.hold) { await luna.fetch("https://example.com/hold"); }
                return { value: handle };
            """))

        async let holder = runner.runtime.invoke(
            .onAction, pluginID: "app.luna.files", argument: HoldInput(hold: true),
            timeout: 5, decode: Answer.self)
        async let quick = runner.runtime.invoke(
            .onAction, pluginID: "app.luna.files", argument: HoldInput(hold: false),
            timeout: 5, decode: Answer.self)
        let outcomes = await [holder, quick]

        let descriptors = try outcomes.map { try handleID(from: $0.get().value.jsonText) }
        XCTAssertEqual(Set(descriptors).count, 2, "each call wrote its own file")
        for id in descriptors {
            XCTAssertNil(
                runner.scratch.fileURL(
                    for: PluginFileDescriptor(id: id, name: "note.txt", size: 5, mime: nil)),
                "the generation is reaped once nothing holds it")
        }
    }

    private struct HoldInput: Encodable { let hold: Bool }

    private func handleID(from json: String?, line: UInt = #line) throws -> String {
        let object = try JSONSerialization.jsonObject(with: Data((json ?? "").utf8))
        return try XCTUnwrap((object as? [String: Any])?["id"] as? String, line: line)
    }
}
