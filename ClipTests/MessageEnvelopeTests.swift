//
//  MessageEnvelopeTests.swift
//  ClipTests
//

import XCTest
@testable import Clip

final class MessageEnvelopeTests: XCTestCase {

    func testFriendAddRoundTrip() throws {
        let card = IdentityCard(
            uuid: UUID(), username: "alice", email: "a@example.com", phone: "+1555",
            encryptionPublicKey: Data(repeating: 1, count: 32),
            signingPublicKey: Data(repeating: 2, count: 32))
        let body = MessageBody.friendAdd(card)
        XCTAssertEqual(try MessageBody.decoded(from: try body.encoded()), body)
    }

    func testReadingListItemRoundTrip() throws {
        let body = MessageBody.readingListItem(urlString: "https://example.com/a", title: nil)
        XCTAssertEqual(try MessageBody.decoded(from: try body.encoded()), body)
    }

    func testUnknownTypeDecodesAsUnknown() throws {
        let wire = Data(#"{"type":"holographicSticker","payload":"whatever"}"#.utf8)
        XCTAssertEqual(try MessageBody.decoded(from: wire), .unknown(type: "holographicSticker"))
    }

    func testKnownTypeWithMissingFieldsDecodesAsUnknown() throws {
        // A "friendAdd" without a card must not crash or half-decode.
        let wire = Data(#"{"type":"friendAdd"}"#.utf8)
        XCTAssertEqual(try MessageBody.decoded(from: wire), .unknown(type: "friendAdd"))
    }
}
