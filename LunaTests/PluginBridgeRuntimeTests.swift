//
//  PluginBridgeRuntimeTests.swift
//  LunaTests
//

import LunaAppConfig
import LunaPluginKit
import LunaPluginRuntime
import LunaStorage
import XCTest

/// The always-present members and the smaller bridges: `parseURL`, `bytes`,
/// `crypto`, `files` and `secrets`.
final class PluginBridgeRuntimeTests: XCTestCase {

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

    private func plugin(
        id: String = "app.luna.bridge", capabilities: [String] = [], body: String
    ) -> String {
        let caps = capabilities.isEmpty
            ? ""
            : ",\n  \"capabilities\": [\(capabilities.map { "\"\($0)\"" }.joined(separator: ", "))]"
        return """
        /* luna-plugin
        { "id": "\(id)", "name": "Bridge", "version": "1.0.0", "api": 1\(caps) }
        */
        luna.register({ async onAction() { \(body) } });
        """
    }

    private struct Answer: Decodable { let value: PluginJSONValue }

    private func answer(
        _ body: String, capabilities: [String] = [], id: String = "app.luna.bridge",
        processKind: PluginProcessKind = .app,
        file: StaticString = #filePath, line: UInt = #line
    ) async -> String? {
        let host = processKind == .app ? runner! : PluginJSFixtureRunner(processKind: processKind)
        defer { if host !== runner { host.cleanUp() } }
        do {
            try host.load(
                plugin(id: id, capabilities: capabilities, body: body), file: file, line: line)
        } catch { return nil }
        guard let answer = await host.invoke(
            .onAction, pluginID: id, as: Answer.self, file: file, line: line)
        else { return nil }
        return answer.value.jsonText
    }

    // MARK: - parseURL

    func testParseURLGivesTheBrowserFieldsAPluginAuthorExpects() async {
        let json = await answer("""
            const u = luna.parseURL("https://User.Example.com:8443/a/b%20c?x=1&y=a+b#frag");
            return { value: [u.protocol, u.host, u.hostname, u.port, u.pathname,
                             u.search, u.hash] };
        """)
        XCTAssertEqual(
            json,
            "[\"https:\",\"user.example.com:8443\",\"user.example.com\",\"8443\","
                + "\"/a/b%20c\",\"?x=1&y=a+b\",\"#frag\"]")
    }

    func testParseURLResolvesAgainstABase() async {
        let json = await answer("""
            return { value: luna.parseURL("../up/x", "https://example.com/a/b/c").href };
        """)
        XCTAssertEqual(json, "\"https://example.com/a/up/x\"")
    }

    func testParseURLAnswersNullForSomethingThatIsNotAURL() async {
        let json = await answer("return { value: luna.parseURL(\"not a url\") };")
        XCTAssertEqual(json, "null")
    }

    func testSearchParamsDecodesPlusAsASpaceAndKeepsDuplicates() async {
        let json = await answer("""
            const u = luna.parseURL("https://example.com/?tag=a+b&tag=c&only=1");
            return { value: [u.searchParams.get("tag"), u.searchParams.getAll("tag"),
                             u.searchParams.has("only"), u.searchParams.has("nope"),
                             u.searchParams.entries()] };
        """)
        XCTAssertEqual(
            json,
            "[\"a b\",[\"a b\",\"c\"],true,false,[[\"tag\",\"a b\"],[\"tag\",\"c\"],"
                + "[\"only\",\"1\"]]]")
    }

    func testAPathWithNoQueryAnswersEmptySearchAndHash() async {
        let json = await answer("""
            const u = luna.parseURL("https://example.com");
            return { value: [u.pathname, u.search, u.hash, u.port] };
        """)
        XCTAssertEqual(json, "[\"/\",\"\",\"\",\"\"]")
    }

    // MARK: - bytes

    func testBytesRoundTripsUTF8ThroughBase64() async {
        let json = await answer("""
            const bytes = luna.bytes.utf8Encode("héllo 🌙");
            const text = luna.bytes.utf8Decode(luna.bytes.fromBase64(luna.bytes.toBase64(bytes)));
            return { value: [text, bytes instanceof Uint8Array, bytes.length] };
        """)
        XCTAssertEqual(json, "[\"héllo 🌙\",true,11]")
    }

    func testBase64MatchesWhatSwiftProduces() async {
        let expected = Data("Luna".utf8).base64EncodedString()
        let json = await answer("""
            return { value: luna.bytes.toBase64(luna.bytes.utf8Encode("Luna")) };
        """)
        XCTAssertEqual(json, "\"\(expected)\"")
    }

    // MARK: - env and LunaError

    func testEnvNamesTheProcessAndThePlugin() async {
        let json = await answer("""
            return { value: [luna.env.context, luna.env.api, luna.env.pluginId,
                             luna.env.version] };
        """)
        XCTAssertEqual(json, "[\"app\",1,\"app.luna.bridge\",\"1.0.0\"]")
    }

    func testEnvReportsTheExtensionItIsRunningIn() async {
        let json = await answer(
            "return { value: luna.env.context };", processKind: .share)
        XCTAssertEqual(json, "\"share\"")
    }

    func testLunaErrorIsARealErrorWithACode() async {
        let json = await answer("""
            const error = new luna.LunaError("nope", "not today");
            return { value: [error instanceof Error, error instanceof luna.LunaError,
                             error.code, error.message, error.name] };
        """)
        XCTAssertEqual(json, "[true,true,\"nope\",\"not today\",\"LunaError\"]")
    }

    func testTheLunaObjectIsFrozenSoAPluginCannotSwapABridge() async {
        let json = await answer("""
            try { luna.parseURL = function () { return "hijacked"; }; } catch (error) { }
            return { value: typeof luna.parseURL("https://a.test/") };
        """)
        XCTAssertEqual(json, "\"object\"")
    }

    // MARK: - crypto

    func testSHA256MatchesCryptoKit() async {
        let json = await answer("""
            return { value: await luna.crypto.sha256("Luna") };
        """, capabilities: ["crypto"])
        // The digest of "Luna", base64, as CryptoKit answers it.
        XCTAssertEqual(json, "\"nXeiTQ9MkaLpaMpgfkndOxXVSJ9mpbyB+nKAOzJENBk=\"")
    }

    func testHMACIsKeyedAndStableAcrossTheBridge() async {
        let json = await answer("""
            const a = await luna.crypto.hmacSHA256("secret", "message");
            const b = await luna.crypto.hmacSHA256("secret", "message");
            const c = await luna.crypto.hmacSHA256("other", "message");
            return { value: [a === b, a === c] };
        """, capabilities: ["crypto"])
        XCTAssertEqual(json, "[true,false]")
    }

    func testRandomBytesAnswersTheRequestedCountAndRefusesAnAbsurdOne() async {
        let json = await answer("""
            const bytes = luna.bytes.fromBase64(await luna.crypto.randomBytes(16));
            let refused = null;
            try { await luna.crypto.randomBytes(0); } catch (error) { refused = error.code; }
            return { value: [bytes.length, refused] };
        """, capabilities: ["crypto"])
        XCTAssertEqual(json, "[16,\"bad-argument\"]")
    }

    // MARK: - files

    func testAWrittenFileReadsBackAsTextAndAsBase64() async {
        let json = await answer("""
            const handle = await luna.files.write("note.txt", "hello", "text/plain");
            const text = await luna.files.read(handle, "text");
            const base64 = await luna.files.read(handle, "base64");
            return { value: [handle.name, handle.size, handle.mime, text,
                             luna.bytes.utf8Decode(luna.bytes.fromBase64(base64))] };
        """, capabilities: ["files"])
        XCTAssertEqual(json, "[\"note.txt\",5,\"text/plain\",\"hello\",\"hello\"]")
    }

    func testAFileNameCannotEscapeItsDirectory() async {
        let json = await answer("""
            const handle = await luna.files.write("../../escape.txt", "x");
            return { value: [handle.name.indexOf("/"), handle.name.indexOf("..")] };
        """, capabilities: ["files"])
        XCTAssertEqual(json, "[-1,-1]")
    }

    func testAScratchDirectoryIsReapedUnlessItWasRetained() throws {
        let scratch = PluginScratchStore(
            pluginID: "p", rootURL: runner.containerURL.appendingPathComponent("scratch2"))
        let kept = try scratch.writeFile(
            Data("a".utf8), suggestedName: "a.txt", mime: nil, invocationID: "keep")
        let dropped = try scratch.writeFile(
            Data("b".utf8), suggestedName: "b.txt", mime: nil, invocationID: "drop")

        scratch.retain(invocationID: "keep")
        XCTAssertEqual(scratch.reap(invocationID: "keep"), .retained)
        XCTAssertEqual(scratch.reap(invocationID: "drop"), .reaped)

        XCTAssertNotNil(scratch.fileURL(for: kept))
        XCTAssertNil(scratch.fileURL(for: dropped))
    }

    // MARK: - secrets

    func testASecretRoundTripsThroughTheKeychain() async throws {
        let pluginID = "app.luna.secrets.\(UUID().uuidString.lowercased().prefix(8))"
        let store = PluginSecretsStore()
        store.setSecret("probe", pluginID: pluginID, key: "probe")
        try XCTSkipIf(
            store.secret(pluginID: pluginID, key: "probe") != "probe",
            "the test host cannot reach the keychain")
        store.removeSecret(pluginID: pluginID, key: "probe")
        defer { store.removeSecret(pluginID: pluginID, key: "token") }

        let json = await answer("""
            await luna.secrets.set("token", "abc123");
            const read = await luna.secrets.get("token");
            await luna.secrets.delete("token");
            return { value: [read, await luna.secrets.get("token")] };
        """, capabilities: ["secrets"], id: pluginID)

        XCTAssertEqual(json, "[\"abc123\",null]")
    }

    func testAnExtensionMayReadASecretButNotWriteOne() async throws {
        let pluginID = "app.luna.secrets.\(UUID().uuidString.lowercased().prefix(8))"
        let store = PluginSecretsStore()
        store.setSecret("from-the-app", pluginID: pluginID, key: "token")
        try XCTSkipIf(
            store.secret(pluginID: pluginID, key: "token") != "from-the-app",
            "the test host cannot reach the keychain")
        defer { store.removeSecret(pluginID: pluginID, key: "token") }

        let json = await answer("""
            const read = await luna.secrets.get("token");
            let refused = null;
            try { await luna.secrets.set("token", "x"); }
            catch (error) { refused = error.code; }
            return { value: [read, refused] };
        """, capabilities: ["secrets"], id: pluginID, processKind: .share)

        XCTAssertEqual(json, "[\"from-the-app\",\"unavailable-here\"]")
        XCTAssertEqual(store.secret(pluginID: pluginID, key: "token"), "from-the-app")
    }

    func testASecretUsesTheSharedAppGroupAccessGroup() {
        XCTAssertEqual(CredentialKeychain.sharedAccessGroup, AppConfig.appGroupID)
        XCTAssertTrue(
            PluginSecretsStore.service(pluginID: "a.b").hasSuffix("a.b"),
            "the service names the plugin, so deleting one plugin's secrets is one prefix")
    }
}
