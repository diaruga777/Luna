//
//  MessageCrypto.swift
//  Lune
//

import CryptoKit
import Foundation

/// Seals and opens message payloads: the body is signed with the sender's
/// Ed25519 key, then body+signature+sender-signing-key are encrypted to the
/// recipient's X25519 key with HPKE. The signature is verified on open; the
/// CALLER decides whether the returned signing key is trusted (stored friend
/// key match, or trust-on-first-use for friend adds).
public enum MessageCrypto {

    public struct CryptoError: Error, CustomStringConvertible {
        public let reason: String
        public var description: String { "MessageCrypto: \(reason)" }
        public init(reason: String) { self.reason = reason }
    }

    private static let ciphersuite = HPKE.Ciphersuite.Curve25519_SHA256_ChachaPoly
    private static let hpkeInfo = Data("clip-message-v1".utf8)

    /// What travels inside the encrypted payload.
    private struct SignedBody: Codable {
        let body: Data
        let signature: Data
        let senderSigningPublicKey: Data
    }

    /// Outer wire shape: HPKE encapsulated key + ciphertext.
    private struct SealedPayload: Codable {
        let encapsulatedKey: Data
        let ciphertext: Data
    }

    /// Signs `body` with the sender's key and encrypts everything to the
    /// recipient's X25519 public key. The result is the record payload.
    public static func seal(
        body: MessageBody,
        senderSigningKey: Curve25519.Signing.PrivateKey,
        recipientEncryptionPublicKey: Data
    ) throws -> Data {
        let bodyData = try body.encoded()
        let signature = try senderSigningKey.signature(for: bodyData)
        let signed = SignedBody(
            body: bodyData,
            signature: signature,
            senderSigningPublicKey: senderSigningKey.publicKey.rawRepresentation)
        let plaintext = try JSONEncoder().encode(signed)

        let recipientKey = try Curve25519.KeyAgreement.PublicKey(
            rawRepresentation: recipientEncryptionPublicKey)
        var sender = try HPKE.Sender(
            recipientKey: recipientKey, ciphersuite: ciphersuite, info: hpkeInfo)
        let ciphertext = try sender.seal(plaintext)
        return try JSONEncoder().encode(
            SealedPayload(encapsulatedKey: sender.encapsulatedKey, ciphertext: ciphertext))
    }

    /// Decrypts a payload with the recipient's private key and verifies the
    /// embedded signature. Returns the body and the sender's signing public
    /// key (raw bytes) for the caller's trust decision.
    public static func open(
        payload: Data,
        recipientEncryptionKey: Curve25519.KeyAgreement.PrivateKey
    ) throws -> (body: MessageBody, senderSigningPublicKey: Data) {
        let sealed = try JSONDecoder().decode(SealedPayload.self, from: payload)
        var recipient = try HPKE.Recipient(
            privateKey: recipientEncryptionKey,
            ciphersuite: ciphersuite,
            info: hpkeInfo,
            encapsulatedKey: sealed.encapsulatedKey)
        let plaintext = try recipient.open(sealed.ciphertext)

        let signed = try JSONDecoder().decode(SignedBody.self, from: plaintext)
        let signingKey = try Curve25519.Signing.PublicKey(
            rawRepresentation: signed.senderSigningPublicKey)
        guard signingKey.isValidSignature(signed.signature, for: signed.body) else {
            throw CryptoError(reason: "signature verification failed")
        }
        return (try MessageBody.decoded(from: signed.body), signed.senderSigningPublicKey)
    }
}
