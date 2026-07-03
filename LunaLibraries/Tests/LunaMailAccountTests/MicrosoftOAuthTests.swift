//
//  MicrosoftOAuthTests.swift
//  LunaMailAccountTests
//

import XCTest
@testable import LunaMailAccount

final class MicrosoftOAuthTests: XCTestCase {

    func testAuthorizationURL() throws {
        let pkce = MicrosoftOAuth.makePKCE()
        let url = try XCTUnwrap(
            MicrosoftOAuth.authorizationURL(clientID: "abc-123", challenge: pkce.challenge))
        let items = try XCTUnwrap(
            URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }

        XCTAssertTrue(url.absoluteString.hasPrefix(MicrosoftOAuth.authorizeEndpoint))
        XCTAssertEqual(value("client_id"), "abc-123")
        XCTAssertEqual(value("response_type"), "code")
        XCTAssertEqual(value("redirect_uri"), MicrosoftOAuth.redirectURI)
        XCTAssertEqual(value("code_challenge_method"), "S256")
        XCTAssertEqual(value("code_challenge"), pkce.challenge)
        XCTAssertTrue(value("scope")?.contains("Mail.Send") == true)
        XCTAssertTrue(value("scope")?.contains("offline_access") == true)
        // No hint given → no login_hint item.
        XCTAssertNil(value("login_hint"))
    }

    func testAuthorizationURLPassesLoginHint() throws {
        let pkce = MicrosoftOAuth.makePKCE()
        let url = try XCTUnwrap(
            MicrosoftOAuth.authorizationURL(
                clientID: "abc-123", challenge: pkce.challenge, loginHint: "user@outlook.com"))
        let items = try XCTUnwrap(
            URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(items.first { $0.name == "login_hint" }?.value, "user@outlook.com")
    }

    func testAuthorizationURLOmitsBlankLoginHint() throws {
        let pkce = MicrosoftOAuth.makePKCE()
        let url = try XCTUnwrap(
            MicrosoftOAuth.authorizationURL(
                clientID: "abc-123", challenge: pkce.challenge, loginHint: "   "))
        let items = try XCTUnwrap(
            URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertNil(items.first { $0.name == "login_hint" }?.value)
    }

    func testPKCEChallengeIsURLSafeBase64() {
        let pkce = MicrosoftOAuth.makePKCE()
        XCTAssertFalse(pkce.verifier.isEmpty)
        XCTAssertFalse(pkce.challenge.contains("+"))
        XCTAssertFalse(pkce.challenge.contains("/"))
        XCTAssertFalse(pkce.challenge.contains("="))
        // SHA-256 -> 32 bytes -> 43 base64url chars (no padding).
        XCTAssertEqual(pkce.challenge.count, 43)
    }

    func testTokenParameters() {
        let exchange = MicrosoftOAuth.tokenExchangeParameters(
            clientID: "c", code: "the code", verifier: "v")
        XCTAssertEqual(exchange["grant_type"], "authorization_code")
        XCTAssertEqual(exchange["code"], "the code")
        XCTAssertEqual(exchange["redirect_uri"], MicrosoftOAuth.redirectURI)

        let refresh = MicrosoftOAuth.refreshParameters(clientID: "c", refreshToken: "r")
        XCTAssertEqual(refresh["grant_type"], "refresh_token")
        XCTAssertEqual(refresh["refresh_token"], "r")

        // Form encoding percent-escapes the space in "the code".
        let encoded = String(decoding: MicrosoftOAuth.formEncode(["a": "the code"]), as: UTF8.self)
        XCTAssertEqual(encoded, "a=the%20code")
    }
}
