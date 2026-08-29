import CryptoKit
import Foundation
import LunaVaultModels

/// A file-backed authenticated ciphertext envelope.  Unlike
/// `VaultAuthenticatedCiphertext`, this value never owns the encrypted
/// frames; it owns only an opaque URL and bounded header metadata.  The file
/// format is private to the Vault transport and is deliberately not JSON so a
/// 100-GB object cannot be expanded into one `Data` value by Codable/base64.
public struct VaultAuthenticatedCiphertextFile: Equatable, Sendable {
    public static let headerByteCount = 4_096
    public static let maximumHeaderBytes = 4_096

    public let fileURL: URL
    public let vaultID: String
    public let identity: VaultRemoteObjectIdentity
    public let rootVersion: UInt32
    public let plaintextByteCount: UInt64
    public let frameCount: UInt32
    public let ciphertextByteCount: UInt64

    public init(fileURL: URL, expectedIdentity: VaultRemoteObjectIdentity? = nil,
                vaultID: String) throws {
        let metadata = try Self.readMetadata(fileURL)
        guard metadata.vaultID == vaultID,
              metadata.rootVersion > 0,
              metadata.plaintextByteCount <= VaultChunkedCryptor.maximumObjectBytes,
              metadata.frameCount >= 2,
              metadata.frameCount <= UInt32.max else {
            throw VaultCryptoError.malformedEnvelope
        }
        let identity = try VaultRemoteObjectIdentity(
            objectID: metadata.objectID, revision: metadata.revision,
            kind: metadata.kind, generation: metadata.generation)
        if let expectedIdentity, expectedIdentity != identity {
            throw VaultCryptoError.malformedEnvelope
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        guard (attributes[.type] as? FileAttributeType) == .typeRegular,
              let fileSize = (attributes[.size] as? NSNumber)?.uint64Value,
              fileSize >= UInt64(Self.headerByteCount) else {
            throw VaultCryptoError.malformedEnvelope
        }

        var offset = UInt64(Self.headerByteCount)
        var digest = Data()
        var frameBytes: UInt64 = 0
        var previousLength: UInt64?
        var chunkSize: UInt64?
        for index in 0..<metadata.frameCount {
            let (length, frameOffset) = try Self.readFrameLength(fileURL, offset: offset)
            guard length >= UInt64(VaultChunkEnvelope.headerSize + 16),
                  length <= UInt64(8_388_608 + VaultChunkEnvelope.headerSize + 16),
                  offset <= UInt64.max - 8 - length,
                  frameOffset + length <= fileSize else {
                throw VaultCryptoError.malformedEnvelope
            }
            // Each encrypted frame is bounded independently.  The digest
            // matches the in-memory generation algorithm without retaining
            // the object or even two full frames at once.
            let frame = try Self.readBytes(fileURL, offset: frameOffset, count: Int(length))
            if index == 0 {
                guard frame.count == 113, frame[0] == 1,
                      Self.readUInt32(frame, offset: 1) == metadata.rootVersion,
                      Data(frame[5..<21]) == Data(SHA256.hash(data: Data(vaultID.utf8)).prefix(16)),
                      Data(frame[21..<37]) == identity.objectID.rawValue.uuidData,
                      Data(frame[37..<53]) == identity.revision.uuidData else {
                    throw VaultCryptoError.malformedEnvelope
                }
            } else {
                let envelope = try VaultChunkEnvelope.decode(
                    frame, maximumBytes: 8_388_608 + VaultChunkEnvelope.headerSize + 16)
                guard envelope.objectID == identity.objectID,
                      envelope.revision == identity.revision,
                      envelope.rootVersion == metadata.rootVersion,
                      envelope.role == identity.kind.envelopeRole else {
                    throw VaultCryptoError.malformedEnvelope
                }
                guard envelope.chunkIndex == index - 1,
                      envelope.plaintextLength == metadata.plaintextByteCount else {
                    throw VaultCryptoError.malformedEnvelope
                }
                if index == 1 {
                    chunkSize = UInt64(envelope.ciphertext.count - 16)
                }
                let actualChunkSize = chunkSize ?? 0
                let expected = metadata.plaintextByteCount == 0
                    ? 0
                    : min(actualChunkSize, metadata.plaintextByteCount - UInt64(index - 1) * actualChunkSize)
                guard actualChunkSize > 0 || metadata.plaintextByteCount == 0,
                      UInt64(envelope.ciphertext.count - 16) == expected else {
                    throw VaultCryptoError.malformedEnvelope
                }
            }
            var lengthBE = length.bigEndian
            withUnsafeBytes(of: &lengthBE) { digest.append(contentsOf: $0) }
            digest.append(frame)
            frameBytes = try Self.checkedAdd(frameBytes, 8 + length)
            previousLength = length
            offset = try Self.checkedAdd(frameOffset, length)
        }
        guard metadata.frameCount == 1 || metadata.plaintextByteCount > 0,
              offset == fileSize,
              Self.generation(digest) == metadata.generation,
              frameBytes == fileSize - UInt64(Self.headerByteCount) else {
            throw VaultCryptoError.malformedEnvelope
        }
        // Silence the intentional local used to make validation obvious in
        // crash logs when inspecting a corrupt frame file.
        _ = previousLength
        self.fileURL = fileURL
        self.vaultID = vaultID
        self.identity = identity
        self.rootVersion = metadata.rootVersion
        self.plaintextByteCount = metadata.plaintextByteCount
        self.frameCount = metadata.frameCount
        self.ciphertextByteCount = frameBytes
    }

    /// Streams plaintext into a destination after authenticating every frame.
    /// The destination is never installed by this method; callers apply their
    /// storage protection and atomically rename only after this returns.
    @discardableResult
    public func decrypt(to destinationURL: URL,
                        rootKey: (UInt32) throws -> VaultRootKey) throws -> UInt64 {
        let cryptor = VaultChunkedCryptor(
            chunkSize: Self.inferredChunkSize(fileURL: fileURL, frameCount: frameCount,
                                               plaintextByteCount: plaintextByteCount),
            vaultID: vaultID)
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            let attrs = try FileManager.default.attributesOfItem(atPath: destinationURL.path)
            guard (attrs[.type] as? FileAttributeType) == .typeRegular,
                  (attrs[.size] as? NSNumber)?.int64Value == 0 else {
                throw VaultCryptoError.malformedEnvelope
            }
        } else if !FileManager.default.createFile(atPath: destinationURL.path, contents: nil) {
            throw VaultCryptoError.malformedEnvelope
        }
        do {
            let output = try FileHandle(forWritingTo: destinationURL)
            defer { try? output.close() }
            let wrapped = try frame(at: 0)
            var written: UInt64 = 0
            if plaintextByteCount == 0 {
                _ = try cryptor.openFrame(wrapped, frame: try frame(at: 1),
                    objectID: identity.objectID, revision: identity.revision,
                    role: identity.kind.envelopeRole, chunkIndex: 0,
                    plaintextLength: 0, rootKey: rootKey)
            } else {
                for index in 0..<(frameCount - 1) {
                    let plaintext = try cryptor.openFrame(wrapped, frame: try frame(at: index + 1),
                        objectID: identity.objectID, revision: identity.revision,
                        role: identity.kind.envelopeRole, chunkIndex: index,
                        plaintextLength: plaintextByteCount, rootKey: rootKey)
                    try output.write(contentsOf: plaintext)
                    written = try Self.checkedAdd(written, UInt64(plaintext.count))
                }
            }
            try output.synchronize()
            guard written == plaintextByteCount else { throw VaultCryptoError.invalidLength }
            return written
        } catch {
            try? FileManager.default.removeItem(at: destinationURL)
            throw error
        }
    }

    public func authenticate(rootKey: (UInt32) throws -> VaultRootKey) throws {
        let cryptor = VaultChunkedCryptor(
            chunkSize: Self.inferredChunkSize(fileURL: fileURL, frameCount: frameCount,
                                               plaintextByteCount: plaintextByteCount),
            vaultID: vaultID)
        let wrapped = try frame(at: 0)
        if plaintextByteCount == 0 {
            _ = try cryptor.openFrame(wrapped, frame: try frame(at: 1),
                objectID: identity.objectID, revision: identity.revision,
                role: identity.kind.envelopeRole, chunkIndex: 0,
                plaintextLength: 0, rootKey: rootKey)
        } else {
            for index in 0..<(frameCount - 1) {
                _ = try cryptor.openFrame(wrapped, frame: try frame(at: index + 1),
                    objectID: identity.objectID, revision: identity.revision,
                    role: identity.kind.envelopeRole, chunkIndex: index,
                    plaintextLength: plaintextByteCount, rootKey: rootKey)
            }
        }
    }

    public func verified(rootKey: (UInt32) throws -> VaultRootKey) throws -> VaultVerifiedCiphertextFile {
        try authenticate(rootKey: rootKey)
        return VaultVerifiedCiphertextFile(payload: self)
    }

    /// Reads exactly one bounded frame. It is the only frame accessor exposed
    /// to network transports, making accidental whole-object reads difficult.
    public func frame(at index: UInt32) throws -> Data {
        guard index < frameCount else { throw VaultCryptoError.invalidRange }
        var offset = UInt64(Self.headerByteCount)
        for _ in 0..<index {
            let (length, frameOffset) = try Self.readFrameLength(fileURL, offset: offset)
            offset = try Self.checkedAdd(frameOffset, length)
        }
        let (length, frameOffset) = try Self.readFrameLength(fileURL, offset: offset)
        guard length <= UInt64(Int.max) else { throw VaultCryptoError.inputTooLarge }
        return try Self.readBytes(fileURL, offset: frameOffset, count: Int(length))
    }

    public static func seal(plaintextURL: URL, fileURL: URL,
                            vaultID: String, kind: VaultRemoteObjectKind,
                            objectID: VaultObjectID, revision: UUID,
                            root: VaultRootKey, chunkSize: Int = 1_048_576,
                            random: VaultRandomBytesGenerating = SystemVaultRandomBytes()) throws
        -> VaultAuthenticatedCiphertextFile {
        let cryptor = VaultChunkedCryptor(chunkSize: chunkSize, vaultID: vaultID, random: random)
        try cryptor.sealFile(plaintextURL: plaintextURL, fileURL: fileURL,
                             kind: kind, objectID: objectID, revision: revision, root: root)
        return try Self(fileURL: fileURL, vaultID: vaultID)
    }

    fileprivate struct Metadata: Codable {
        let vaultID: String
        let objectID: VaultObjectID
        let revision: UUID
        let kind: VaultRemoteObjectKind
        let rootVersion: UInt32
        let plaintextByteCount: UInt64
        let frameCount: UInt32
        let generation: String
    }

    static func writePlaceholder(to fileURL: URL) throws -> FileHandle {
        guard FileManager.default.createFile(atPath: fileURL.path, contents: nil) else {
            throw VaultCryptoError.malformedEnvelope
        }
        let handle = try FileHandle(forWritingTo: fileURL)
        try handle.write(contentsOf: Data(repeating: 0, count: headerByteCount))
        return handle
    }

    static func writeFrame(_ frame: Data, to handle: FileHandle) throws {
        guard frame.count <= 8_388_608 + VaultChunkEnvelope.headerSize + 16 else {
            throw VaultCryptoError.malformedEnvelope
        }
        var length = UInt64(frame.count).bigEndian
        try withUnsafeBytes(of: &length) { try handle.write(contentsOf: Data($0)) }
        try handle.write(contentsOf: frame)
    }

    fileprivate static func rewriteHeader(_ metadata: Metadata, at fileURL: URL) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let encoded = try encoder.encode(metadata)
        guard encoded.count + 8 <= headerByteCount else { throw VaultCryptoError.malformedEnvelope }
        let handle = try FileHandle(forUpdating: fileURL)
        defer { try? handle.close() }
        try handle.seek(toOffset: 0)
        var header = Data([0x4c, 0x56, 0x46, 0x31])
        var length = UInt32(encoded.count).bigEndian
        withUnsafeBytes(of: &length) { header.append(contentsOf: $0) }
        header.append(encoded)
        header.append(Data(repeating: 0, count: headerByteCount - header.count))
        try handle.write(contentsOf: header)
        try handle.synchronize()
    }

    fileprivate static func readMetadata(_ fileURL: URL) throws -> Metadata {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        guard let header = try handle.read(upToCount: headerByteCount),
              header.count == headerByteCount,
              header.prefix(4).elementsEqual([0x4c, 0x56, 0x46, 0x31]) else {
            throw VaultCryptoError.malformedEnvelope
        }
        let length = UInt32(header[4..<8].reduce(0) { ($0 << 8) | UInt32($1) })
        guard length > 0, length <= headerByteCount - 8 else { throw VaultCryptoError.malformedEnvelope }
        return try JSONDecoder().decode(Metadata.self, from: Data(header[8..<(8 + Int(length))]))
    }

    private static func readFrameLength(_ fileURL: URL, offset: UInt64) throws -> (UInt64, UInt64) {
        let bytes = try readBytes(fileURL, offset: offset, count: 8)
        let length = bytes.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        return (length, try checkedAdd(offset, 8))
    }

    private static func readBytes(_ fileURL: URL, offset: UInt64, count: Int) throws -> Data {
        guard offset <= UInt64(Int64.max), count >= 0 else { throw VaultCryptoError.invalidRange }
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        try handle.seek(toOffset: offset)
        guard let data = try handle.read(upToCount: count), data.count == count else {
            throw VaultCryptoError.malformedEnvelope
        }
        return data
    }

    private static func inferredChunkSize(fileURL: URL, frameCount: UInt32,
                                          plaintextByteCount: UInt64) -> Int {
        // The first chunk's authenticated length is authoritative. Read and
        // decode it; this remains a single bounded frame read.
        if let (length, offset) = try? readFrameLength(fileURL, offset: UInt64(headerByteCount)),
           let bytes = try? readBytes(fileURL, offset: offset, count: Int(length)),
           let envelope = try? VaultChunkEnvelope.decode(bytes,
               maximumBytes: 8_388_608 + VaultChunkEnvelope.headerSize + 16) {
            return max(1, envelope.ciphertext.count - 16)
        }
        return Int(min(8_388_608, max(1, plaintextByteCount)))
    }

    private static func generation(_ input: Data) -> String {
        SHA256.hash(data: input).map { String(format: "%02x", $0) }.joined()
    }

    private static func readUInt32(_ data: Data, offset: Int) -> UInt32 {
        data[offset..<(offset + 4)].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    private static func checkedAdd(_ lhs: UInt64, _ rhs: UInt64) throws -> UInt64 {
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        guard !overflow else { throw VaultCryptoError.inputTooLarge }
        return value
    }
}

public struct VaultVerifiedCiphertextFile: Equatable, Sendable {
    public let payload: VaultAuthenticatedCiphertextFile
    fileprivate init(payload: VaultAuthenticatedCiphertextFile) { self.payload = payload }
    public var fileURL: URL { payload.fileURL }
    public var vaultID: String { payload.vaultID }
    public var identity: VaultRemoteObjectIdentity { payload.identity }
    public var rootVersion: UInt32 { payload.rootVersion }
    public var ciphertextByteCount: UInt64 { payload.ciphertextByteCount }
    public var plaintextByteCount: UInt64 { payload.plaintextByteCount }
    public var frameCount: UInt32 { payload.frameCount }
    public func frame(at index: UInt32) throws -> Data { try payload.frame(at: index) }
}

public extension VaultChunkedCryptor {
    /// Streams a plaintext regular file into the bounded frame-file format.
    /// The source descriptor is held open throughout the copy, so replacing
    /// the source pathname cannot switch bytes midway through sealing.
    func sealFile(plaintextURL: URL, fileURL: URL, kind: VaultRemoteObjectKind,
                  objectID: VaultObjectID, revision: UUID, root: VaultRootKey) throws {
        let attrs = try FileManager.default.attributesOfItem(atPath: plaintextURL.path)
        guard (attrs[.type] as? FileAttributeType) == .typeRegular,
              let size = (attrs[.size] as? NSNumber)?.uint64Value,
              size <= Self.maximumObjectBytes else { throw VaultCryptoError.inputTooLarge }
        let source = try FileHandle(forReadingFrom: plaintextURL)
        let output = try VaultAuthenticatedCiphertextFile.writePlaceholder(to: fileURL)
        defer { try? source.close(); try? output.close() }
        var digest = Data()
        var frameCount: UInt32 = 0
        func appendFrame(_ frame: Data) throws {
            try VaultAuthenticatedCiphertextFile.writeFrame(frame, to: output)
            var length = UInt64(frame.count).bigEndian
            withUnsafeBytes(of: &length) { digest.append(contentsOf: $0) }
            digest.append(frame)
            guard frameCount < UInt32.max else { throw VaultCryptoError.tooManyChunks }
            frameCount += 1
        }
        let dek = try random.bytes(count: 32)
        guard dek.count == 32 else { throw VaultCryptoError.invalidLength }
        try appendFrame(try wrap(dek, root, objectID, revision, try randomNonce()))
        let key = SymmetricKey(data: dek)
        var remaining = size
        var index: UInt32 = 0
        while remaining > 0 || (size == 0 && index == 0) {
            let count = size == 0 ? 0 : Int(min(UInt64(chunkSize), remaining))
            let bytes: Data
            if count == 0 { bytes = Data() }
            else {
                guard let read = try source.read(upToCount: count), read.count == count else {
                    throw VaultCryptoError.invalidLength
                }
                bytes = read
            }
            let nonce = try randomNonce()
            let aad = associatedData(kind.envelopeRole, root.version, objectID, revision,
                                     index, size)
            let box = try AES.GCM.seal(bytes, using: key,
                                       nonce: try AES.GCM.Nonce(data: nonce), authenticating: aad)
            try appendFrame(try VaultChunkEnvelope(role: kind.envelopeRole,
                rootVersion: root.version, objectID: objectID, revision: revision,
                chunkIndex: index, plaintextLength: size, nonce: nonce,
                ciphertext: box.ciphertext + box.tag).encoded())
            if size > 0 { remaining -= UInt64(count) }
            index += 1
            if size == 0 { break }
        }
        guard try source.read(upToCount: 1)?.isEmpty != false else { throw VaultCryptoError.invalidLength }
        try output.synchronize()
        let metadata = VaultAuthenticatedCiphertextFile.Metadata(
            vaultID: vaultID, objectID: objectID, revision: revision, kind: kind,
            rootVersion: root.version, plaintextByteCount: size,
            frameCount: frameCount, generation: SHA256.hash(data: digest)
                .map { String(format: "%02x", $0) }.joined())
        try VaultAuthenticatedCiphertextFile.rewriteHeader(metadata, at: fileURL)
    }

    private func randomNonce() throws -> Data {
        let nonce = try random.bytes(count: 12)
        guard nonce.count == 12 else { throw VaultCryptoError.invalidLength }
        return nonce
    }
}
