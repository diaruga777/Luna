import Foundation
import XCTest
import LunaMailAccount
@testable import LunaMailTransport

final class GraphRecentMailTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!
    private var store: EmailAccountStore!
    private var session: URLSession!

    override func setUp() {
        super.setUp()
        suite = "GraphRecentMailTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        store = EmailAccountStore(defaults: defaults, credentialStorage: InMemoryCredentialStorage())
        store.save(EmailAccount(providerID: .outlook, address: "reader@example.com"),
                   credential: .oauth(OAuthTokens(accessToken: "scratch", refreshToken: "scratch", expiry: Date().addingTimeInterval(3600))))
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RecentMailURLProtocol.self]
        session = URLSession(configuration: config)
    }

    override func tearDown() {
        session.invalidateAndCancel()
        RecentMailURLProtocol.handler = nil
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    func testRecentScanFollowsAllPagesAndMatchesDecodedHTMLBySubjectOrSender() async throws {
        var requests: [URLRequest] = []
        RecentMailURLProtocol.handler = { request in
            requests.append(request)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer scratch")
            if request.url!.query!.contains("skiptoken") {
                return (200, """
                {"value":[{"id":"second","subject":"Other subject","from":{"emailAddress":{"address":"sender@example.com"}},"receivedDateTime":"2026-10-14T00:00:00Z","body":{"contentType":"text","content":"Second article"}}]}
                """)
            }
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            XCTAssertEqual(query.first(where: { $0.name == "$filter" })?.value, "receivedDateTime ge 2026-10-07T00:00:00Z")
            return (200, """
            {"value":[{"id":"first","subject":"DAILY NEWS","receivedDateTime":"2026-10-13T00:00:00Z","body":{"contentType":"html","content":"<p>First article</p>"},"internetMessageHeaders":[{"name":"Content-Transfer-Encoding","value":"base64"}]},{"id":"irrelevant","subject":"Receipt"}],"@odata.nextLink":"https://graph.microsoft.com/v1.0/me/messages?skiptoken=next"}
            """)
        }
        let since = ISO8601DateFormatter().date(from: "2026-10-07T00:00:00Z")!
        let result = try await GraphMailTransport(store: store, session: session).fetchRecentShares(
            since: since, extraSenders: ["sender@example.com"], extraSubjects: ["Daily News"])
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(result.messages.map(\.id), ["first", "second"])
        XCTAssertEqual(result.messages.first?.headers["content-type"], "text/html; charset=utf-8")
        XCTAssertNil(result.messages.first?.headers["content-transfer-encoding"])
    }

    func testRecentFetchAuthenticationFailureReachesRecoveryWrapper() async {
        RecentMailURLProtocol.handler = { _ in (401, "{}") }
        let transport = AuthenticationStateTrackingTransport(base: GraphMailTransport(store: store, session: session), store: store)
        do {
            _ = try await transport.fetchRecentShares(since: Date(), extraSenders: [], extraSubjects: [])
            XCTFail("Expected authentication rejection")
        } catch {
            XCTAssertTrue(error is EmailAuthenticationError)
            XCTAssertEqual(store.authenticationIssue, .authorizationExpired)
        }
    }
}

private final class RecentMailURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, String))?
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "graph.microsoft.com" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, body) = try Self.handler!(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {}
}
