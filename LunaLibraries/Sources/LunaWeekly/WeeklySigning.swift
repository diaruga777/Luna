//
//  WeeklySigning.swift
//  LunaWeekly
//

import CryptoKit
import Foundation

/// Ed25519 signing/verification for `WeeklySave`.
///
/// Every install carries the PUBLIC key; only the curator's devices ever hold
/// the private half (pasted once through the diagnostics screen, kept in the
/// shared App-Group Keychain). A record whose signature doesn't verify is
/// treated as though the record did not exist — the public CloudKit database is
/// world-writable in principle, and this is what makes that harmless.
public enum WeeklySigning {

    /// The bundled public key, base64 of the 32-byte raw representation. Its
    /// private half lives OUTSIDE this repository.
    public static let publicKeyBase64 = "o3FR1R1bN8vZxNdqsxWwb7/tkM0ZYPPYOgQyIf5wLl4="

    /// The parsed bundled key. Nil only if the literal above were corrupted,
    /// which `WeeklySigningTests` pins against.
    public static var publicKey: Curve25519.Signing.PublicKey? {
        guard let data = Data(base64Encoded: publicKeyBase64) else { return nil }
        return try? Curve25519.Signing.PublicKey(rawRepresentation: data)
    }

    /// Whether this entry was really signed by the curator.
    public static func verify(_ save: WeeklySave) -> Bool {
        guard let publicKey else { return false }
        return verify(save, publicKey: publicKey)
    }

    /// The same check against an explicit key. The bundled key's private half
    /// isn't in this repository, so this is how the sign→verify algebra gets
    /// tested at all: with a pair the test mints.
    public static func verify(
        _ save: WeeklySave, publicKey: Curve25519.Signing.PublicKey
    ) -> Bool {
        publicKey.isValidSignature(save.signature, for: save.canonicalMessage)
    }

    /// Signs a new entry with the curator's private key.
    public static func sign(
        kind: WeeklySaveKind,
        urlString: String,
        date: Date,
        privateKey: Curve25519.Signing.PrivateKey
    ) throws -> WeeklySave {
        // The date is signed at the precision the canonical formatter prints,
        // so round it there too — otherwise the value we store locally would
        // carry sub-second detail the signature doesn't cover.
        let canonical = WeeklySave.canonicalDateFormatter.string(from: date)
        let signedDate = WeeklySave.canonicalDateFormatter.date(from: canonical) ?? date
        let message = Data(WeeklySave.canonicalMessageString(
            kind: kind, urlString: urlString, date: signedDate).utf8)
        let signature = try privateKey.signature(for: message)
        return WeeklySave(
            kind: kind, urlString: urlString, date: signedDate, signature: signature)
    }

    /// Whether a pasted base64 private key is the counterpart of the bundled
    /// public key — the diagnostics paste's only validation, and the reason a
    /// typo can never leave the app writing records nobody will accept.
    public static func privateKeyMatchesBundledPublicKey(_ base64: String) -> Bool {
        privateKey(fromBase64: base64) != nil
    }

    /// Parses a base64 private key, returning it only when it derives the
    /// bundled public key.
    public static func privateKey(fromBase64 base64: String) -> Curve25519.Signing.PrivateKey? {
        let trimmed = base64.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = Data(base64Encoded: trimmed),
              let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: data),
              let publicKey,
              key.publicKey.rawRepresentation == publicKey.rawRepresentation
        else { return nil }
        return key
    }
}
