import CryptoKit
import Foundation
import LunaVaultBackend
import LunaVaultModels

public enum LunaVaultMacModule {
    public static let identifier = "LunaVaultMac"
}

public enum VaultMacCompanionError: Error, Equatable, Sendable {
    case invalidRevision
    case objectNotFound
    case conflict
    case incompleteUpload
    case invalidRange
    case diskFailure
}

/// Owner-only credential persistence for a paired Mac. This is an app-level
/// pairing secret, not the iPhone's Vault root key. The host UI should put this
/// file inside its application-support directory and remove it on revoke.
public struct VaultMacPairedCredentialStore: Sendable {
    public init() {}

    public func save(_ secret: VaultMacPairingSecret, at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(secret.base64Encoded.utf8).write(to: url, options: .atomic)
        #if canImport(Darwin)
        guard chmod(url.path, 0o600) == 0 else { throw VaultMacCompanionError.diskFailure }
        #endif
    }

    public func load(from url: URL) throws -> VaultMacPairingSecret {
        guard let encoded = String(data: try Data(contentsOf: url), encoding: .utf8) else {
            throw VaultMacProtocolError.invalidSecret
        }
        return try VaultMacPairingSecret(base64Encoded: encoded.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    public func revoke(at url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }
}

private struct StoredObject: Codable, Sendable {
    var objectID: VaultObjectID
    var revision: VaultRevision
    var totalBytes: UInt64
    var totalChunks: UInt32
    var deleted: Bool
    var idempotencyKeys: [String]
}

private struct PartialUpload: Codable, Sendable {
    var objectID: VaultObjectID
    var revision: VaultRevision
    var totalChunks: UInt32
    var receivedChunks: [UInt32]
}

private struct CompanionManifest: Codable, Sendable {
    var objects: [String: StoredObject] = [:]
    var partialUploads: [String: PartialUpload] = [:]
}

private struct ManifestEnvelope: Codable {
    let nonce: Data
    let ciphertext: Data
    let tag: Data
}

/// Encrypted-object storage for the user-owned Mac. The Mac never receives
/// the iPhone's Vault root key. It stores a paired application secret and a
/// manifest encrypted with that secret; object files are the already encrypted
/// CryptoKit chunks produced by `LunaVaultCrypto`.
public actor VaultMacCompanionStore {
    public let rootURL: URL
    private let secret: VaultMacPairingSecret
    private var manifest: CompanionManifest

    public init(rootURL: URL, secret: VaultMacPairingSecret) throws {
        self.rootURL = rootURL
        self.secret = secret
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: rootURL.appendingPathComponent("objects", isDirectory: true), withIntermediateDirectories: true)
        self.manifest = try Self.loadManifest(rootURL: rootURL, secret: secret)
    }

    public func handle(_ request: VaultMacRequest) throws -> VaultMacResponse {
        let request = try request.validated()
        switch request.operation {
        case .putChunk:
            return try putChunk(request)
        case .readRange:
            return try readRange(request)
        case .delete:
            return try delete(request)
        }
    }

    public func currentRevision(for objectID: VaultObjectID) -> UUID? {
        manifest.objects[objectID.rawValue.uuidString]?.revision.revision
    }

    public func storedObjectCount() -> Int {
        manifest.objects.values.filter { !$0.deleted }.count
    }

    private func putChunk(_ request: VaultMacRequest) throws -> VaultMacResponse {
        guard let revision = request.revision,
              revision.objectID == request.objectID,
              let index = request.chunkIndex,
              let totalChunks = request.totalChunks,
              let ciphertext = request.ciphertext else {
            throw VaultMacCompanionError.invalidRevision
        }
        let key = request.objectID.rawValue.uuidString
        if let current = manifest.objects[key] {
            if current.deleted || compare(revision, current.revision) < 0 {
                throw VaultMacCompanionError.conflict
            }
            if current.revision.revision != revision.revision,
               request.expectedRevision != current.revision.revision {
                return VaultMacResponse(status: .conflict, objectID: request.objectID, currentRevision: current.revision.revision)
            }
            if current.revision.revision == revision.revision,
               current.idempotencyKeys.contains(request.idempotencyKey) {
                return VaultMacResponse(status: .accepted, objectID: request.objectID, currentRevision: current.revision.revision)
            }
        }

        let objectDirectory = objectDirectory(for: request.objectID, revision: revision.revision)
        try FileManager.default.createDirectory(at: objectDirectory, withIntermediateDirectories: true)
        let chunkURL = objectDirectory.appendingPathComponent("chunk-\(index).bin")
        if FileManager.default.fileExists(atPath: chunkURL.path) {
            guard try Data(contentsOf: chunkURL) == ciphertext else {
                throw VaultMacCompanionError.conflict
            }
        } else {
            try ciphertext.write(to: chunkURL, options: .atomic)
            try makePrivate(chunkURL)
        }

        var partial = manifest.partialUploads[key] ?? PartialUpload(
            objectID: request.objectID,
            revision: revision,
            totalChunks: totalChunks,
            receivedChunks: [])
        guard partial.revision.revision == revision.revision, partial.totalChunks == totalChunks else {
            throw VaultMacCompanionError.conflict
        }
        if !partial.receivedChunks.contains(index) { partial.receivedChunks.append(index) }
        partial.receivedChunks.sort()
        manifest.partialUploads[key] = partial

        guard partial.receivedChunks.count == Int(totalChunks) else {
            try persistManifest()
            return VaultMacResponse(status: .partial, objectID: request.objectID, currentRevision: manifest.objects[key]?.revision.revision, receivedChunks: partial.receivedChunks)
        }

        let finalURL = objectDirectory.appendingPathComponent("ciphertext.bin")
        let stagingURL = objectDirectory.appendingPathComponent(".ciphertext.staging")
        FileManager.default.createFile(atPath: stagingURL.path, contents: nil)
        let output = try FileHandle(forWritingTo: stagingURL)
        defer { try? output.close() }
        for chunk in 0..<totalChunks {
            let chunkURL = objectDirectory.appendingPathComponent("chunk-\(chunk).bin")
            guard FileManager.default.fileExists(atPath: chunkURL.path) else {
                throw VaultMacCompanionError.incompleteUpload
            }
            try output.write(contentsOf: Data(contentsOf: chunkURL))
        }
        try output.synchronize()
        try output.close()
        if FileManager.default.fileExists(atPath: finalURL.path) {
            _ = try FileManager.default.replaceItemAt(finalURL, withItemAt: stagingURL, backupItemName: nil, options: .usingNewMetadataOnly)
        } else {
            try FileManager.default.moveItem(at: stagingURL, to: finalURL)
        }
        try makePrivate(finalURL)

        let object = StoredObject(objectID: request.objectID, revision: revision, totalBytes: UInt64((try Data(contentsOf: finalURL)).count), totalChunks: totalChunks, deleted: false, idempotencyKeys: [request.idempotencyKey])
        manifest.objects[key] = object
        manifest.partialUploads.removeValue(forKey: key)
        try persistManifest()
        return VaultMacResponse(status: .accepted, objectID: request.objectID, currentRevision: revision.revision, receivedChunks: partial.receivedChunks)
    }

    private func readRange(_ request: VaultMacRequest) throws -> VaultMacResponse {
        let key = request.objectID.rawValue.uuidString
        guard let object = manifest.objects[key], !object.deleted else {
            return VaultMacResponse(status: .notFound, objectID: request.objectID)
        }
        guard let offset = request.offset, let length = request.length,
              offset <= UInt64(Int.max), length <= UInt64(Int.max), offset <= UInt64(Int.max) - length else {
            throw VaultMacCompanionError.invalidRange
        }
        let file = objectDirectory(for: request.objectID, revision: object.revision.revision).appendingPathComponent("ciphertext.bin")
        guard FileManager.default.fileExists(atPath: file.path) else { throw VaultMacCompanionError.objectNotFound }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        try handle.seek(toOffset: offset)
        let bytes = try handle.read(upToCount: Int(length)) ?? Data()
        return VaultMacResponse(status: .accepted, objectID: request.objectID, currentRevision: object.revision.revision, ciphertext: bytes)
    }

    private func delete(_ request: VaultMacRequest) throws -> VaultMacResponse {
        let key = request.objectID.rawValue.uuidString
        guard let current = manifest.objects[key] else {
            return VaultMacResponse(status: .notFound, objectID: request.objectID)
        }
        guard request.expectedRevision == current.revision.revision else {
            return VaultMacResponse(status: .conflict, objectID: request.objectID, currentRevision: current.revision.revision)
        }
        var deleted = current
        deleted.deleted = true
        deleted.idempotencyKeys = Array(Set(deleted.idempotencyKeys + [request.idempotencyKey]))
        manifest.objects[key] = deleted
        try persistManifest()
        return VaultMacResponse(status: .accepted, objectID: request.objectID, currentRevision: current.revision.revision)
    }

    private func objectDirectory(for objectID: VaultObjectID, revision: UUID) -> URL {
        rootURL.appendingPathComponent("objects", isDirectory: true)
            .appendingPathComponent(objectID.rawValue.uuidString, isDirectory: true)
            .appendingPathComponent(revision.uuidString, isDirectory: true)
    }

    private func persistManifest() throws {
        let plaintext = try JSONEncoder().encode(manifest)
        let nonce = AES.GCM.Nonce()
        let sealed = try AES.GCM.seal(plaintext, using: SymmetricKey(data: secret.rawValue), nonce: nonce, authenticating: Data("LunaVault-Mac-manifest-v1".utf8))
        let envelope = ManifestEnvelope(nonce: Data(nonce), ciphertext: Data(sealed.ciphertext), tag: Data(sealed.tag))
        let url = rootURL.appendingPathComponent("manifest.v1")
        try JSONEncoder().encode(envelope).write(to: url, options: .atomic)
        try makePrivate(url)
    }

    private static func loadManifest(rootURL: URL, secret: VaultMacPairingSecret) throws -> CompanionManifest {
        let url = rootURL.appendingPathComponent("manifest.v1")
        guard FileManager.default.fileExists(atPath: url.path) else { return CompanionManifest() }
        do {
            let envelope = try JSONDecoder().decode(ManifestEnvelope.self, from: Data(contentsOf: url))
            let nonce = try AES.GCM.Nonce(data: envelope.nonce)
            let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: envelope.ciphertext, tag: envelope.tag)
            let data = try AES.GCM.open(box, using: SymmetricKey(data: secret.rawValue), authenticating: Data("LunaVault-Mac-manifest-v1".utf8))
            return try JSONDecoder().decode(CompanionManifest.self, from: data)
        } catch {
            throw VaultMacCompanionError.diskFailure
        }
    }

    private func makePrivate(_ url: URL) throws {
        #if canImport(Darwin)
        guard chmod(url.path, 0o600) == 0 else { throw VaultMacCompanionError.diskFailure }
        #else
        _ = url
        #endif
    }

    private func compare(_ lhs: VaultRevision, _ rhs: VaultRevision) -> Int {
        if lhs.logicalTime != rhs.logicalTime { return lhs.logicalTime < rhs.logicalTime ? -1 : 1 }
        if lhs.deviceID != rhs.deviceID { return lhs.deviceID < rhs.deviceID ? -1 : 1 }
        if lhs.revision == rhs.revision { return 0 }
        return lhs.revision.uuidString < rhs.revision.uuidString ? -1 : 1
    }
}

/// Thin request dispatcher used by the Network.framework listener and by
/// deterministic in-process tests. Authentication is handled by the wire
/// framing layer before a request reaches this actor.
public actor VaultMacCompanionService {
    private let store: VaultMacCompanionStore

    public init(store: VaultMacCompanionStore) {
        self.store = store
    }

    public func handle(_ request: VaultMacRequest) async -> VaultMacResponse {
        do {
            return try await store.handle(request)
        } catch VaultMacCompanionError.conflict {
            return VaultMacResponse(status: .conflict, objectID: request.objectID)
        } catch VaultMacCompanionError.objectNotFound {
            return VaultMacResponse(status: .notFound, objectID: request.objectID)
        } catch {
            return VaultMacResponse(status: .invalid, objectID: request.objectID, message: "request rejected")
        }
    }
}
