//
//  UserIdentity.swift
//  Clip
//

import CryptoKit
import Foundation

/// This user's durable social identity: a self-assigned UUID plus an X25519
/// key pair (message encryption) and an Ed25519 key pair (message signing).
/// Username/email/phone are purely cosmetic profile fields.
struct UserIdentity {
    let uuid: UUID
    var username: String
    var email: String?
    var phone: String?
    let encryptionKey: Curve25519.KeyAgreement.PrivateKey
    let signingKey: Curve25519.Signing.PrivateKey

    /// The shareable public half (what goes in QR codes, links, and
    /// friendAdd payloads).
    var card: IdentityCard {
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
struct IdentityCard: Codable, Equatable {
    let uuid: UUID
    var username: String
    var email: String?
    var phone: String?
    /// Raw X25519 public key bytes.
    var encryptionPublicKey: Data
    /// Raw Ed25519 public key bytes.
    var signingPublicKey: Data
}

/// Profile field validation shared by the identity store and the UI.
enum ProfileValidation {
    static let usernameMaxLength = 20
    static let contactFieldMaxLength = 60

    /// Trims and validates a username: 1–20 characters after trimming, with no
    /// ":" (reserved as the delimiter in the share-suggestion intent token,
    /// e.g. "3:username").
    static func normalizedUsername(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= usernameMaxLength,
              !trimmed.contains(":") else { return nil }
        return trimmed
    }

    /// Trims an optional cosmetic contact field; empty collapses to nil.
    static func normalizedContactField(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else { return nil }
        return String(trimmed.prefix(contactFieldMaxLength))
    }
}
