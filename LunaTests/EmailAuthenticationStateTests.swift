//
//  EmailAuthenticationStateTests.swift
//  LunaTests
//

import LunaMailAccount
@testable import LunaMailTransport
import XCTest

final class EmailAuthenticationStateTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var store: EmailAccountStore!

    override func setUp() {
        super.setUp()
        suiteName = "EmailAuthenticationStateTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        store = EmailAccountStore(
            defaults: defaults, credentialStorage: InMemoryCredentialStorage())
        store.save(
            EmailAccount(providerID: .gmail, address: "person@gmail.com"),
            credential: .appPassword("saved-password"))
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        store = nil
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testTypedAuthenticationFailureMarksAccountForRecovery() async {
        let transport = AuthenticationStateTrackingTransport(
            base: StubTransport(result: .authenticationFailure(.credentialsRejected)),
            store: store)

        do {
            try await transport.verifyCredentials()
            XCTFail("Expected authentication failure")
        } catch {
            XCTAssertEqual(store.authenticationIssue, .credentialsRejected)
            XCTAssertTrue(store.isConfigured)
            XCTAssertFalse(store.isReady)
            XCTAssertNil(MailTransportFactory.make(store: store))
        }
    }

    func testConnectivityFailureDoesNotInvalidateLogin() async {
        let transport = AuthenticationStateTrackingTransport(
            base: StubTransport(result: .connectivityFailure), store: store)

        do {
            try await transport.verifyCredentials()
            XCTFail("Expected connectivity failure")
        } catch {
            XCTAssertNil(store.authenticationIssue)
            XCTAssertTrue(store.isReady)
        }
    }

    func testSuccessfulAuthenticatedCallClearsStaleIssue() async throws {
        store.markAuthenticationIssue(.authorizationExpired)
        let transport = AuthenticationStateTrackingTransport(
            base: StubTransport(result: .success), store: store)

        try await transport.verifyCredentials()

        XCTAssertNil(store.authenticationIssue)
        XCTAssertTrue(store.isReady)
    }

    func testGraphAuthenticationResponseClassification() {
        XCTAssertTrue(GraphMailTransport.authenticationFailure(
            statusCode: 401, body: Data()))
        XCTAssertTrue(GraphMailTransport.authenticationFailure(
            statusCode: 400, body: Data(#"{"error":"invalid_grant"}"#.utf8)))
        XCTAssertTrue(GraphMailTransport.authenticationFailure(
            statusCode: 403,
            body: Data(#"{"error":{"code":"ErrorAccessDenied"}}"#.utf8)))
        XCTAssertFalse(GraphMailTransport.authenticationFailure(
            statusCode: 400, body: Data(#"{"error":"invalid_request"}"#.utf8)))
        XCTAssertFalse(GraphMailTransport.authenticationFailure(
            statusCode: 429, body: Data(#"{"error":"too_many_requests"}"#.utf8)))
        XCTAssertFalse(GraphMailTransport.authenticationFailure(
            statusCode: 503, body: Data()))
    }
}

private struct StubTransport: EmailTransport {
    enum Result {
        case success
        case authenticationFailure(EmailAuthenticationIssue)
        case connectivityFailure
    }

    let result: Result

    func verifyCredentials() async throws {
        try resolve()
    }

    func send(_ email: OutgoingEmail) async throws {
        try resolve()
    }

    func fetchShares(
        after cursor: MailCursor?,
        extraSenders: [String],
        extraSubjects: [String]
    ) async throws -> FetchResult {
        try resolve()
        return FetchResult(messages: [], cursor: cursor ?? MailCursor())
    }

    func markRead(_ messageIDs: [String]) async throws {
        try resolve()
    }

    func createLunaFilter() async throws -> FilterOutcome {
        try resolve()
        return .created
    }

    private func resolve() throws {
        switch result {
        case .success:
            return
        case .authenticationFailure(let issue):
            throw EmailAuthenticationError(issue: issue, detail: "fixture rejection")
        case .connectivityFailure:
            throw URLError(.notConnectedToInternet)
        }
    }
}
