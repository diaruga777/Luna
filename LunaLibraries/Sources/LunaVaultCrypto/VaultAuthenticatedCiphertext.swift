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

/// A generation marker obtained from an authenticated envelope. It cannot be
/// fabricated by callers that only have a string; storage accepts this token
/// when installing a remote payload instead of a public override string.
public struct VaultAuthenticatedGeneration: Hashable, Sendable {
    public let objectID: VaultObjectID
    public let revision: UUID
    public let kind: VaultRemoteObjectKind
    public let value: String
    internal init(identity: VaultRemoteObjectIdentity) {
        self.objectID = identity.objectID
        self.revision = identity.revision
        self.kind = identity.kind
        self.value = identity.generation
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
            if Task.isCancelled { throw VaultCryptoError.malformedEnvelope }
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
            guard first.plaintextLength <= UInt64(Int.max) else {
                throw VaultCryptoError.inputTooLarge
            }
            let plaintextLength = Int(first.plaintextLength)
            let (consumed, multiplicationOverflow) = index.multipliedReportingOverflow(by: chunkSize)
            guard !multiplicationOverflow, consumed <= plaintextLength else {
                throw VaultCryptoError.malformedEnvelope
            }
            let remaining = plaintextLength - consumed
            let expected = first.plaintextLength == 0 ? 0 : min(chunkSize, remaining)
            guard envelope.ciphertext.count == expected + 16 else {
                throw VaultCryptoError.malformedEnvelope
            }
        }
        guard first.plaintextLength <= UInt64(Int.max) else {
            throw VaultCryptoError.inputTooLarge
        }
        let divisor = max(1, chunkSize)
        let plaintextLength = Int(first.plaintextLength)
        let quotient = plaintextLength / divisor
        let remainder = plaintextLength % divisor
        let expectedCount = first.plaintextLength == 0
            ? 1
            : quotient + (remainder == 0 ? 0 : 1)
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

    /// Serializes the authenticated frames into the streaming LVF container
    /// used by the Mac companion. This preserves the same fixed header and
    /// length-prefixed frame layout as `VaultAuthenticatedCiphertextFile`
    /// without exposing a pathname or requiring a second encryption pass.
    /// Callers should prefer the file-backed representation for large objects.
    public func encodedFileData() throws -> Data {
        guard encryptedFrames.count >= 2 else { throw VaultCryptoError.malformedEnvelope }
        let first = try VaultChunkEnvelope.decode(
            encryptedFrames[1], maximumBytes: 8_388_608 + VaultChunkEnvelope.headerSize + 16)
        let metadata = FileMetadata(vaultID: vaultID, objectID: identity.objectID,
                                    revision: identity.revision, kind: identity.kind,
                                    rootVersion: rootVersion,
                                    plaintextByteCount: first.plaintextLength,
                                    frameCount: UInt32(encryptedFrames.count),
                                    generation: identity.generation)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let encoded = try encoder.encode(metadata)
        guard encoded.count + 8 <= VaultAuthenticatedCiphertextFile.headerByteCount else {
            throw VaultCryptoError.malformedEnvelope
        }
        var header = Data([0x4c, 0x56, 0x46, 0x31])
        var length = UInt32(encoded.count).bigEndian
        withUnsafeBytes(of: &length) { header.append(contentsOf: $0) }
        header.append(encoded)
        header.append(Data(repeating: 0,
                           count: VaultAuthenticatedCiphertextFile.headerByteCount - header.count))
        var result = header
        for frame in encryptedFrames {
            var frameLength = UInt64(frame.count).bigEndian
            withUnsafeBytes(of: &frameLength) { result.append(contentsOf: $0) }
            result.append(frame)
        }
        return result
    }

    /// Verifies the wrapped DEK and every chunk authentication tag without
    /// retaining the decrypted bytes. Remote downloads must pass this check
    /// before they are installed into a durable local store.
    public func authenticate(rootKey: (UInt32) throws -> VaultRootKey) throws {
        _ = try open(rootKey: rootKey)
    }

    /// Authenticates every envelope and returns the plaintext. Callers that
    /// install a remote content object use this single verification pass both
    /// to establish the capability and to materialize local content.
    public func open(rootKey: (UInt32) throws -> VaultRootKey) throws -> Data {
        let first = try VaultChunkEnvelope.decode(
            encryptedFrames[1],
            maximumBytes: 8_388_608 + VaultChunkEnvelope.headerSize + 16)
        let inferredChunkSize = max(1, first.ciphertext.count - 16)
        return try VaultChunkedCryptor(chunkSize: inferredChunkSize, vaultID: vaultID)
            .open(encryptedFrames, objectID: identity.objectID,
                  revision: identity.revision, role: identity.kind.envelopeRole,
                  rootKey: rootKey)
    }

    /// The only value accepted by an outbound backend write. Construction is
    /// impossible without successfully authenticating the wrapped DEK and all
    /// chunk tags with the Vault root key.
    public func verified(rootKey: (UInt32) throws -> VaultRootKey) throws -> VaultVerifiedCiphertext {
        try authenticate(rootKey: rootKey)
        return VaultVerifiedCiphertext(payload: self)
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
        guard decoded.vaultID == vaultID,
              validated.vaultID == vaultID,
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

    private struct FileMetadata: Codable {
        let vaultID: String
        let objectID: VaultObjectID
        let revision: UUID
        let kind: VaultRemoteObjectKind
        let rootVersion: UInt32
        let plaintextByteCount: UInt64
        let frameCount: UInt32
        let generation: String
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

public struct VaultVerifiedCiphertext: Equatable, Sendable {
    public let payload: VaultAuthenticatedCiphertext

    fileprivate init(payload: VaultAuthenticatedCiphertext) {
        self.payload = payload
    }

    public var identity: VaultRemoteObjectIdentity { payload.identity }
    public var vaultID: String { payload.vaultID }
    public var rootVersion: UInt32 { payload.rootVersion }
    public var encryptedFrames: [Data] { payload.encryptedFrames }
    public var authenticatedGeneration: VaultAuthenticatedGeneration {
        VaultAuthenticatedGeneration(identity: identity)
    }
    public func encoded() throws -> Data { try payload.encoded() }
    public func encodedFileData() throws -> Data { try payload.encodedFileData() }
}
