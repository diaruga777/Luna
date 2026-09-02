//
//  PluginStorageRuntimeTests.swift
//  LunaTests
//

import LunaPluginKit
import LunaPluginRuntime
import XCTest

/// `luna.storage` semantics: what a plugin gets back, and that one plugin never
/// sees another's rows.
final class PluginStorageRuntimeTests: XCTestCase {

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

    private func plugin(id: String = "app.luna.store", body: String) -> String {
        """
        /* luna-plugin
        { "id": "\(id)", "name": "Store", "version": "1.0.0", "api": 1,
          "capabilities": ["storage"] }
        */
        luna.register({ async onAction() { \(body) } });
        """
    }

    private struct Answer: Decodable { let value: PluginJSONValue }

    private func answer(
        _ body: String, pluginID: String = "app.luna.store",
        file: StaticString = #filePath, line: UInt = #line
    ) async -> String? {
        do { try runner.load(plugin(id: pluginID, body: body), file: file, line: line) }
        catch { return nil }
        guard let answer = await runner.invoke(
            .onAction, pluginID: pluginID, as: Answer.self, file: file, line: line)
        else { return nil }
        return answer.value.jsonText
    }

    // MARK: - Key/value

    func testAValueComesBackAsTheShapeItWasStoredAs() async {
        let json = await answer("""
            await luna.storage.set("profile", { name: "a", tags: [1, 2] });
            return { value: await luna.storage.get("profile") };
        """)
        XCTAssertEqual(json, "{\"name\":\"a\",\"tags\":[1,2]}")
    }

    func testAKeyThatWasNeverSetAnswersNothing() async {
        let json = await answer("return { value: await luna.storage.get(\"missing\") };")
        XCTAssertEqual(json, "null")
    }

    func testSettingTheSameKeyTwiceKeepsOnlyTheSecondValue() async {
        let json = await answer("""
            await luna.storage.set("k", 1);
            await luna.storage.set("k", 2);
            return { value: await luna.storage.get("k") };
        """)
        XCTAssertEqual(json, "2")
    }

    func testDeletingAKeyLeavesNothingBehind() async {
        let json = await answer("""
            await luna.storage.set("k", "v");
            await luna.storage.delete("k");
            return { value: [await luna.storage.get("k"), await luna.storage.keys()] };
        """)
        XCTAssertEqual(json, "[null,[]]")
    }

    func testKeysAnswersInKeyOrderAndCanBeNarrowedByPrefix() async {
        let json = await answer("""
            await luna.storage.set("b", 1);
            await luna.storage.set("a", 1);
            await luna.storage.set("settings.x", 1);
            return { value: [await luna.storage.keys(), await luna.storage.keys("settings.")] };
        """)
        XCTAssertEqual(json, "[[\"a\",\"b\",\"settings.x\"],[\"settings.x\"]]")
    }

    func testAValueOverTheCapIsRefusedRatherThanTruncated() async {
        let json = await answer("""
            const big = "x".repeat(300 * 1024);
            try {
                await luna.storage.set("big", big);
                return { value: "stored" };
            } catch (error) {
                return { value: [error.code, await luna.storage.get("big")] };
            }
        """)
        XCTAssertEqual(json, "[\"too-large\",null]")
    }

    func testOnePluginNeverSeesAnotherSKeys() {
        runner.kv.setValueJSON("1", pluginID: "app.luna.a", key: "shared", now: Date())
        runner.kv.setValueJSON("2", pluginID: "app.luna.b", key: "shared", now: Date())

        XCTAssertEqual(runner.kv.valueJSON(pluginID: "app.luna.a", key: "shared"), "1")
        XCTAssertEqual(runner.kv.valueJSON(pluginID: "app.luna.b", key: "shared"), "2")
        XCTAssertEqual(runner.kv.keys(pluginID: "app.luna.a"), ["shared"])
    }

    func testDeletingAPluginTakesItsRowsWithIt() {
        runner.kv.setValueJSON("1", pluginID: "app.luna.a", key: "k", now: Date())
        runner.kv.putDocument(
            PluginCollectionDocument(id: "d", json: "{}"), collection: "c",
            pluginID: "app.luna.a", now: Date())

        runner.kv.removeAll(pluginID: "app.luna.a")

        XCTAssertEqual(runner.kv.keys(pluginID: "app.luna.a"), [])
        XCTAssertEqual(runner.kv.count(collection: "c", pluginID: "app.luna.a"), 0)
    }

    func testAPrefixHoldingALikeWildcardMatchesItselfRatherThanEverything() {
        runner.kv.setValueJSON("1", pluginID: "p", key: "a_b", now: Date())
        runner.kv.setValueJSON("1", pluginID: "p", key: "axb", now: Date())

        XCTAssertEqual(runner.kv.keys(pluginID: "p", prefix: "a_"), ["a_b"])
    }

    // MARK: - Collections

    func testACollectionDocumentComesBackByItsId() async {
        let json = await answer("""
            const notes = luna.storage.collection("notes");
            await notes.put("n1", { text: "hello" });
            return { value: await notes.get("n1") };
        """)
        XCTAssertEqual(json, "{\"text\":\"hello\"}")
    }

    func testPuttingTheSameIdTwiceReplacesTheDocument() async {
        let json = await answer("""
            const notes = luna.storage.collection("notes");
            await notes.put("n1", { v: 1 });
            await notes.put("n1", { v: 2 });
            return { value: [await notes.get("n1"), await notes.count()] };
        """)
        XCTAssertEqual(json, "[{\"v\":2},1]")
    }

    func testFindMatchesOnTheIndexFieldsAndCountAgrees() async {
        let json = await answer("""
            const notes = luna.storage.collection("notes");
            await notes.put("a", { v: 1 }, { k1: "red", k2: "big" });
            await notes.put("b", { v: 2 }, { k1: "red", k2: "small" });
            await notes.put("c", { v: 3 }, { k1: "blue" });
            const red = await notes.find({ k1: "red" });
            return { value: [red.length, await notes.count({ k1: "red" }),
                             await notes.count({ k1: "red", k2: "small" }),
                             await notes.count()] };
        """)
        XCTAssertEqual(json, "[2,2,1,3]")
    }

    func testFindHonoursLimitAndOffset() async {
        let json = await answer("""
            const notes = luna.storage.collection("notes");
            for (const id of ["a", "b", "c"]) { await notes.put(id, { id: id }, { k1: "x" }); }
            const page = await notes.find({ k1: "x" }, { limit: 2 });
            const rest = await notes.find({ k1: "x" }, { limit: 2, offset: 2 });
            return { value: [page.length, rest.length] };
        """)
        XCTAssertEqual(json, "[2,1]")
    }

    func testFindAnswersIdAndDocumentPairs() async {
        let json = await answer("""
            const notes = luna.storage.collection("notes");
            await notes.put("only", { v: 7 }, { k1: "x" });
            const rows = await notes.find({ k1: "x" });
            return { value: [rows[0].id, rows[0].doc.v] };
        """)
        XCTAssertEqual(json, "[\"only\",7]")
    }

    func testDeletingADocumentLeavesTheCollectionEmpty() async {
        let json = await answer("""
            const notes = luna.storage.collection("notes");
            await notes.put("n1", { v: 1 });
            await notes.delete("n1");
            return { value: [await notes.get("n1"), await notes.count()] };
        """)
        XCTAssertEqual(json, "[null,0]")
    }

    func testTwoCollectionsOfOnePluginDoNotSeeEachOther() async {
        let json = await answer("""
            const a = luna.storage.collection("a");
            const b = luna.storage.collection("b");
            await a.put("x", { in: "a" });
            await b.put("x", { in: "b" });
            return { value: [(await a.get("x")).in, (await b.get("x")).in] };
        """)
        XCTAssertEqual(json, "[\"a\",\"b\"]")
    }

    // MARK: - Settings on the same table

    func testARequiredSettingDecidesWhetherThePluginIsConfigured() {
        let fields = [
            PluginSettingField(key: "address", type: .email, label: "Address", isRequired: true),
            PluginSettingField(key: "note", type: .toggle, label: "Note"),
        ]
        XCTAssertFalse(runner.kv.isConfigured(pluginID: "p", fields: fields))

        runner.kv.setValueJSON(
            "\"a@b.test\"", pluginID: "p",
            key: "address", now: Date())

        XCTAssertTrue(runner.kv.isConfigured(pluginID: "p", fields: fields))
    }

    func testAnEmptyRequiredSettingIsNotConfigured() {
        let fields = [
            PluginSettingField(key: "address", type: .email, label: "Address", isRequired: true),
        ]
        runner.kv.setValueJSON(
            "\"\"", pluginID: "p", key: "address", now: Date())

        XCTAssertFalse(runner.kv.isConfigured(pluginID: "p", fields: fields))
    }
}
