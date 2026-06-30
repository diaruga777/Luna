//
//  UserIdentity.swift
//  Lune
//

import CryptoKit
import Foundation

/// This user's durable social identity: a self-assigned UUID plus an X25519
/// key pair (message encryption) and an Ed25519 key pair (message signing).
/// Username/email/phone are purely cosmetic profile fields.
public struct UserIdentity {
    public let uuid: UUID
    public var username: String
    public var email: String?
    public var phone: String?
    public let encryptionKey: Curve25519.KeyAgreement.PrivateKey
    public let signingKey: Curve25519.Signing.PrivateKey

    public init(uuid: UUID, username: String, email: String?, phone: String?,
                encryptionKey: Curve25519.KeyAgreement.PrivateKey,
                signingKey: Curve25519.Signing.PrivateKey) {
        self.uuid = uuid
        self.username = username
        self.email = email
        self.phone = phone
        self.encryptionKey = encryptionKey
        self.signingKey = signingKey
    }

    /// The shareable public half (what goes in QR codes, links, and
    /// friendAdd payloads).
    public var card: IdentityCard {
        IdentityCard(
            uuid: uuid,
            username: username,
            email: email,
            phone: phone,
            encryptionPublicKey: encryptionKey.publicKey.rawRepresentation,
            signingPublicKey: signingKey.publicKey.rawRepresentation)
    }
}

/// The public half of an identity — everything a friend needs to encrypt to,
/// verify, and display this user.
public struct IdentityCard: Codable, Equatable {
    public let uuid: UUID
    public var username: String
    public var email: String?
    public var phone: String?
    /// Raw X25519 public key bytes.
    public var encryptionPublicKey: Data
    /// Raw Ed25519 public key bytes.
    public var signingPublicKey: Data

    public init(uuid: UUID, username: String, email: String?, phone: String?,
                encryptionPublicKey: Data, signingPublicKey: Data) {
        self.uuid = uuid
        self.username = username
        self.email = email
        self.phone = phone
        self.encryptionPublicKey = encryptionPublicKey
        self.signingPublicKey = signingPublicKey
    }
}

/// Profile field validation shared by the identity store and the UI.
public enum ProfileValidation {
    public static let usernameMaxLength = 20
    public static let contactFieldMaxLength = 60

    /// Trims and validates a username: 1–20 characters after trimming, with no
    /// ":" (reserved as the delimiter in the share-suggestion intent token,
    /// e.g. "3:username").
    public static func normalizedUsername(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= usernameMaxLength,
              !trimmed.contains(":") else { return nil }
        return trimmed
    }

    /// Trims an optional cosmetic contact field; empty collapses to nil.
    public static func normalizedContactField(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else { return nil }
        return String(trimmed.prefix(contactFieldMaxLength))
    }
}
