//
//  MessageCryptoTests.swift
//  LuneTests
//

import LuneSocial
import CryptoKit
import XCTest
@testable import Lune

final class MessageCryptoTests: XCTestCase {

    private func makeIdentity(username: String) -> UserIdentity {
        UserIdentity(
            uuid: UUID(), username: username, email: nil, phone: nil,
            encryptionKey: Curve25519.KeyAgreement.PrivateKey(),
            signingKey: Curve25519.Signing.PrivateKey())
    }

    func testSealOpenRoundTrip() throws {
        let alice = makeIdentity(username: "alice")
        let bob = makeIdentity(username: "bob")

        let sealed = try MessageCrypto.seal(
            body: .readingListItem(urlString: "https://example.com/a", title: "A"),
            senderSigningKey: alice.signingKey,
            recipientEncryptionPublicKey: bob.card.encryptionPublicKey)

        let (body, signingKey) = try MessageCrypto.open(
            payload: sealed, recipientEncryptionKey: bob.encryptionKey)
        XCTAssertEqual(body, .readingListItem(urlString: "https://example.com/a", title: "A"))
        XCTAssertEqual(signingKey, alice.card.signingPublicKey)
    }

    func testFriendAddCardSurvivesRoundTrip() throws {
        let alice = makeIdentity(username: "alice")
        let bob = makeIdentity(username: "bob")

        let sealed = try MessageCrypto.seal(
            body: .friendAdd(alice.card),
            senderSigningKey: alice.signingKey,
            recipientEncryptionPublicKey: bob.card.encryptionPublicKey)
        let (body, _) = try MessageCrypto.open(
            payload: sealed, recipientEncryptionKey: bob.encryptionKey)
        XCTAssertEqual(body, .friendAdd(alice.card))
    }

    func testWrongRecipientCannotOpen() throws {
        let alice = makeIdentity(username: "alice")
        let bob = makeIdentity(username: "bob")
        let eve = makeIdentity(username: "eve")

        let sealed = try MessageCrypto.seal(
            body: .friendAdd(alice.card),
            senderSigningKey: alice.signingKey,
            recipientEncryptionPublicKey: bob.card.encryptionPublicKey)
        XCTAssertThrowsError(
            try MessageCrypto.open(payload: sealed, recipientEncryptionKey: eve.encryptionKey))
    }

    func testTamperedCiphertextFails() throws {
        let alice = makeIdentity(username: "alice")
        let bob = makeIdentity(username: "bob")

        let sealed = try MessageCrypto.seal(
            body: .friendAdd(alice.card),
            senderSigningKey: alice.signingKey,
            recipientEncryptionPublicKey: bob.card.encryptionPublicKey)
        var tampered = sealed
        // Flip a byte near the end (inside the base64 of the ciphertext field).
        tampered[tampered.count - 10] ^= 0x41
        XCTAssertThrowsError(
            try MessageCrypto.open(payload: tampered, recipientEncryptionKey: bob.encryptionKey))
    }

    func testGarbagePayloadFails() {
        let bob = makeIdentity(username: "bob")
        XCTAssertThrowsError(
            try MessageCrypto.open(
                payload: Data("not json".utf8), recipientEncryptionKey: bob.encryptionKey))
    }
}
