import CryptoKit
import Foundation
import LunaVaultModels

public enum VaultRemoteObjectKind: String, Codable, CaseIterable, Sendable {
    case content
    case metadata
    case manifest
    case index

    public var envelopeRole: VaultEnvelopeRole {
        switch self {
        case .content: return .content
        case .metadata, .manifest: return .metadata
        case .index: return .index
        }
    }
}

/// Immutable identity for one encrypted remote generation. User-facing names
/// and metadata never participate in remote addressing.
public struct VaultRemoteObjectIdentity: Codable, Hashable, Sendable {
    public let objectID: VaultObjectID
    public let revision: UUID
    public let kind: VaultRemoteObjectKind
    public let generation: String

    public init(objectID: VaultObjectID, revision: UUID,
                kind: VaultRemoteObjectKind, generation: String) throws {
        guard generation.count == 64,
              generation.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else {
            throw VaultCryptoError.malformedEnvelope
        }
        self.objectID = objectID
        self.revision = revision
        self.kind = kind
        self.generation = generation
    }
}

/// A structurally authenticated chunked payload. Construction validates the
/// wrapped DEK header and every AEAD envelope's object, revision, role, root
/// version, chunk ordering and plaintext length. Authentication tags are
/// verified by `VaultChunkedCryptor.open` before plaintext installation.
public struct VaultAuthenticatedCiphertext: Equatable, Sendable {
    public let vaultID: String
    public let identity: VaultRemoteObjectIdentity
    public let rootVersion: UInt32
    public let encryptedFrames: [Data]

    public init(vaultID: String, kind: VaultRemoteObjectKind,
                encryptedFrames: [Data]) throws {
        guard !vaultID.isEmpty, encryptedFrames.count >= 2,
              encryptedFrames[0].count == 113,
              encryptedFrames[0][0] == 1 else {
            throw VaultCryptoError.malformedEnvelope
        }
        let rootVersion = Self.readUInt32(encryptedFrames[0], offset: 1)
        guard rootVersion > 0 else { throw VaultCryptoError.malformedEnvelope }
        let vaultFingerprint = Data(SHA256.hash(data: Data(vaultID.utf8)).prefix(16))
        guard Data(encryptedFrames[0][5..<21]) == vaultFingerprint,
              let wrappedObject = Self.uuid(encryptedFrames[0][21..<37]),
              let wrappedRevision = Self.uuid(encryptedFrames[0][37..<53]) else {
            throw VaultCryptoError.wrongVault
        }
        let objectID = VaultObjectID(rawValue: wrappedObject)
        let first = try VaultChunkEnvelope.decode(
            encryptedFrames[1], maximumBytes: 8_388_608 + VaultChunkEnvelope.headerSize + 16)
        guard first.objectID == objectID, first.revision == wrappedRevision,
              first.rootVersion == rootVersion, first.role == kind.envelopeRole else {
            throw VaultCryptoError.malformedEnvelope
        }
        let chunkSize = first.ciphertext.count - 16
        guard chunkSize >= 0 else { throw VaultCryptoError.malformedEnvelope }
        for (index, frame) in encryptedFrames.dropFirst().enumerated() {
            let envelope = try VaultChunkEnvelope.decode(
                frame, maximumBytes: 8_388_608 + VaultChunkEnvelope.headerSize + 16)
            guard envelope.objectID == objectID,
                  envelope.revision == wrappedRevision,
                  envelope.rootVersion == rootVersion,
                  envelope.role == kind.envelopeRole,
                  envelope.chunkIndex == UInt32(index),
                  envelope.plaintextLength == first.plaintextLength else {
                throw VaultCryptoError.malformedEnvelope
            }
            let expected = first.plaintextLength == 0
                ? 0
                : min(chunkSize, Int(first.plaintextLength) - index * chunkSize)
            guard expected >= 0, envelope.ciphertext.count == expected + 16 else {
                throw VaultCryptoError.malformedEnvelope
            }
        }
        let divisor = max(1, chunkSize)
        let expectedCount = first.plaintextLength == 0
            ? 1
            : (Int(first.plaintextLength) + divisor - 1) / divisor
        guard expectedCount == encryptedFrames.count - 1 else {
            throw VaultCryptoError.malformedEnvelope
        }
        let generation = Self.generation(for: encryptedFrames)
        self.vaultID = vaultID
        self.identity = try VaultRemoteObjectIdentity(
            objectID: objectID, revision: wrappedRevision, kind: kind,
            generation: generation)
        self.rootVersion = rootVersion
        self.encryptedFrames = encryptedFrames
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(Wire(vaultID: vaultID, identity: identity,
                                       rootVersion: rootVersion,
                                       encryptedFrames: encryptedFrames))
    }

    /// Verifies the wrapped DEK and every chunk authentication tag without
    /// retaining the decrypted bytes. Remote downloads must pass this check
    /// before they are installed into a durable local store.
    public func authenticate(rootKey: (UInt32) throws -> VaultRootKey) throws {
        let first = try VaultChunkEnvelope.decode(
            encryptedFrames[1],
            maximumBytes: 8_388_608 + VaultChunkEnvelope.headerSize + 16)
        let inferredChunkSize = max(1, first.ciphertext.count - 16)
        _ = try VaultChunkedCryptor(chunkSize: inferredChunkSize, vaultID: vaultID)
            .open(encryptedFrames, objectID: identity.objectID,
                  revision: identity.revision, role: identity.kind.envelopeRole,
                  rootKey: rootKey)
    }

    public static func decodeAndValidate(_ data: Data,
                                         expected: VaultRemoteObjectIdentity,
                                         vaultID: String) throws -> VaultAuthenticatedCiphertext {
        guard data.count <= Int(VaultChunkedCryptor.maximumObjectBytes),
              let decoded = try? JSONDecoder().decode(Wire.self, from: data) else {
            throw VaultCryptoError.malformedEnvelope
        }
        let validated = try VaultAuthenticatedCiphertext(
            vaultID: vaultID, kind: expected.kind,
            encryptedFrames: decoded.encryptedFrames)
        guard validated.vaultID == vaultID,
              validated.identity == expected,
              decoded.identity == expected,
              decoded.rootVersion == validated.rootVersion else {
            throw VaultCryptoError.malformedEnvelope
        }
        return validated
    }

    private static func generation(for frames: [Data]) -> String {
        var digestInput = Data()
        for frame in frames {
            var length = UInt64(frame.count).bigEndian
            withUnsafeBytes(of: &length) { digestInput.append(contentsOf: $0) }
            digestInput.append(frame)
        }
        return SHA256.hash(data: digestInput).map { String(format: "%02x", $0) }.joined()
    }

    private struct Wire: Codable {
        let vaultID: String
        let identity: VaultRemoteObjectIdentity
        let rootVersion: UInt32
        let encryptedFrames: [Data]
    }

    private static func readUInt32(_ data: Data, offset: Int) -> UInt32 {
        data[offset..<(offset + 4)].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    private static func uuid(_ bytes: Data.SubSequence) -> UUID? {
        guard bytes.count == 16 else { return nil }
        let values = Array(bytes)
        return UUID(uuid: (values[0], values[1], values[2], values[3],
                           values[4], values[5], values[6], values[7],
                           values[8], values[9], values[10], values[11],
                           values[12], values[13], values[14], values[15]))
    }
}
