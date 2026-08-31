import CryptoKit
import Foundation
import LunaVaultModels
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// A file-backed authenticated ciphertext envelope.  Unlike
/// `VaultAuthenticatedCiphertext`, this value never owns the encrypted
/// frames; it owns only an opaque URL and bounded header metadata.  The file
/// format is private to the Vault transport and is deliberately not JSON so a
/// 100-GB object cannot be expanded into one `Data` value by Codable/base64.
public struct VaultAuthenticatedCiphertextFile: Equatable, Sendable {
    public static let headerByteCount = 4_096

    public let fileURL: URL
    public let vaultID: String
    public let identity: VaultRemoteObjectIdentity
    public let rootVersion: UInt32
    public let plaintextByteCount: UInt64
    public let frameCount: UInt32
    public let ciphertextByteCount: UInt64
    /// True only for a transport-created temporary whose caller must remove it.
    public let ownsFile: Bool
    /// The descriptor is deliberately retained for the lifetime of the
    /// capability.  The pathname is only an installation/removal handle;
    /// validation, authentication, decryption, and transport reads all use
    /// this immutable inode handle so a replacement of `fileURL` cannot
    /// switch the bytes after validation.
    private let stableFile: StableReadFile
    /// Start-of-length-prefix offset for every frame, recorded during the one
    /// validation walk so `frame(at:)` never re-walks preceding frames.
    private let frameOffsets: [UInt64]

    public init(fileURL: URL, expectedIdentity: VaultRemoteObjectIdentity? = nil,
                vaultID: String, ownsFile: Bool = false) throws {
        let stableFile = try Self.openStableReadOnly(fileURL)
        let metadata = try Self.readMetadata(stableFile)
        guard metadata.vaultID == vaultID,
              metadata.rootVersion > 0,
              metadata.plaintextByteCount <= VaultChunkedCryptor.maximumObjectBytes,
              metadata.frameCount >= 2 else {
            throw VaultCryptoError.malformedEnvelope
        }
        let identity = try VaultRemoteObjectIdentity(
            objectID: metadata.objectID, revision: metadata.revision,
            kind: metadata.kind, generation: metadata.generation)
        if let expectedIdentity, expectedIdentity != identity {
            throw VaultCryptoError.malformedEnvelope
        }
        let fileSize = stableFile.fileSize
        guard fileSize >= UInt64(Self.headerByteCount) else {
            throw VaultCryptoError.malformedEnvelope
        }

        var offset = UInt64(Self.headerByteCount)
        var digest = SHA256()
        var frameBytes: UInt64 = 0
        var chunkSize: UInt64?
        var frameStarts: [UInt64] = []
        frameStarts.reserveCapacity(Int(metadata.frameCount))
        for index in 0..<metadata.frameCount {
            if Task.isCancelled { throw VaultCryptoError.malformedEnvelope }
            frameStarts.append(offset)
            let (length, frameOffset) = try Self.readFrameLength(stableFile, offset: offset)
            guard length >= UInt64(VaultChunkEnvelope.headerSize + 16),
                  length <= UInt64(8_388_608 + VaultChunkEnvelope.headerSize + 16),
                  offset <= UInt64.max - 8 - length,
                  frameOffset + length <= fileSize else {
                throw VaultCryptoError.malformedEnvelope
            }
            // Each encrypted frame is bounded independently.  The digest
            // matches the in-memory generation algorithm without retaining
            // the object or even two full frames at once.
            let frame = try Self.readBytes(stableFile, offset: frameOffset, count: Int(length))
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
                let chunkIndex = UInt64(index - 1)
                let (consumed, multiplicationOverflow) = chunkIndex.multipliedReportingOverflow(by: actualChunkSize)
                guard !multiplicationOverflow, consumed <= metadata.plaintextByteCount else {
                    throw VaultCryptoError.malformedEnvelope
                }
                let remaining = metadata.plaintextByteCount - consumed
                let expected = metadata.plaintextByteCount == 0 ? 0 : min(actualChunkSize, remaining)
                guard actualChunkSize > 0 || metadata.plaintextByteCount == 0,
                      UInt64(envelope.ciphertext.count - 16) == expected else {
                    throw VaultCryptoError.malformedEnvelope
                }
            }
            var lengthBE = length.bigEndian
            withUnsafeBytes(of: &lengthBE) { digest.update(data: Data($0)) }
            digest.update(data: frame)
            frameBytes = try Self.checkedAdd(frameBytes, 8 + length)
            offset = try Self.checkedAdd(frameOffset, length)
        }
        guard offset == fileSize,
              // The file format has exactly one wrapped-DEK frame followed by
              // the canonical number of plaintext chunks.  In particular an
              // empty plaintext has one (empty) chunk, not an arbitrary run of
              // additional valid empty frames.  Keeping this check identical
              // to VaultAuthenticatedCiphertext's in-memory parser prevents
              // a trailing frame from becoming an unauthenticated extension
              // of an otherwise valid LVF.
              chunkSize.map({
                  let divisor = max(UInt64(1), $0)
                  let chunks = metadata.plaintextByteCount == 0
                      ? UInt64(1)
                      : (metadata.plaintextByteCount + divisor - 1) / divisor
                  return metadata.frameCount == chunks + 1
              }) == true,
              Self.generation(digest) == metadata.generation,
              frameBytes == fileSize - UInt64(Self.headerByteCount) else {
            throw VaultCryptoError.malformedEnvelope
        }
        self.fileURL = fileURL
        self.vaultID = vaultID
        self.identity = identity
        self.rootVersion = metadata.rootVersion
        self.plaintextByteCount = metadata.plaintextByteCount
        self.frameCount = metadata.frameCount
        // Transport callers copy the complete LVF, including its authenticated
        // fixed-size header. `frameBytes` above remains the integrity check for
        // the encrypted frame region, while this count is the source file size.
        self.ciphertextByteCount = fileSize
        self.ownsFile = ownsFile
        self.stableFile = stableFile
        self.frameOffsets = frameStarts
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.fileURL == rhs.fileURL && lhs.vaultID == rhs.vaultID &&
        lhs.identity == rhs.identity && lhs.rootVersion == rhs.rootVersion &&
        lhs.plaintextByteCount == rhs.plaintextByteCount &&
        lhs.frameCount == rhs.frameCount && lhs.ciphertextByteCount == rhs.ciphertextByteCount &&
        lhs.ownsFile == rhs.ownsFile
    }

    /// Streams plaintext into a destination after authenticating every frame.
    /// The destination is never installed by this method; callers apply their
    /// storage protection and atomically rename only after this returns.
    @discardableResult
    public func decrypt(to destinationURL: URL,
                        rootKey: (UInt32) throws -> VaultRootKey) throws -> UInt64 {
        let cryptor = VaultChunkedCryptor(
            chunkSize: Self.inferredChunkSize(handle: stableFile, frameCount: frameCount,
                                               plaintextByteCount: plaintextByteCount),
            vaultID: vaultID)
        let (output, createdDestination) = try Self.openOrCreateAnchoredWriter(destinationURL.path)
        do {
            defer { try? output.close() }
            let wrapped = try frame(at: 0, handle: stableFile)
            var written: UInt64 = 0
            if plaintextByteCount == 0 {
                _ = try cryptor.openFrame(wrapped, frame: try frame(at: 1, handle: stableFile),
                    objectID: identity.objectID, revision: identity.revision,
                    role: identity.kind.envelopeRole, chunkIndex: 0,
                    plaintextLength: 0, rootKey: rootKey)
            } else {
                for index in 0..<(frameCount - 1) {
                    if Task.isCancelled { throw VaultCryptoError.invalidLength }
                    let plaintext = try cryptor.openFrame(wrapped, frame: try frame(at: index + 1, handle: stableFile),
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
            if createdDestination { try? Self.removeAnchoredFile(destinationURL.path) }
            throw error
        }
    }

    public func authenticate(rootKey: (UInt32) throws -> VaultRootKey) throws {
        let cryptor = VaultChunkedCryptor(
            chunkSize: Self.inferredChunkSize(handle: stableFile, frameCount: frameCount,
                                               plaintextByteCount: plaintextByteCount),
            vaultID: vaultID)
        let wrapped = try frame(at: 0, handle: stableFile)
        if plaintextByteCount == 0 {
            _ = try cryptor.openFrame(wrapped, frame: try frame(at: 1, handle: stableFile),
                objectID: identity.objectID, revision: identity.revision,
                role: identity.kind.envelopeRole, chunkIndex: 0,
                plaintextLength: 0, rootKey: rootKey)
        } else {
            for index in 0..<(frameCount - 1) {
                if Task.isCancelled { throw VaultCryptoError.invalidLength }
                _ = try cryptor.openFrame(wrapped, frame: try frame(at: index + 1, handle: stableFile),
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

    /// The returned file is a temporary transport artifact owned by the
    /// caller. Remove it after the consumer has finished reading it.
    public func removeOwnedFile() throws {
        guard ownsFile else { return }
        try FileManager.default.removeItem(at: fileURL)
    }

    /// Reads exactly one bounded frame. It is the only frame accessor exposed
    /// to network transports, making accidental whole-object reads difficult.
    public func frame(at index: UInt32) throws -> Data {
        return try frame(at: index, handle: stableFile)
    }

    /// Reads a bounded ciphertext range from the descriptor that was
    /// authenticated at initialization.  This is used by streaming backends
    /// and never reopens the public URL.
    public func read(offset: UInt64, count: Int) throws -> Data {
        try stableFile.read(offset: offset, count: count)
    }

    /// Computes the digest of the exact authenticated inode, without a second
    /// pathname lookup.  Uploaders use this before and after their chunk loop.
    public func digest() throws -> String {
        Self.hex(try digestBytes())
    }

    public func digestBytes() throws -> Data {
        var hasher = SHA256()
        var offset: UInt64 = 0
        while offset < stableFile.fileSize {
            if Task.isCancelled { throw VaultCryptoError.invalidLength }
            let count = Int(min(UInt64(1_048_576), stableFile.fileSize - offset))
            hasher.update(data: try stableFile.read(offset: offset, count: count))
            offset = try Self.checkedAdd(offset, UInt64(count))
        }
        return Data(hasher.finalize())
    }

    public func writeCopy(to destinationURL: URL) throws -> UInt64 {
        guard destinationURL.isFileURL else { throw VaultCryptoError.invalidRange }
        let output = try Self.createAnchoredWriter(destinationURL.path)
        do {
            defer { try? output.close() }
            var offset: UInt64 = 0
            while offset < stableFile.fileSize {
                if Task.isCancelled { throw VaultCryptoError.invalidLength }
                let count = Int(min(UInt64(1_048_576), stableFile.fileSize - offset))
                try output.write(contentsOf: stableFile.read(offset: offset, count: count))
                offset = try Self.checkedAdd(offset, UInt64(count))
            }
            try output.synchronize()
            return offset
        } catch {
            try? Self.removeAnchoredFile(destinationURL.path)
            throw error
        }
    }

    private func frame(at index: UInt32, handle: StableReadFile) throws -> Data {
        guard index < frameCount, Int(index) < frameOffsets.count else {
            throw VaultCryptoError.invalidRange
        }
        let (length, frameOffset) = try Self.readFrameLength(handle, offset: frameOffsets[Int(index)])
        guard length <= UInt64(8_388_608 + VaultChunkEnvelope.headerSize + 16) else {
            throw VaultCryptoError.malformedEnvelope
        }
        return try Self.readBytes(handle, offset: frameOffset, count: Int(length))
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

    /// Seals bytes from an already-open regular-file descriptor.  The caller
    /// retains ownership of `plaintextHandle`; this method only advances its
    /// cursor while preserving the descriptor's inode binding.
    public static func seal(plaintextHandle: FileHandle, plaintextByteCount: UInt64,
                            fileURL: URL, vaultID: String, kind: VaultRemoteObjectKind,
                            objectID: VaultObjectID, revision: UUID,
                            root: VaultRootKey, chunkSize: Int = 1_048_576,
                            random: VaultRandomBytesGenerating = SystemVaultRandomBytes()) throws
        -> VaultAuthenticatedCiphertextFile {
        let cryptor = VaultChunkedCryptor(chunkSize: chunkSize, vaultID: vaultID, random: random)
        try cryptor.sealFile(plaintextHandle: plaintextHandle,
                             plaintextByteCount: plaintextByteCount, fileURL: fileURL,
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
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: fileURL.path) {
            let attributes = try fileManager.attributesOfItem(atPath: fileURL.path)
            guard (attributes[.type] as? FileAttributeType) == .typeRegular,
                  (attributes[.size] as? NSNumber)?.int64Value == 0 else {
                throw VaultCryptoError.malformedEnvelope
            }
        } else if !fileManager.createFile(atPath: fileURL.path, contents: nil) {
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

    fileprivate static func readMetadata(_ handle: StableReadFile) throws -> Metadata {
        let header = try handle.read(offset: 0, count: headerByteCount)
        guard header.count == headerByteCount,
              header.prefix(4).elementsEqual([0x4c, 0x56, 0x46, 0x31]) else {
            throw VaultCryptoError.malformedEnvelope
        }
        let length = UInt32(header[4..<8].reduce(0) { ($0 << 8) | UInt32($1) })
        guard length > 0, length <= headerByteCount - 8 else { throw VaultCryptoError.malformedEnvelope }
        return try JSONDecoder().decode(Metadata.self, from: Data(header[8..<(8 + Int(length))]))
    }

    private static func readFrameLength(_ handle: StableReadFile, offset: UInt64) throws -> (UInt64, UInt64) {
        let bytes = try readBytes(handle, offset: offset, count: 8)
        let length = bytes.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        return (length, try checkedAdd(offset, 8))
    }

    private static func readBytes(_ handle: StableReadFile, offset: UInt64, count: Int) throws -> Data {
        guard offset <= UInt64(Int64.max), count >= 0 else { throw VaultCryptoError.invalidRange }
        return try handle.read(offset: offset, count: count)
    }

    private static func inferredChunkSize(handle: StableReadFile, frameCount: UInt32,
                                          plaintextByteCount: UInt64) -> Int {
        // The first chunk's authenticated length is authoritative. Read and
        // decode it; this remains a single bounded frame read.
        if let (length, offset) = try? readFrameLength(handle, offset: UInt64(headerByteCount)),
           let bytes = try? readBytes(handle, offset: offset, count: Int(length)),
           let envelope = try? VaultChunkEnvelope.decode(bytes,
               maximumBytes: 8_388_608 + VaultChunkEnvelope.headerSize + 16) {
            return max(1, envelope.ciphertext.count - 16)
        }
        return Int(min(8_388_608, max(1, plaintextByteCount)))
    }

    private static func generation(_ input: SHA256) -> String {
        input.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    private static func readUInt32(_ data: Data, offset: Int) -> UInt32 {
        data[offset..<(offset + 4)].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    private static func checkedAdd(_ lhs: UInt64, _ rhs: UInt64) throws -> UInt64 {
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        guard !overflow else { throw VaultCryptoError.inputTooLarge }
        return value
    }

    fileprivate static func openStableReadOnly(_ fileURL: URL) throws -> StableReadFile {
        guard fileURL.isFileURL else {
            throw VaultCryptoError.malformedEnvelope
        }
        let descriptor = try openAnchoredRegularFile(fileURL.path)
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            close(descriptor)
            throw VaultCryptoError.malformedEnvelope
        }
        return try StableReadFile(descriptor: descriptor, fileSize: UInt64(info.st_size))
    }

    /// Resolves each path component from an already-open directory descriptor.
    /// Checking the complete string with lstat followed by open is racy: an
    /// attacker can replace an intermediate directory between those calls.
    /// `openat(..., O_NOFOLLOW)` makes every component decision atomic.
    private static func openAnchoredRegularFile(_ path: String) throws -> Int32 {
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        guard !components.isEmpty, !components.contains("."), !components.contains("..") else {
            throw VaultCryptoError.malformedEnvelope
        }
        var directory = open(path.hasPrefix("/") ? "/" : ".",
                             O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard directory >= 0 else { throw VaultCryptoError.malformedEnvelope }
        for component in components.dropLast() {
            let next = component.withCString {
                openat(directory, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            }
            guard next >= 0 else {
                close(directory)
                throw VaultCryptoError.malformedEnvelope
            }
            close(directory)
            directory = next
        }
        let descriptor = components.last!.withCString {
            openat(directory, $0, O_RDONLY | O_NOFOLLOW)
        }
        close(directory)
        guard descriptor >= 0 else { throw VaultCryptoError.malformedEnvelope }
        return descriptor
    }

    fileprivate final class StableReadFile: @unchecked Sendable {
        let descriptor: Int32
        let fileSize: UInt64
        private let cursorLock = NSLock()
        private var cursor: UInt64 = 0

        init(descriptor: Int32, fileSize: UInt64) throws {
            guard fileSize <= UInt64(Int64.max) else {
                close(descriptor)
                throw VaultCryptoError.inputTooLarge
            }
            self.descriptor = descriptor
            self.fileSize = fileSize
        }

        deinit { close(descriptor) }

        func read(upToCount count: Int) throws -> Data? {
            guard count >= 0 else { throw VaultCryptoError.invalidRange }
            return try cursorLock.withLock {
                guard cursor < fileSize else { return nil }
                let amount = Int(min(UInt64(count), fileSize - cursor))
                let result = try read(offset: cursor, count: amount)
                cursor += UInt64(amount)
                return result
            }
        }

        func read(offset: UInt64, count: Int) throws -> Data {
            guard offset <= fileSize, count >= 0,
                  UInt64(count) <= fileSize - offset,
                  offset <= UInt64(Int64.max) else {
                throw VaultCryptoError.malformedEnvelope
            }
            var result = Data(count: count)
            var done = 0
            let baseOffset = off_t(offset)
            let readCount = result.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return count == 0 ? 0 : -1 }
                while done < count {
                    let value = pread(descriptor, base.advanced(by: done), count - done,
                                      baseOffset + off_t(done))
                    if value <= 0 { return -1 }
                    done += value
                }
                return done
            }
            guard readCount == count else { throw VaultCryptoError.malformedEnvelope }
            return result
        }
    }

    /// Creates the LVF destination through an open parent descriptor. This
    /// module intentionally does not depend on Storage, so keep the tiny
    /// no-follow primitive local to the file-envelope implementation.
    private static func createAnchoredWriter(_ path: String) throws -> FileHandle {
        let components = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard let name = components.last,
              !components.contains("."), !components.contains("..") else {
            throw VaultCryptoError.malformedEnvelope
        }
        var parent = open(path.hasPrefix("/") ? "/" : ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard parent >= 0 else { throw VaultCryptoError.malformedEnvelope }
        for component in components.dropLast() {
            let next = component.withCString { openat(parent, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW) }
            guard next >= 0 else { close(parent); throw VaultCryptoError.malformedEnvelope }
            close(parent); parent = next
        }
        let descriptor = name.withCString {
            openat(parent, $0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        }
        close(parent)
        guard descriptor >= 0 else { throw VaultCryptoError.malformedEnvelope }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    /// Opens the `decrypt(to:)` destination through the same no-follow
    /// component walk as `createAnchoredWriter`, but also accepts a
    /// pre-existing empty regular file: a caller may need to apply Data
    /// Protection to the destination before ciphertext lands in it. Anchoring
    /// every open closes the symlink-swap window a path-based existence check
    /// followed by a separate open would leave. Returns whether this call
    /// created the file, so callers remove only what they created.
    private static func openOrCreateAnchoredWriter(_ path: String) throws -> (FileHandle, Bool) {
        let components = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard let name = components.last,
              !components.contains("."), !components.contains("..") else {
            throw VaultCryptoError.malformedEnvelope
        }
        var parent = open(path.hasPrefix("/") ? "/" : ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard parent >= 0 else { throw VaultCryptoError.malformedEnvelope }
        for component in components.dropLast() {
            let next = component.withCString { openat(parent, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW) }
            guard next >= 0 else { close(parent); throw VaultCryptoError.malformedEnvelope }
            close(parent); parent = next
        }
        defer { close(parent) }
        let created = name.withCString {
            openat(parent, $0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        }
        if created >= 0 {
            return (FileHandle(fileDescriptor: created, closeOnDealloc: true), true)
        }
        guard errno == EEXIST else { throw VaultCryptoError.malformedEnvelope }
        let existing = name.withCString { openat(parent, $0, O_WRONLY | O_NOFOLLOW) }
        guard existing >= 0 else { throw VaultCryptoError.malformedEnvelope }
        var info = stat()
        guard fstat(existing, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size == 0 else {
            close(existing)
            throw VaultCryptoError.malformedEnvelope
        }
        return (FileHandle(fileDescriptor: existing, closeOnDealloc: true), false)
    }

    private static func removeAnchoredFile(_ path: String) throws {
        let components = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard let name = components.last,
              !components.contains("."), !components.contains("..") else { return }
        let parentPath = path.hasPrefix("/")
            ? "/" + components.dropLast().joined(separator: "/")
            : components.dropLast().joined(separator: "/")
        let parent = open(parentPath.isEmpty ? "." : parentPath, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard parent >= 0 else { return }
        defer { close(parent) }
        var info = stat()
        guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
              (info.st_mode & S_IFMT) == S_IFREG else { return }
        _ = name.withCString { unlinkat(parent, $0, 0) }
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
    /// This token exists only after every frame's authentication tag has
    /// verified under the supplied root key.
    public var authenticatedGeneration: VaultAuthenticatedGeneration {
        VaultAuthenticatedGeneration(identity: identity)
    }
    public func frame(at index: UInt32) throws -> Data { try payload.frame(at: index) }
    public func read(offset: UInt64, count: Int) throws -> Data {
        try payload.read(offset: offset, count: count)
    }
    public func digest() throws -> String { try payload.digest() }
    public func digestBytes() throws -> Data { try payload.digestBytes() }
    @discardableResult
    public func writeCopy(to destinationURL: URL) throws -> UInt64 {
        try payload.writeCopy(to: destinationURL)
    }
}

/// A caller-owned, cursor-advancing byte source. `FileHandle` and the
/// package's `StableReadFile` both already satisfy this shape, so the
/// chunk-sealing loop reads through one path regardless of which descriptor
/// kind supplied the plaintext.
protocol VaultSealableByteSource {
    func read(upToCount count: Int) throws -> Data?
}
extension FileHandle: VaultSealableByteSource {}
extension VaultAuthenticatedCiphertextFile.StableReadFile: VaultSealableByteSource {}

public extension VaultChunkedCryptor {
    /// Streams bytes from an already-open, caller-owned descriptor into the
    /// bounded frame-file format.  The descriptor is never reopened by path;
    /// callers use this when a prior validation step must remain bound to the
    /// same inode for the whole operation (for example, duplicate import
    /// reconciliation).
    func sealFile(plaintextHandle: FileHandle, plaintextByteCount: UInt64,
                  fileURL: URL, kind: VaultRemoteObjectKind,
                  objectID: VaultObjectID, revision: UUID, root: VaultRootKey) throws {
        try plaintextHandle.seek(toOffset: 0)
        try sealFile(source: plaintextHandle, size: plaintextByteCount, fileURL: fileURL,
                     kind: kind, objectID: objectID, revision: revision, root: root)
    }

    /// Streams a plaintext regular file into the bounded frame-file format.
    /// The source descriptor is held open throughout the copy, so replacing
    /// the source pathname cannot switch bytes midway through sealing.
    func sealFile(plaintextURL: URL, fileURL: URL, kind: VaultRemoteObjectKind,
                  objectID: VaultObjectID, revision: UUID, root: VaultRootKey) throws {
        let source = try VaultAuthenticatedCiphertextFile.openStableReadOnly(plaintextURL)
        try sealFile(source: source, size: source.fileSize, fileURL: fileURL,
                     kind: kind, objectID: objectID, revision: revision, root: root)
    }

    /// Shared body for both `sealFile` overloads. Every nonce issued for this
    /// seal — the wrapped-DEK nonce and each chunk's — is tracked and a
    /// repeat throws, the same defence the in-memory `seal(_:objectID:...)`
    /// applies against a broken random source.
    private func sealFile<Source: VaultSealableByteSource>(
        source: Source, size: UInt64, fileURL: URL, kind: VaultRemoteObjectKind,
        objectID: VaultObjectID, revision: UUID, root: VaultRootKey) throws {
        guard size <= Self.maximumObjectBytes else { throw VaultCryptoError.inputTooLarge }
        let output = try VaultAuthenticatedCiphertextFile.writePlaceholder(to: fileURL)
        defer { try? output.close() }
        var digest = SHA256()
        var frameCount: UInt32 = 0
        var issuedNonces = Set<Data>()
        func appendFrame(_ frame: Data) throws {
            try VaultAuthenticatedCiphertextFile.writeFrame(frame, to: output)
            var length = UInt64(frame.count).bigEndian
            withUnsafeBytes(of: &length) { digest.update(data: Data($0)) }
            digest.update(data: frame)
            guard frameCount < UInt32.max else { throw VaultCryptoError.tooManyChunks }
            frameCount += 1
        }
        let dek = try random.bytes(count: 32)
        guard dek.count == 32 else { throw VaultCryptoError.invalidLength }
        try appendFrame(try wrap(dek, root, objectID, revision, try uniqueFileNonce(&issuedNonces)))
        let key = SymmetricKey(data: dek)
        var remaining = size
        var index: UInt32 = 0
        while remaining > 0 || (size == 0 && index == 0) {
            if Task.isCancelled { throw VaultCryptoError.invalidLength }
            let count = size == 0 ? 0 : Int(min(UInt64(chunkSize), remaining))
            let bytes: Data
            if count == 0 { bytes = Data() }
            else {
                guard let read = try source.read(upToCount: count), read.count == count else {
                    throw VaultCryptoError.invalidLength
                }
                bytes = read
            }
            let nonce = try uniqueFileNonce(&issuedNonces)
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
        guard try source.read(upToCount: 1)?.isEmpty != false else {
            throw VaultCryptoError.invalidLength
        }
        try output.synchronize()
        let metadata = VaultAuthenticatedCiphertextFile.Metadata(
            vaultID: vaultID, objectID: objectID, revision: revision, kind: kind,
            rootVersion: root.version, plaintextByteCount: size,
            frameCount: frameCount, generation: digest.finalize()
                .map { String(format: "%02x", $0) }.joined())
        try VaultAuthenticatedCiphertextFile.rewriteHeader(metadata, at: fileURL)
    }

    private func uniqueFileNonce(_ issued: inout Set<Data>) throws -> Data {
        let nonce = try random.bytes(count: 12)
        guard nonce.count == 12 else { throw VaultCryptoError.invalidLength }
        guard issued.insert(nonce).inserted else { throw VaultCryptoError.authenticationFailed }
        return nonce
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock(); defer { unlock() }
        return try body()
    }
}
