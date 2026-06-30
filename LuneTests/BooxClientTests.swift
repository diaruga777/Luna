//
//  BooxClientTests.swift
//  LuneTests
//

import LuneSend
import XCTest
@testable import Lune

/// Intercepts URLSession requests and returns canned responses keyed by URL path.
private final class MockURLProtocol: URLProtocol {
    /// path-substring → (statusCode, body). Set per test.
    static var routes: [(match: String, status: Int, body: Data)] = []
    static var requestedPaths: [String] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let urlString = request.url?.absoluteString ?? ""
        Self.requestedPaths.append(urlString)
        let route = Self.routes.first { urlString.contains($0.match) }
        let status = route?.status ?? 404
        let body = route?.body ?? Data()
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    static func reset() {
        routes = []
        requestedPaths = []
    }
}

final class BooxClientTests: XCTestCase {

    override func tearDown() {
        MockURLProtocol.reset()
        super.tearDown()
    }

    private func json(_ string: String) -> Data { Data(string.utf8) }

    func testLoginParsesToken() async throws {
        MockURLProtocol.routes = [
            ("users/signupByPhoneOrEmail", 200, json(#"{"data":{"token":"TOK123"}}"#)),
        ]
        let auth = BooxAuthClient(host: "eur.boox.com", session: MockURLProtocol.session())
        let token = try await auth.login(identity: "me@example.com", code: "0000")
        XCTAssertEqual(token, "TOK123")
    }

    func testRequestLoginCodeHitsSendMobileCode() async throws {
        MockURLProtocol.routes = [("users/sendMobileCode", 200, json("{}"))]
        let auth = BooxAuthClient(host: "eur.boox.com", session: MockURLProtocol.session())
        try await auth.requestLoginCode(identity: "me@example.com")
        XCTAssertTrue(MockURLProtocol.requestedPaths.contains { $0.contains("users/sendMobileCode") })
    }

    func testLoginThrowsOnErrorStatus() async {
        MockURLProtocol.routes = [("users/signupByPhoneOrEmail", 401, json("{}"))]
        let auth = BooxAuthClient(host: "eur.boox.com", session: MockURLProtocol.session())
        do {
            _ = try await auth.login(identity: "me@example.com", code: "0000")
            XCTFail("expected throw")
        } catch {
            // expected
        }
    }

    func testUploadThrowsWhenNoToken() async {
        let credentials = InMemorySendCredentialsStore() // no token
        let client = Send2BooxClient(
            host: "eur.boox.com", credentials: credentials, session: MockURLProtocol.session())
        do {
            try await client.upload(epubData: Data("epub".utf8), fileName: "a.epub", title: "A")
            XCTFail("expected NotConfiguredError")
        } catch is Send2BooxClient.NotConfiguredError {
            // expected
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testUploadHappyPathRunsAllSteps() async throws {
        let credentials = InMemorySendCredentialsStore()
        credentials.setBooxToken("TOK")
        MockURLProtocol.routes = [
            ("users/me", 200, json(#"{"data":{"uid":"user-1"}}"#)),
            ("config/buckets", 200, json(#"{"data":{"onyx-cloud":{"bucket":"b1","aliEndpoint":"oss-eu-central-1.aliyuncs.com"}}}"#)),
            ("config/stss", 200, json(#"{"data":{"AccessKeyId":"AK","AccessKeySecret":"SK","SecurityToken":"ST"}}"#)),
            ("push/saveAndPush", 200, json("{}")),
            // The OSS PUT goes to b1.oss-eu-central-1.aliyuncs.com — match the bucket host.
            ("b1.oss-eu-central-1.aliyuncs.com", 200, Data()),
        ]
        let client = Send2BooxClient(
            host: "eur.boox.com", credentials: credentials, session: MockURLProtocol.session())
        try await client.upload(epubData: Data("epub-bytes".utf8), fileName: "Article.epub", title: "Article")

        let paths = MockURLProtocol.requestedPaths
        XCTAssertTrue(paths.contains { $0.contains("users/me") })
        XCTAssertTrue(paths.contains { $0.contains("config/stss") })
        XCTAssertTrue(paths.contains { $0.contains("b1.oss-eu-central-1.aliyuncs.com") })
        XCTAssertTrue(paths.contains { $0.contains("push/saveAndPush") })
    }
}
