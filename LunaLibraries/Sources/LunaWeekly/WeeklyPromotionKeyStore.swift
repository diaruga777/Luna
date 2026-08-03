//
//  WeeklyPromotionKeyStore.swift
//  LunaWeekly
//

import CryptoKit
import Foundation
import LunaStorage

/// Where the curator's private key lives on a device that has one.
///
/// `CredentialKeychain` stores into the shared App-Group access group, so a
/// single paste in any one Luna app makes all four apps on that device
/// key-holders. A stored value that no longer matches the bundled public key
/// (a rotated key, a corrupted item) reads as absent rather than producing
/// signatures nobody accepts.
public enum WeeklyPromotionKeyStore {
    static let service = "weeklyPromotionKey"
    static let account = "curator"

    public static func storedPrivateKey() -> Curve25519.Signing.PrivateKey? {
        guard let base64 = CredentialKeychain.read(service: service, account: account)
        else { return nil }
        return WeeklySigning.privateKey(fromBase64: base64)
    }

    /// Whether this device can promote. Cheap enough to call from menu
    /// construction (one Keychain read, `kSecAttrAccessibleAfterFirstUnlock`).
    public static var isKeyHolder: Bool { storedPrivateKey() != nil }

    /// Validates then stores. Returns false — storing nothing — when the key
    /// isn't the bundled public key's counterpart.
    @discardableResult
    public static func store(base64: String) -> Bool {
        guard WeeklySigning.privateKeyMatchesBundledPublicKey(base64) else { return false }
        CredentialKeychain.write(
            base64.trimmingCharacters(in: .whitespacesAndNewlines),
            service: service, account: account)
        return true
    }

    public static func removeKey() {
        CredentialKeychain.delete(service: service, account: account)
    }
}
