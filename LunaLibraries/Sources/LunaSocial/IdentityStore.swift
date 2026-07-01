//
//  IdentityStore.swift
//  Luna
//

import CryptoKit
import Foundation
import Security

/// Loads and persists this user's social identity.
public protocol IdentityStoring {
    /// The stored identity, or nil before onboarding has run.
    func loadIdentity() -> UserIdentity?
    /// Generates a fresh UUID + key pairs and persists them. Returns nil when
    /// the username fails validation.
    @discardableResult
    func createIdentity(username: String, email: String?, phone: String?) -> UserIdentity?
    /// Updates the cosmetic profile fields (keys and UUID never change).
    /// Returns the updated identity, or nil when the username fails validation.
    @discardableResult
    func updateProfile(username: String, email: String?, phone: String?) -> UserIdentity?
}

/// Keychain-backed identity storage. Items are marked synchronizable so the
/// identity survives reinstalls and roams to the user's other devices via
/// iCloud Keychain.
public final class KeychainIdentityStore: IdentityStoring {

    public static let shared = KeychainIdentityStore()

    private let service = "com.hsanabria.luna.identity"
    private let account = "identity"

    /// On-disk shape: keys as raw bytes alongside the profile.
    private struct StoredIdentity: Codable {
        let uuid: UUID
        var username: String
        var email: String?
        var phone: String?
        let encryptionPrivateKey: Data
        let signingPrivateKey: Data
    }

    public func loadIdentity() -> UserIdentity? {
        guard let data = readKeychainData(),
              let stored = try? JSONDecoder().decode(StoredIdentity.self, from: data),
              let encryptionKey = try? Curve25519.KeyAgreement.PrivateKey(
                rawRepresentation: stored.encryptionPrivateKey),
              let signingKey = try? Curve25519.Signing.PrivateKey(
                rawRepresentation: stored.signingPrivateKey)
        else { return nil }
        return UserIdentity(
            uuid: stored.uuid, username: stored.username,
            email: stored.email, phone: stored.phone,
            encryptionKey: encryptionKey, signingKey: signingKey)
    }

    @discardableResult
    public func createIdentity(username: String, email: String?, phone: String?) -> UserIdentity? {
        guard let validUsername = ProfileValidation.normalizedUsername(username) else { return nil }
        let identity = UserIdentity(
            uuid: UUID(),
            username: validUsername,
            email: ProfileValidation.normalizedContactField(email),
            phone: ProfileValidation.normalizedContactField(phone),
            encryptionKey: Curve25519.KeyAgreement.PrivateKey(),
            signingKey: Curve25519.Signing.PrivateKey())
        persist(identity)
        return identity
    }

    @discardableResult
    public func updateProfile(username: String, email: String?, phone: String?) -> UserIdentity? {
        guard var identity = loadIdentity(),
              let validUsername = ProfileValidation.normalizedUsername(username)
        else { return nil }
        identity.username = validUsername
        identity.email = ProfileValidation.normalizedContactField(email)
        identity.phone = ProfileValidation.normalizedContactField(phone)
        persist(identity)
        return identity
    }

    // MARK: - Keychain plumbing

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
        ]
    }

    private func readKeychainData() -> Data? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess
        else { return nil }
        return result as? Data
    }

    private func persist(_ identity: UserIdentity) {
        let stored = StoredIdentity(
            uuid: identity.uuid, username: identity.username,
            email: identity.email, phone: identity.phone,
            encryptionPrivateKey: identity.encryptionKey.rawRepresentation,
            signingPrivateKey: identity.signingKey.rawRepresentation)
        guard let data = try? JSONEncoder().encode(stored) else { return }

        SecItemDelete(baseQuery as CFDictionary)
        var query = baseQuery
        query[kSecAttrSynchronizable as String] = kCFBooleanTrue as Any
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(query as CFDictionary, nil)
    }
}

/// In-memory stand-in for tests.
public final class InMemoryIdentityStore: IdentityStoring {
    private var identity: UserIdentity?

    public init(identity: UserIdentity? = nil) {
        self.identity = identity
    }

    public func loadIdentity() -> UserIdentity? { identity }

    @discardableResult
    public func createIdentity(username: String, email: String?, phone: String?) -> UserIdentity? {
        guard let validUsername = ProfileValidation.normalizedUsername(username) else { return nil }
        let created = UserIdentity(
            uuid: UUID(),
            username: validUsername,
            email: ProfileValidation.normalizedContactField(email),
            phone: ProfileValidation.normalizedContactField(phone),
            encryptionKey: Curve25519.KeyAgreement.PrivateKey(),
            signingKey: Curve25519.Signing.PrivateKey())
        identity = created
        return created
    }

    @discardableResult
    public func updateProfile(username: String, email: String?, phone: String?) -> UserIdentity? {
        guard var current = identity,
              let validUsername = ProfileValidation.normalizedUsername(username)
        else { return nil }
        current.username = validUsername
        current.email = ProfileValidation.normalizedContactField(email)
        current.phone = ProfileValidation.normalizedContactField(phone)
        identity = current
        return current
    }
}
