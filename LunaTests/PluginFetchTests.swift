//
//  PluginFetchTests.swift
//  LunaTests
//

import LunaModels
import LunaPluginKit
import LunaPluginRuntime
import LunaURLClassification
import XCTest

/// What `luna.fetch` sends and what it hands back. The request shapes are
/// asserted through a stub `URLProtocol`, so the assertion is on the bytes
/// `URLSession` would put on the wire.
final class PluginFetchTests: XCTestCase {

    private var runner: PluginJSFixtureRunner!

    override func setUp() {
        super.setUp()
        PluginStubURLProtocol.reset()
        // The service checks `LiveNetworkPolicy` before it builds a request, and
        // this process is a test runner. The stub protocol answers every
        // request, so nothing here reaches a real server.
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

    // MARK: - Request decoding

    /// The decoder is exercised through the bridge, so the assertion is on what
    /// a plugin's own object turns into.
    private func requestFromPlugin(
        _ requestSource: String, file: StaticString = #filePath, line: UInt = #line
    ) async -> PluginFetchRequest? {
        runner.fetcher.respond(to: "https://example.com/a", body: "ok")
        runner.fetcher.respond(to: "https://example.com/b", body: "ok")
        let source = """
        /* luna-plugin
        { "id": "app.luna.fetch", "name": "Fetch", "version": "1.0.0", "api": 1,
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
            .onAction, pluginID: "app.luna.fetch", argument: PluginEmptyArgument(),
            timeout: 5, decode: Answer.self)
        return runner.fetcher.requests.first
    }

    func testAStringArgumentIsTheSameCallWithOneField() async {
        let request = await requestFromPlugin("\"https://example.com/a\"")
        XCTAssertEqual(request?.url.absoluteString, "https://example.com/a")
        XCTAssertEqual(request?.method, "GET")
    }

    func testANamedCrawlerIdentityBecomesItsUserAgentAndForwardedFor() async {
        let request = await requestFromPlugin(
            "{ url: \"https://example.com/a\", userAgent: \"googlebot\" }")
        XCTAssertEqual(request?.headers["User-Agent"], PluginCrawlerIdentity.googlebot.userAgent)
        XCTAssertEqual(request?.headers["X-Forwarded-For"], "66.249.66.1")
    }

    func testANonGoogleIdentitySendsNoForwardedForHeader() async {
        let request = await requestFromPlugin(
            "{ url: \"https://example.com/a\", userAgent: \"bingbot\" }")
        XCTAssertEqual(request?.headers["User-Agent"], PluginCrawlerIdentity.bingbot.userAgent)
        XCTAssertNil(request?.headers["X-Forwarded-For"])
    }

    func testAnUnnamedUserAgentIsSentVerbatim() async {
        let request = await requestFromPlugin(
            "{ url: \"https://example.com/a\", userAgent: \"MyPlugin/1.0\" }")
        XCTAssertEqual(request?.headers["User-Agent"], "MyPlugin/1.0")
    }

    func testHostAndContentLengthCannotBeSetByAPlugin() async {
        let request = await requestFromPlugin(
            "{ url: \"https://example.com/a\", headers: { Host: \"evil.test\", "
                + "\"Content-Length\": \"0\", Referer: \"https://ok.test/\" } }")
        XCTAssertNil(request?.headers["Host"])
        XCTAssertNil(request?.headers["Content-Length"])
        XCTAssertEqual(request?.headers["Referer"], "https://ok.test/")
    }

    func testAFormBodyIsEncodedAndTyped() async {
        let request = await requestFromPlugin(
            "{ url: \"https://example.com/a\", method: \"POST\", "
                + "body: { form: { b: \"2 3\", a: \"1\" } } }")
        XCTAssertEqual(request?.headers["Content-Type"], "application/x-www-form-urlencoded")
        XCTAssertEqual(request?.body.map { String(decoding: $0, as: UTF8.self) }, "a=1&b=2%203")
    }

    func testAJSONBodyIsEncodedAndTyped() async {
        let request = await requestFromPlugin(
            "{ url: \"https://example.com/a\", method: \"POST\", body: { json: { a: 1 } } }")
        XCTAssertEqual(request?.headers["Content-Type"], "application/json")
        XCTAssertEqual(request?.body.map { String(decoding: $0, as: UTF8.self) }, "{\"a\":1}")
    }

    func testAMultipartBodyCarriesItsBoundaryInTheHeaderAndTheBytes() async {
        let request = await requestFromPlugin(
            "{ url: \"https://example.com/a\", method: \"POST\", body: { multipart: ["
                + "{ name: \"file\", filename: \"a.txt\", mime: \"text/plain\", text: \"hi\" }"
                + "] } }")
        guard let contentType = request?.headers["Content-Type"],
              let body = request?.body.map({ String(decoding: $0, as: UTF8.self) })
        else { return XCTFail("no multipart request") }
        XCTAssertTrue(contentType.hasPrefix("multipart/form-data; boundary=luna-"))
        let boundary = String(contentType.dropFirst("multipart/form-data; boundary=".count))
        XCTAssertTrue(body.hasPrefix("--\(boundary)\r\n"))
        XCTAssertTrue(body.contains("Content-Disposition: form-data; name=\"file\"; "
            + "filename=\"a.txt\""))
        XCTAssertTrue(body.contains("Content-Type: text/plain"))
        XCTAssertTrue(body.hasSuffix("--\(boundary)--\r\n"))
    }

    func testABase64BodyIsDecodedToItsBytes() async {
        let request = await requestFromPlugin(
            "{ url: \"https://example.com/a\", method: \"PUT\", "
                + "body: { base64: luna.bytes.toBase64(luna.bytes.utf8Encode(\"hé\")) } }")
        XCTAssertEqual(request?.body, Data("hé".utf8))
    }

    func testTheCookieAndRedirectPoliciesReachTheService() async {
        let request = await requestFromPlugin(
            "{ url: \"https://example.com/a\", cookies: \"ephemeral\", redirect: \"manual\" }")
        XCTAssertEqual(request?.cookies, .ephemeral)
        XCTAssertEqual(request?.redirect, .manual)
    }

    func testMaxBytesIsClampedToTheArticlePathSCeiling() async {
        let request = await requestFromPlugin(
            "{ url: \"https://example.com/a\", maxBytes: 99999999999 }")
        XCTAssertEqual(request?.maxBytes, WebFetchConstants.maxBytes)
    }

    // MARK: - The response a plugin sees

    func testAResponseCarriesStatusFinalURLHeadersAndText() async throws {
        runner.fetcher.responses["https://example.com/a"] = PluginFetchResponse(
            status: 201, finalURL: "https://example.com/b", headers: ["Content-Type": "text/html"],
            body: Data("<p>hi</p>".utf8), truncated: true, redirected: true)
        let source = """
        /* luna-plugin
        { "id": "app.luna.fetch", "name": "Fetch", "version": "1.0.0", "api": 1,
          "capabilities": ["fetch"] }
        */
        luna.register({
            async onAction() {
                const r = await luna.fetch("https://example.com/a");
                return { ok: r.ok, status: r.status, url: r.url, text: r.text,
                         type: r.headers["Content-Type"], truncated: r.truncated,
                         redirected: r.redirected, bytes: r.bytes };
            }
        });
        """
        try runner.load(source)

        struct Answer: Decodable {
            let ok: Bool
            let status: Int
            let url: String
            let text: String
            let type: String
            let truncated: Bool
            let redirected: Bool
            let bytes: Int
        }
        let answer = await runner.invoke(
            .onAction, pluginID: "app.luna.fetch", as: Answer.self)

        XCTAssertEqual(answer?.ok, true)
        XCTAssertEqual(answer?.status, 201)
        XCTAssertEqual(answer?.url, "https://example.com/b")
        XCTAssertEqual(answer?.text, "<p>hi</p>")
        XCTAssertEqual(answer?.type, "text/html")
        XCTAssertEqual(answer?.truncated, true)
        XCTAssertEqual(answer?.redirected, true)
        XCTAssertEqual(answer?.bytes, 9)
    }

    func testAsBase64AnswersTheBodyEncodedRatherThanAsText() async throws {
        runner.fetcher.responses["https://example.com/a"] = PluginFetchResponse(
            status: 200, finalURL: "https://example.com/a", headers: [:],
            body: Data([0x00, 0x01, 0xff]), truncated: false, redirected: false)
        let source = """
        /* luna-plugin
        { "id": "app.luna.fetch", "name": "Fetch", "version": "1.0.0", "api": 1,
          "capabilities": ["fetch"] }
        */
        luna.register({
            async onAction() {
                const r = await luna.fetch({ url: "https://example.com/a", as: "base64" });
                return { base64: r.base64, hasText: r.text !== undefined };
            }
        });
        """
        try runner.load(source)

        struct Answer: Decodable { let base64: String; let hasText: Bool }
        let answer = await runner.invoke(.onAction, pluginID: "app.luna.fetch", as: Answer.self)

        XCTAssertEqual(answer?.base64, Data([0x00, 0x01, 0xff]).base64EncodedString())
        XCTAssertEqual(answer?.hasText, false)
    }

    func testAFailedFetchRejectsWithACodeThePluginCanBranchOn() async throws {
        runner.fetcher.fallback = .failure(PluginFetchError("offline", code: "network-refused"))
        let source = """
        /* luna-plugin
        { "id": "app.luna.fetch", "name": "Fetch", "version": "1.0.0", "api": 1,
          "capabilities": ["fetch"] }
        */
        luna.register({
            async onAction() {
                try {
                    await luna.fetch("https://example.com/gone");
                    return { code: "no throw" };
                } catch (error) {
                    return { code: error.code, isLunaError: error instanceof luna.LunaError,
                             message: error.message };
                }
            }
        });
        """
        try runner.load(source)

        struct Answer: Decodable { let code: String; let isLunaError: Bool; let message: String }
        let answer = await runner.invoke(.onAction, pluginID: "app.luna.fetch", as: Answer.self)

        XCTAssertEqual(answer?.code, "network-refused")
        XCTAssertEqual(answer?.isLunaError, true)
        XCTAssertEqual(answer?.message, "offline")
    }

    // MARK: - The service on URLSession

    func testTheServiceSendsTheMethodHeadersAndBodyItWasGiven() {
        let service = PluginFetchService(protocolClasses: [PluginStubURLProtocol.self])
        PluginStubURLProtocol.respond(
            to: "https://example.com/post", status: 200, body: "done")
        let expectation = expectation(description: "the request completes")

        service.fetch(PluginFetchRequest(
            url: URL(string: "https://example.com/post")!, method: "POST",
            headers: ["X-Test": "1"], body: Data("payload".utf8), cookies: .none)
        ) { outcome in
            XCTAssertEqual(try? outcome.get().status, 200)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 10)

        let sent = PluginStubURLProtocol.requests.first
        XCTAssertEqual(sent?.httpMethod, "POST")
        XCTAssertEqual(sent?.value(forHTTPHeaderField: "X-Test"), "1")
        XCTAssertEqual(PluginStubURLProtocol.bodies.first, Data("payload".utf8))
    }

    func testTheServiceSendsTheSafariUserAgentWhenThePluginNamedNone() {
        let service = PluginFetchService(protocolClasses: [PluginStubURLProtocol.self])
        PluginStubURLProtocol.respond(to: "https://example.com/ua", status: 200, body: "")
        let expectation = expectation(description: "the request completes")

        service.fetch(PluginFetchRequest(
            url: URL(string: "https://example.com/ua")!, cookies: .none)
        ) { _ in expectation.fulfill() }
        wait(for: [expectation], timeout: 10)

        XCTAssertEqual(
            PluginStubURLProtocol.requests.first?.value(forHTTPHeaderField: "User-Agent"),
            WebFetchConstants.safariUserAgent)
    }

    func testTheServiceCutsABodyAtMaxBytesAndReportsItTruncated() {
        let service = PluginFetchService(protocolClasses: [PluginStubURLProtocol.self])
        PluginStubURLProtocol.respond(
            to: "https://example.com/big", status: 200,
            body: String(repeating: "x", count: 5000))
        let expectation = expectation(description: "the request completes")
        var response: PluginFetchResponse?

        service.fetch(PluginFetchRequest(
            url: URL(string: "https://example.com/big")!, cookies: .none, maxBytes: 100)
        ) { outcome in
            response = try? outcome.get()
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 10)

        XCTAssertEqual(response?.truncated, true)
        XCTAssertEqual(response?.body.count, 100)
    }

}

/// Answers `PluginFetchService`'s requests from a table and records what it was
/// asked for.
final class PluginStubURLProtocol: URLProtocol {

    private static let lock = NSLock()
    nonisolated(unsafe) private static var table: [String: (Int, Data)] = [:]
    nonisolated(unsafe) private static var recorded: [URLRequest] = []
    nonisolated(unsafe) private static var recordedBodies: [Data] = []

    static var requests: [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    static var bodies: [Data] {
        lock.lock(); defer { lock.unlock() }
        return recordedBodies
    }

    static func reset() {
        lock.lock()
        table.removeAll()
        recorded.removeAll()
        recordedBodies.removeAll()
        lock.unlock()
    }

    static func respond(to urlString: String, status: Int, body: String) {
        lock.lock()
        table[urlString] = (status, Data(body.utf8))
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let urlString = request.url?.absoluteString ?? ""
        // `httpBody` is stripped by the time a protocol sees a body stream, so
        // the stream is what a POST's bytes have to be read from.
        var body = request.httpBody
        if body == nil, let stream = request.httpBodyStream {
            stream.open()
            var collected = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                guard read > 0 else { break }
                collected.append(contentsOf: buffer[0..<read])
            }
            stream.close()
            body = collected
        }
        Self.lock.lock()
        Self.recorded.append(request)
        Self.recordedBodies.append(body ?? Data())
        let answer = Self.table[urlString]
        Self.lock.unlock()

        guard let answer, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let response = HTTPURLResponse(
            url: url, statusCode: answer.0, httpVersion: "HTTP/1.1", headerFields: [:])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: answer.1)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
