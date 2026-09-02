//
//  PluginFetchShapingParityTests.swift
//  LunaTests
//

import LunaModels
import LunaPluginKit
import LunaPluginRuntime
import LunaURLClassification
import XCTest

/// One request object, two entry points into `PluginFetchRequestShaping`, one
/// `PluginFetchRequest`.
///
/// The JavaScriptCore bridge reaches the shaper through `luna.fetch` in the app
/// and the share/action extensions; `SafariPluginMessages+Luna.pluginFetch`
/// reaches it with the native message's own dictionary. The Safari half used to
/// build the request by hand and dropped `userAgent`, `form`, `json` and
/// `multipart` — every shipped media resolver behaved differently in the one
/// process whose point is running the same plugin. This pins the two answers to
/// each other; `SafariPluginHandlerSourceTests` pins the appex to the shaper.
final class PluginFetchShapingParityTests: XCTestCase {

    private var runner: PluginJSFixtureRunner!

    override func setUp() {
        super.setUp()
        PluginStubURLProtocol.reset()
        LiveNetworkPolicy.overrideForTesting = true
        runner = PluginJSFixtureRunner()
    }

    override func tearDown() {
        LiveNetworkPolicy.overrideForTesting = nil
        PluginStubURLProtocol.reset()
        runner.cleanUp()
        runner = nil
        super.tearDown()
    }

    /// The request the shipped bridge built from a plugin's own object.
    private func throughTheBridge(
        _ requestSource: String, file: StaticString = #filePath, line: UInt = #line
    ) async -> PluginFetchRequest? {
        runner.fetcher.respond(to: "https://example.com/a", body: "ok")
        let source = """
        /* luna-plugin
        { "id": "app.luna.shape", "name": "Shape", "version": "1.0.0", "api": 1,
          "capabilities": ["fetch"] }
        */
        luna.register({
            async onAction() {
                const response = await luna.fetch(\(requestSource));
                return { status: response.status };
            }
        });
        """
        do { try runner.load(source, file: file, line: line) } catch { return nil }
        struct Answer: Decodable { let status: Int }
        _ = await runner.runtime.invoke(
            .onAction, pluginID: "app.luna.shape", argument: PluginEmptyArgument(),
            timeout: 5, decode: Answer.self)
        return runner.fetcher.requests.first
    }

    /// The request the appex's entry point builds from the same object as a
    /// native-message dictionary. `pluginID`/`scratchGeneration` are taken off
    /// the bridge's own answer, since those two name the caller rather than the
    /// request the plugin wrote.
    private func throughTheDictionary(
        _ object: [String: Any], like bridged: PluginFetchRequest
    ) -> PluginFetchRequest? {
        switch PluginFetchRequestShaping.request(
            from: object, pluginID: bridged.pluginID,
            scratchGeneration: bridged.invocationID, files: nil)
        {
        case .success(let request): return request
        case .failure(let error):
            XCTFail("the dictionary path refused the request: \(error.code) \(error.message)")
            return nil
        }
    }

    func testACrawlerIdentityStructuredBodyAndReservedHeadersShapeIdentically() async {
        let source = """
            { url: "https://example.com/a", method: "POST", userAgent: "googlebot",
              headers: { Host: "evil.test", Referer: "https://ok.test/" },
              body: { json: { a: 1 } }, cookies: "ephemeral", redirect: "manual",
              timeout: 5, maxBytes: 1024 }
            """
        guard let bridged = await throughTheBridge(source) else {
            return XCTFail("the bridge sent no request")
        }
        let object: [String: Any] = [
            "url": "https://example.com/a", "method": "POST", "userAgent": "googlebot",
            "headers": ["Host": "evil.test", "Referer": "https://ok.test/"],
            "body": ["json": ["a": 1]], "cookies": "ephemeral", "redirect": "manual",
            "timeout": 5, "maxBytes": 1024,
        ]
        XCTAssertEqual(throughTheDictionary(object, like: bridged), bridged)
        XCTAssertEqual(bridged.headers["User-Agent"], PluginCrawlerIdentity.googlebot.userAgent)
        XCTAssertNil(bridged.headers["Host"], "a reserved header is stripped on both paths")
    }

    func testAFormBodyShapesIdentically() async {
        guard let bridged = await throughTheBridge(
            "{ url: \"https://example.com/a\", method: \"POST\", body: { form: { b: \"2 3\", a: \"1\" } } }")
        else { return XCTFail("the bridge sent no request") }
        let object: [String: Any] = [
            "url": "https://example.com/a", "method": "POST",
            "body": ["form": ["b": "2 3", "a": "1"]],
        ]
        XCTAssertEqual(throughTheDictionary(object, like: bridged), bridged)
        XCTAssertEqual(bridged.body.map { String(decoding: $0, as: UTF8.self) }, "a=1&b=2%203")
    }

    /// A multipart boundary is a fresh UUID per request, so the two paths agree
    /// on everything but that one string.
    func testAMultipartBodyShapesIdenticallyApartFromItsBoundary() async {
        guard let bridged = await throughTheBridge("""
            { url: "https://example.com/a", method: "POST", body: { multipart: [
                { name: "file", filename: "a.txt", mime: "text/plain", text: "hi" }
            ] } }
            """)
        else { return XCTFail("the bridge sent no request") }
        let object: [String: Any] = [
            "url": "https://example.com/a", "method": "POST",
            "body": ["multipart": [[
                "name": "file", "filename": "a.txt", "mime": "text/plain", "text": "hi",
            ]]],
        ]
        guard let direct = throughTheDictionary(object, like: bridged) else { return }
        XCTAssertEqual(
            Self.withoutBoundary(direct.body, contentType: direct.headers["Content-Type"]),
            Self.withoutBoundary(bridged.body, contentType: bridged.headers["Content-Type"]))
    }

    /// A `file` part cannot be served where no `luna.files` runs — Safari — so
    /// the whole fetch is refused rather than posted with an empty part.
    func testAFilePartWithoutTheFilesCapabilityIsRefused() {
        let object: [String: Any] = [
            "url": "https://example.com/a", "method": "POST",
            "body": ["multipart": [["name": "file", "file": ["id": "abc"]]]],
        ]
        switch PluginFetchRequestShaping.request(
            from: object, pluginID: "p", scratchGeneration: "g", files: nil)
        {
        case .success: XCTFail("a file part with no files bridge must not be sent")
        case .failure(let error): XCTAssertEqual(error.code, "unavailable-here")
        }
    }

    func testAnUnknownCookieRedirectOrResponseFormIsABadArgument() {
        for (key, value) in [("cookies", "browser"), ("redirect", "sideways"), ("as", "stream")] {
            let object: [String: Any] = ["url": "https://example.com/a", key: value]
            switch PluginFetchRequestShaping.request(
                from: object, pluginID: "p", scratchGeneration: "g", files: nil)
            {
            case .success: XCTFail("\(key): \(value) must not be accepted")
            case .failure(let error): XCTAssertEqual(error.code, "bad-argument", key)
            }
        }
    }

    private static func withoutBoundary(_ body: Data?, contentType: String?) -> String? {
        guard let body, let contentType,
              let range = contentType.range(of: "boundary=")
        else { return nil }
        let boundary = String(contentType[range.upperBound...])
        return String(decoding: body, as: UTF8.self)
            .replacingOccurrences(of: boundary, with: "<boundary>")
    }
}
