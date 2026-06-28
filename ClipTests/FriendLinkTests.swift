//
//  FriendLinkTests.swift
//  ClipTests
//

import ClipSocialUI
import ClipSocial
import XCTest
@testable import Clip

final class FriendLinkTests: XCTestCase {

    private func makeCard(
        username: String = "alice", email: String? = nil, phone: String? = nil
    ) -> IdentityCard {
        IdentityCard(
            uuid: UUID(), username: username, email: email, phone: phone,
            encryptionPublicKey: Data((0..<32).map { UInt8($0) }),
            signingPublicKey: Data((0..<32).map { UInt8(255 - $0) }))
    }

    func testRoundTripMinimalCard() throws {
        let card = makeCard()
        let url = try XCTUnwrap(FriendLink.url(for: card))
        XCTAssertEqual(url.scheme, "clipreader")
        XCTAssertEqual(FriendLink.card(from: url), card)
    }

    func testRoundTripWithEmailPhoneAndSpecialCharacters() throws {
        let card = makeCard(
            username: "héllo & wörld", email: "a+b@example.com", phone: "+1 (555) 010-9999")
        let url = try XCTUnwrap(FriendLink.url(for: card))
        XCTAssertEqual(FriendLink.card(from: url), card)
    }

    func testUsernameOverLimitRejected() throws {
        let card = makeCard(username: String(repeating: "x", count: 21))
        // Build the URL manually since url(for:) doesn't validate.
        let url = try XCTUnwrap(FriendLink.url(for: card))
        XCTAssertNil(FriendLink.card(from: url))
    }

    func testJunkURLsRejected() {
        let junk = [
            "https://example.com/friend?u=abc",
            "clipreader://friend",
            "clipreader://friend?u=not-a-uuid&n=a&ke=AAAA&ks=AAAA",
            "clipreader://other?u=\(UUID().uuidString)&n=a&ke=AAAA&ks=AAAA",
            // Keys of the wrong length:
            "clipreader://friend?u=\(UUID().uuidString)&n=a&ke=AAAA&ks=AAAA",
        ]
        for text in junk {
            guard let url = URL(string: text.addingPercentEncoding(
                withAllowedCharacters: .urlQueryAllowed) ?? text) ?? URL(string: text) else {
                continue
            }
            XCTAssertNil(FriendLink.card(from: url), "should reject: \(text)")
        }
    }

    func testQRCodeGeneratesForTypicalCard() throws {
        let card = makeCard(username: "twentycharusername00", email: "someone@example.com",
                            phone: "+15550109999")
        let url = try XCTUnwrap(FriendLink.url(for: card))
        XCTAssertNotNil(FriendsViewController.qrCode(for: url.absoluteString))
    }
}
