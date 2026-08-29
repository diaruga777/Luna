import Foundation
import SQLite3
import CryptoKit
import LunaAppConfig
import LunaVaultCrypto
import LunaVaultModels

public enum LunaVaultStorageModule { public static let identifier = "LunaVaultStorage" }

public struct VaultStorageConfiguration: Equatable, Sendable {
    public let databaseName: String
    public let policy: VaultStoragePolicy
    /// Nil means 10% of important available capacity, bounded to 2–20 GB.
    public let cacheQuotaOverrideBytes: Int64?
    public let vaultID: String
    public init(databaseName: String = "vault.sqlite", policy: VaultStoragePolicy = VaultStoragePolicy(location: .device), cacheQuotaBytes: Int64? = nil, vaultID: String = "default") {
        self.databaseName = databaseName; self.policy = policy
        self.cacheQuotaOverrideBytes = cacheQuotaBytes.map { min(max($0, 2_000_000_000), 20_000_000_000) }
        self.vaultID = vaultID
    }
    public var cacheQuotaBytes: Int64 { cacheQuotaOverrideBytes ?? 2_000_000_000 }
    public func cacheQuota(availableCapacity: Int64) -> Int64 {
        cacheQuotaOverrideBytes ?? min(max(availableCapacity / 10, 2_000_000_000), 20_000_000_000)
    }
}

public protocol VaultFileProtectionApplying: Sendable {
    func apply(to url: URL) throws
    func hasRequiredProtection(at url: URL) throws -> Bool
}

/// iOS Simulator accepts protection-class writes but does not expose the
/// resulting class through `attributesOfItem`. Injected test appliers can
/// register the inode they authenticated; this ledger is unavailable on
/// device and never accepts a changed inode.
public enum VaultSimulatorProtectionLedger {
    #if targetEnvironment(simulator)
    private static let lock = NSLock()
    private static var fileNumbers: [String: Int64] = [:]
    #endif

    public static func record(_ url: URL) {
        #if targetEnvironment(simulator)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let number = attributes[.systemFileNumber] as? NSNumber else { return }
        lock.lock(); defer { lock.unlock() }
        fileNumbers[url.standardizedFileURL.path] = number.int64Value
        #endif
    }

    public static func matches(_ url: URL) -> Bool {
        #if targetEnvironment(simulator)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let number = attributes[.systemFileNumber] as? NSNumber else { return false }
        lock.lock(); defer { lock.unlock() }
        return fileNumbers[url.standardizedFileURL.path] == number.int64Value
        #else
        return false
        #endif
    }
}

public struct SystemVaultFileProtectionApplier: VaultFileProtectionApplying {
    public init() {}
    public func apply(to url: URL) throws {
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
        #if targetEnvironment(simulator)
        // The iOS simulator accepts the protection-class write but currently
        // omits `.protectionKey` when attributes are read back. Remember the
        // inode that the OS accepted so a later replacement is still rejected
        // rather than treating an arbitrary path as protected.
        if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
           let number = attributes[.systemFileNumber] as? NSNumber {
            VaultSimulatorProtectionLedger.record(url)
        }
        #endif
    }
    public func hasRequiredProtection(at url: URL) throws -> Bool {
        let value = try FileManager.default.attributesOfItem(atPath: url.path)[.protectionKey]
        if let protection = value as? FileProtectionType { return protection == .completeUntilFirstUserAuthentication }
        if let rawValue = value as? String {
            guard rawValue == FileProtectionType.completeUntilFirstUserAuthentication.rawValue else {
                throw VaultStorageError.sqlite("unexpectedProtectionAttribute:\(rawValue)|expected:\(FileProtectionType.completeUntilFirstUserAuthentication.rawValue)")
            }
            return true
        }
        if let rawValue = value as? NSString { return rawValue as String == FileProtectionType.completeUntilFirstUserAuthentication.rawValue }
        #if targetEnvironment(simulator)
        if value == nil,
           let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
           VaultSimulatorProtectionLedger.matches(url) { return true }
        #endif
        return false
    }

}

public enum VaultStorageError: Error, Equatable, Sendable {
    case appGroupUnavailable, sqlite(String), missingObject, invalidTransition, invalidArtifact, stagingLimit, protectionRequired
}
public protocol VaultObjectStoring: Sendable {
    func data(for id: VaultObjectID) throws -> Data?
    func setData(_ data: Data, for id: VaultObjectID) throws
    func removeData(for id: VaultObjectID) throws
}

/// A repository-issued capability for local preview. Callers cannot turn an
/// arbitrary URL into this value; the repository verifies the current
/// revision, exact byte count, generation marker, regular-file type, and
/// required Data Protection class before issuing it.
public struct VaultLocalContentCapability: Hashable, Sendable {
    public let objectID: VaultObjectID
    public let revision: UUID
    public let generation: String
    public let byteCount: Int64
    public let localURL: URL
    /// True only after protection, regular-file, size, revision, generation,
    /// and a streaming SHA-256 verification all succeed.
    public let authenticated: Bool

    internal init(objectID: VaultObjectID, revision: UUID, generation: String,
                  byteCount: Int64, localURL: URL) {
        self.objectID = objectID; self.revision = revision
        self.generation = generation; self.byteCount = byteCount
        self.localURL = localURL; self.authenticated = true
    }
}
public struct VaultEncryptedArtifact: Equatable, Sendable {
    public enum Kind: String, Sendable { case manifest, index }
    public let kind: Kind; public let vaultID: String; public let objectID: VaultObjectID
    public let revision: UUID; public let rootVersion: UInt32; public let encryptedFrames: [Data]
    public init(kind: Kind, vaultID: String = "default", revision: UUID, rootVersion: UInt32, encryptedFrames: [Data]) throws {
        guard rootVersion > 0, encryptedFrames.count >= 2 else { throw VaultStorageError.invalidArtifact }
        let expectedRole: VaultEnvelopeRole = kind == .index ? .index : .metadata
        let vaultFingerprint=Data(SHA256.hash(data:Data(vaultID.utf8)).prefix(16))
        guard encryptedFrames[0].count == 113, encryptedFrames[0][0] == 1,
              UInt32(bigEndianBytes: encryptedFrames[0][1..<5]) == rootVersion,
              let first = try? VaultChunkEnvelope.decode(encryptedFrames[1], maximumBytes: 8_388_608 + VaultChunkEnvelope.headerSize + 16),
              first.role == expectedRole, first.revision == revision, first.rootVersion == rootVersion else { throw VaultStorageError.invalidArtifact }
        guard Data(encryptedFrames[0][5..<21])==vaultFingerprint,Data(encryptedFrames[0][21..<37])==first.objectID.rawValue.uuidData,Data(encryptedFrames[0][37..<53])==revision.uuidData else{throw VaultStorageError.invalidArtifact}
        let chunkSize = first.ciphertext.count - 16
        guard chunkSize >= 0 else { throw VaultStorageError.invalidArtifact }
        for (index, frame) in encryptedFrames.dropFirst().enumerated() {
            guard let envelope=try?VaultChunkEnvelope.decode(frame,maximumBytes:8_388_608+VaultChunkEnvelope.headerSize+16),envelope.role==expectedRole,envelope.objectID==first.objectID,envelope.revision==revision,envelope.rootVersion==rootVersion,envelope.plaintextLength==first.plaintextLength,envelope.chunkIndex==UInt32(index) else{throw VaultStorageError.invalidArtifact}
            let expected = first.plaintextLength == 0 ? 0 : min(chunkSize, Int(first.plaintextLength) - index * chunkSize)
            guard expected >= 0, envelope.ciphertext.count == expected + 16 else { throw VaultStorageError.invalidArtifact }
        }
        let expectedCount = first.plaintextLength == 0 ? 1 : (Int(first.plaintextLength) + max(1,chunkSize) - 1) / max(1,chunkSize)
        guard expectedCount == encryptedFrames.count - 1 else { throw VaultStorageError.invalidArtifact }
        self.kind=kind; self.vaultID=vaultID; self.objectID=first.objectID; self.revision=revision; self.rootVersion=rootVersion; self.encryptedFrames=encryptedFrames
    }
}

public final class VaultRepository: @unchecked Sendable {
    public let databaseURL: URL; public let contentDirectory: URL; public let cacheQuotaBytes: Int64
    /// Only an iCloud policy that allows local eviction may evict full bytes.
    /// Device and Mac copies are canonical and therefore non-evictable.
    public let supportsCacheEviction: Bool
    private var db: OpaquePointer?; private let queue=DispatchQueue(label: "com.hsanabria.luna.vault.sqlite")
    private let fileManager: FileManager; private let configuration: VaultStorageConfiguration
    private let protectionApplier: VaultFileProtectionApplying
    private let stagingAllowanceBytes: Int64

    /// Production initializer fails closed when the entitled App Group is unavailable.
    public convenience init(configuration: VaultStorageConfiguration = VaultStorageConfiguration(), fileManager: FileManager = .default, protectionApplier: VaultFileProtectionApplying = SystemVaultFileProtectionApplier()) throws {
        guard let container = AppConfig.sharedContainerURL(fileManager) else { throw VaultStorageError.appGroupUnavailable }
        try self.init(configuration: configuration, testContainerURL: container, fileManager: fileManager, protectionApplier: protectionApplier)
    }
    /// Explicit scratch-container initializer for tests and staged fixtures only.
    public init(configuration: VaultStorageConfiguration = VaultStorageConfiguration(), testContainerURL: URL, fileManager: FileManager = .default, protectionApplier: VaultFileProtectionApplying = SystemVaultFileProtectionApplier()) throws {
        self.configuration=configuration; self.fileManager=fileManager
        self.protectionApplier=protectionApplier
        databaseURL=testContainerURL.appendingPathComponent(configuration.databaseName)
        contentDirectory=testContainerURL.appendingPathComponent("VaultObjects",isDirectory:true)
        try fileManager.createDirectory(at:testContainerURL,withIntermediateDirectories:true)
        try fileManager.createDirectory(at:contentDirectory,withIntermediateDirectories:true)
        let values=try? testContainerURL.resourceValues(forKeys:[.volumeAvailableCapacityForImportantUsageKey])
        let capacity=Int64(values?.volumeAvailableCapacityForImportantUsage ?? 20_000_000_000)
        cacheQuotaBytes=configuration.cacheQuota(availableCapacity:capacity); stagingAllowanceBytes=min(max(cacheQuotaBytes/10,256_000_000),2_000_000_000)
        supportsCacheEviction = configuration.policy.location == .iCloud && !configuration.policy.keepLocalCopy
        var opened:OpaquePointer?;let flags=SQLITE_OPEN_READWRITE|SQLITE_OPEN_CREATE|SQLITE_OPEN_FULLMUTEX|0x0040_0000
        guard sqlite3_open_v2(databaseURL.path,&opened,flags,nil)==SQLITE_OK,let opened else{throw VaultStorageError.sqlite("open")};db=opened
        do { try queue.sync { sqlite3_busy_timeout(opened,5000);try retryingBusy{try execute("PRAGMA journal_mode=WAL")};try execute("PRAGMA synchronous=FULL");try execute("PRAGMA foreign_keys=ON");try retryingBusy{try migrate()} } } catch { sqlite3_close_v2(opened);db=nil;throw error }
        try protect(testContainerURL);try protect(contentDirectory);try protectDatabaseFiles();try queue.sync{try repairFileLayout();try drainPendingCleanup()}
    }
    deinit{if let db{sqlite3_close_v2(db)}}

    public func object(_ id:VaultObjectID)throws->VaultObjectRecord?{try sync{try objectLocked(id)}}
    public func objects(includeDeleted:Bool=false)throws->[VaultObjectRecord]{try sync{var result=[VaultObjectRecord]();let whereClause=includeDeleted ? "":" WHERE tombstone=0";try query("SELECT id,revision,logical_time,device_id,size,content_type,created_at,updated_at,accessed_at,tombstone FROM objects\(whereClause) ORDER BY logical_time DESC,device_id DESC,revision DESC"){row in guard let u=UUID(uuidString:row.text(0) ?? "")else{throw VaultStorageError.sqlite("object id")};result.append(try decodeRecord(VaultObjectID(rawValue:u),row,offset:1))};return result}}
    @discardableResult public func upsert(_ record:VaultObjectRecord)throws->Bool{try sync{try transaction{
        if let tomb=try tombstoneLocked(record.id), compare(record.logicalTime,record.deviceID,record.revision,tomb.logicalTime,tomb.deviceID,tomb.revision)<=0{return false}
        if let old=try objectLocked(record.id), compare(record.logicalTime,record.deviceID,record.revision,old.logicalTime,old.deviceID,old.revision)<=0{return false}
        try run("INSERT INTO objects(id,revision,logical_time,device_id,size,content_type,created_at,updated_at,accessed_at,tombstone) VALUES(?,?,?,?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET revision=excluded.revision,logical_time=excluded.logical_time,device_id=excluded.device_id,size=excluded.size,content_type=excluded.content_type,created_at=excluded.created_at,updated_at=excluded.updated_at,accessed_at=excluded.accessed_at,tombstone=excluded.tombstone",
            [.text(record.id.rawValue.uuidString),.text(record.revision.uuidString),.int(record.logicalTime),.text(record.deviceID),.int(record.size),record.contentType.map(SQLiteValue.text) ?? .null,.double(record.createdAt.timeIntervalSinceReferenceDate),.double(record.updatedAt.timeIntervalSinceReferenceDate),.double(record.accessedAt.timeIntervalSinceReferenceDate),.int(record.isTombstone ? 1:0)])
        return true
    }}}
    @discardableResult public func tombstone(_ tombstone:VaultTombstone)throws->Bool{try sync{let advanced=try transaction{
        if let old=try tombstoneLocked(tombstone.id),compare(tombstone.logicalTime,tombstone.deviceID,tombstone.revision,old.logicalTime,old.deviceID,old.revision)<=0{return false}
        if let old=try objectLocked(tombstone.id),compare(tombstone.logicalTime,tombstone.deviceID,tombstone.revision,old.logicalTime,old.deviceID,old.revision)<=0{return false}
        try run("INSERT INTO tombstones(id,revision,logical_time,device_id,deleted_at) VALUES(?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET revision=excluded.revision,logical_time=excluded.logical_time,device_id=excluded.device_id,deleted_at=excluded.deleted_at",[.text(tombstone.id.rawValue.uuidString),.text(tombstone.revision.uuidString),.int(tombstone.logicalTime),.text(tombstone.deviceID),.double(tombstone.deletedAt.timeIntervalSinceReferenceDate)])
        if let old=try objectLocked(tombstone.id),compare(tombstone.logicalTime,tombstone.deviceID,tombstone.revision,old.logicalTime,old.deviceID,old.revision)>0 {try run("UPDATE objects SET revision=?,logical_time=?,device_id=?,size=0,updated_at=?,accessed_at=?,tombstone=1 WHERE id=?",[.text(tombstone.revision.uuidString),.int(tombstone.logicalTime),.text(tombstone.deviceID),.double(tombstone.deletedAt.timeIntervalSinceReferenceDate),.double(tombstone.deletedAt.timeIntervalSinceReferenceDate),.text(tombstone.id.rawValue.uuidString)])}
        try enqueueCleanupLocked(tombstone.id)
        try run("DELETE FROM cache WHERE object_id=?",[.text(tombstone.id.rawValue.uuidString)])
        try run("DELETE FROM extraction_artifacts WHERE object_id=?",[.text(tombstone.id.rawValue.uuidString)])
        // Transfer jobs remain durable records, but a tombstoned object must
        // never be retried. Keeping them as cancelled preserves auditability.
        try run("UPDATE jobs SET state='cancelled',next_attempt=NULL,last_error=NULL,lease_owner=NULL,lease_token=NULL,lease_expires=NULL,updated_at=? WHERE object_id=? AND state IN ('queued','retrying','running')",[.double(tombstone.deletedAt.timeIntervalSinceReferenceDate),.text(tombstone.id.rawValue.uuidString)])
        return true}
        if advanced{try drainPendingCleanup()};return advanced}}

    public func writeContent(_ data:Data,for id:VaultObjectID)throws->URL{try sync{
        guard let object=try objectLocked(id),!object.isTombstone else{throw VaultStorageError.missingObject}
        let dir=contentDirectory.appendingPathComponent(id.rawValue.uuidString,isDirectory:true);try fileManager.createDirectory(at:dir,withIntermediateDirectories:true);try protect(dir)
        let token=UUID().uuidString,staging=dir.appendingPathComponent(".staging-\(token)"),stagingGeneration=dir.appendingPathComponent(".generation-staging-\(token)")
        let final=dir.appendingPathComponent("content"),generation=dir.appendingPathComponent(".content-generation"),backup=dir.appendingPathComponent(".previous"),backupGeneration=dir.appendingPathComponent(".previous-generation")
        guard Int64(data.count) == object.size else { throw VaultStorageError.invalidArtifact }
        guard Int64(data.count)<=cacheQuotaBytes+stagingAllowanceBytes else{throw VaultStorageError.stagingLimit}
        do{
            try writeProtectedData(data, to: staging)
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            try writeProtectedData(Data("\(object.revision.uuidString):\(digest)".utf8), to: stagingGeneration)
            for oldBackup in [backup,backupGeneration] where fileManager.fileExists(atPath:oldBackup.path){try fileManager.removeItem(at:oldBackup)}
            if fileManager.fileExists(atPath:final.path){try fileManager.moveItem(at:final,to:backup)}
            if fileManager.fileExists(atPath:generation.path){try fileManager.moveItem(at:generation,to:backupGeneration)}
            do{
                // Data Protection attributes were applied and fsynced on staging and
                // survive rename. Never install first and protect afterward.
                try fileManager.moveItem(at:staging,to:final)
                try fileManager.moveItem(at:stagingGeneration,to:generation)
                // The simulator cannot report the protection class after a
                // rename, so carry the authenticated inode into its final
                // paths for same-process reads and previews.
                VaultSimulatorProtectionLedger.record(final)
                VaultSimulatorProtectionLedger.record(generation)
                for oldBackup in [backup,backupGeneration] where fileManager.fileExists(atPath:oldBackup.path){try fileManager.removeItem(at:oldBackup)}
            }catch{
                if fileManager.fileExists(atPath:final.path){try?fileManager.removeItem(at:final)}
                if fileManager.fileExists(atPath:generation.path){try?fileManager.removeItem(at:generation)}
                if fileManager.fileExists(atPath:backup.path){try fileManager.moveItem(at:backup,to:final)}
                if fileManager.fileExists(atPath:backupGeneration.path){try fileManager.moveItem(at:backupGeneration,to:generation)}
                throw error
            }
            try markObjectReadyLocked(id)
            return final
        }catch{try?fileManager.removeItem(at:staging);try?fileManager.removeItem(at:stagingGeneration);throw error}
    }}

    /// Installs a regular file without materialising it as `Data`. The source
    /// descriptor is checked before opening, then copied through an open file
    /// descriptor in bounded chunks; a replacement of the source path cannot
    /// change the bytes being copied. The final object is invisible to job
    /// workers until the caller enqueues its durable job.
    public func writeContent(from sourceURL: URL, expectedByteCount: Int64? = nil,
                             for id: VaultObjectID) throws -> URL {
        try sync {
            guard let object = try objectLocked(id), !object.isTombstone else {
                throw VaultStorageError.missingObject
            }
            guard sourceURL.isFileURL,
                  (try? sourceURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]).isDirectory) != true,
                  (try? sourceURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]).isSymbolicLink) != true,
                  let attrs = try? fileManager.attributesOfItem(atPath: sourceURL.path),
                  let sourceSize = (attrs[.size] as? NSNumber)?.int64Value,
                  sourceSize >= 0 else { throw VaultStorageError.invalidArtifact }
            let size = expectedByteCount ?? sourceSize
            guard size == sourceSize, size == object.size, size <= 100_000_000_000 else {
                throw VaultStorageError.invalidArtifact
            }
            let dir = contentDirectory.appendingPathComponent(id.rawValue.uuidString, isDirectory: true)
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
            try protect(dir)
            let token = UUID().uuidString
            let staging = dir.appendingPathComponent(".staging-\(token)")
            let stagingGeneration = dir.appendingPathComponent(".generation-staging-\(token)")
            let final = dir.appendingPathComponent("content")
            let generation = dir.appendingPathComponent(".content-generation")
            let backup = dir.appendingPathComponent(".previous")
            let backupGeneration = dir.appendingPathComponent(".previous-generation")
            do {
                let digest = try streamCopy(sourceURL, to: staging, expectedByteCount: size)
                let marker = Data("\(object.revision.uuidString):\(digest)".utf8)
                try writeProtectedData(marker, to: stagingGeneration)
                for old in [backup, backupGeneration] where fileManager.fileExists(atPath: old.path) {
                    try fileManager.removeItem(at: old)
                }
                if fileManager.fileExists(atPath: final.path) { try fileManager.moveItem(at: final, to: backup) }
                if fileManager.fileExists(atPath: generation.path) { try fileManager.moveItem(at: generation, to: backupGeneration) }
                try fileManager.moveItem(at: staging, to: final)
                try fileManager.moveItem(at: stagingGeneration, to: generation)
                VaultSimulatorProtectionLedger.record(final)
                VaultSimulatorProtectionLedger.record(generation)
                for old in [backup, backupGeneration] where fileManager.fileExists(atPath: old.path) {
                    try fileManager.removeItem(at: old)
                }
                try markObjectReadyLocked(id)
                return final
            } catch {
                try? fileManager.removeItem(at: staging)
                try? fileManager.removeItem(at: stagingGeneration)
                throw error
            }
        }
    }

    /// Returns a bounded prefix for extraction routing. Callers must use the
    /// file-based path for objects larger than their extraction budget.
    public func readContentPrefix(for id: VaultObjectID, maximumBytes: Int64) throws -> Data? {
        guard maximumBytes >= 0, maximumBytes <= 64 * 1024 * 1024 else {
            throw VaultStorageError.invalidArtifact
        }
        return try sync {
            let url = contentURL(id)
            guard fileManager.fileExists(atPath: url.path),
                  try protectionApplier.hasRequiredProtection(at: url) else { return nil }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            return try handle.read(upToCount: Int(maximumBytes))
        }
    }

    private func streamCopy(_ sourceURL: URL, to destination: URL,
                            expectedByteCount: Int64) throws -> String {
        guard fileManager.createFile(atPath: destination.path, contents: nil) else {
            throw VaultStorageError.sqlite("create staging")
        }
        // Mark the inode before its first plaintext write; `protect` also
        // verifies the exact required class and fails closed.
        try protect(destination)
        let input = try FileHandle(forReadingFrom: sourceURL)
        let output = try FileHandle(forWritingTo: destination)
        defer { try? input.close(); try? output.close() }
        var copied: Int64 = 0
        var hasher = SHA256()
        while copied < expectedByteCount {
            let count = Int(min(Int64(1_048_576), expectedByteCount - copied))
            guard let chunk = try input.read(upToCount: count), !chunk.isEmpty else {
                throw VaultStorageError.invalidArtifact
            }
            try output.write(contentsOf: chunk)
            hasher.update(data: chunk)
            copied += Int64(chunk.count)
        }
        guard copied == expectedByteCount,
              try input.read(upToCount: 1)?.isEmpty != false else {
            throw VaultStorageError.invalidArtifact
        }
        try output.synchronize()
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func writeProtectedData(_ data: Data, to destination: URL) throws {
        guard fileManager.createFile(atPath: destination.path, contents: nil) else {
            throw VaultStorageError.sqlite("create staging")
        }
        do {
            // Set protection before the first plaintext write. An atomic Data
            // write would create an unprotected inode transiently.
            try protect(destination)
            let handle = try FileHandle(forWritingTo: destination)
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
        } catch {
            try? fileManager.removeItem(at: destination)
            throw error
        }
    }

    private func digestFile(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public func localContentCapability(for id: VaultObjectID) throws -> VaultLocalContentCapability? {
        try sync { () -> VaultLocalContentCapability? in
            guard let object = try objectLocked(id), !object.isTombstone else { return nil }
            let url = contentURL(id)
            let markerURL = generationURL(id)
            guard fileManager.fileExists(atPath: url.path),
                  fileManager.fileExists(atPath: markerURL.path),
                  try protectionApplier.hasRequiredProtection(at: url),
                  try protectionApplier.hasRequiredProtection(at: markerURL),
                  let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  values.isDirectory != true, values.isSymbolicLink != true,
                  let attrs = try? fileManager.attributesOfItem(atPath: url.path),
                  let size = (attrs[.size] as? NSNumber)?.int64Value, size == object.size,
                  let markerData = try? readBoundedFile(markerURL, maximumBytes: 256),
                  let marker = String(data: markerData, encoding: .utf8),
                  let separator = marker.firstIndex(of: ":") else { return nil }
            let markerRevision = String(marker[..<separator])
            let generation = String(marker[marker.index(after: separator)...])
            guard markerRevision == object.revision.uuidString,
                  generation.count == 64,
                  generation.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else { return nil }
            guard try digestFile(url) == generation else { return nil }
            return VaultLocalContentCapability(objectID: id, revision: object.revision,
                                               generation: generation, byteCount: size,
                                               localURL: url)
        }
    }

    public func validateLocalContentCapability(_ capability: VaultLocalContentCapability) throws -> Bool {
        guard let current = try localContentCapability(for: capability.objectID) else { return false }
        return current == capability
    }

    /// In-memory reads are intentionally bounded. Large objects must use the
    /// file URL/capability or the chunked writer APIs.
    public func readContent(for id:VaultObjectID)throws->Data?{try sync { () -> Data? in
        let url = contentURL(id)
        guard fileManager.fileExists(atPath: url.path),
              (try? protectionApplier.hasRequiredProtection(at: url)) == true,
              let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              values.isDirectory != true, values.isSymbolicLink != true else { return nil }
        guard let attrs = try? fileManager.attributesOfItem(atPath: url.path),
              let size = (attrs[.size] as? NSNumber)?.int64Value,
              size <= 64 * 1024 * 1024 else { throw VaultStorageError.stagingLimit }
        return try readBoundedFile(url, maximumBytes: 64 * 1024 * 1024)
    }}
    /// A durable visibility bit separates a metadata row from an installed
    /// protected payload. Workers must not claim jobs for an object until this
    /// bit is true; it survives process death and is repaired from the content
    /// generation marker on the next repository launch.
    public func objectIsReady(_ id: VaultObjectID) throws -> Bool {
        try sync {
            var ready = false
            try query("SELECT ready FROM object_visibility WHERE object_id=?", [.text(id.rawValue.uuidString)]) {
                ready = $0.int(0) != 0
            }
            return ready
        }
    }
    public func removeContent(for id:VaultObjectID)throws{try sync{try transaction{try enqueueCleanupLocked(id)};try drainPendingCleanup()}}

    public func putCache(_ entry:VaultCacheEntry,now:Date=Date())throws{try sync{var downgraded=false;try transaction{guard entry.byteCount >= 0 else{throw VaultStorageError.invalidArtifact};var wasFull=false;var wasPinned=false;var wasEvictable=true;try query("SELECT full_content,pinned,supports_eviction FROM cache WHERE object_id=?",[.text(entry.objectID.rawValue.uuidString)]){wasFull=$0.int(0) != 0;wasPinned=$0.int(1) != 0;wasEvictable=$0.int(2) != 0};downgraded=wasFull && !entry.fullContent;if downgraded{try enqueueCleanupLocked(entry.objectID)};try run("INSERT INTO cache(object_id,bytes,full_content,last_accessed,created_at,pinned,supports_eviction) VALUES(?,?,?,?,?,?,?) ON CONFLICT(object_id) DO UPDATE SET bytes=excluded.bytes,full_content=excluded.full_content,last_accessed=excluded.last_accessed,pinned=excluded.pinned,supports_eviction=excluded.supports_eviction",[.text(entry.objectID.rawValue.uuidString),.int(entry.byteCount),.int(entry.fullContent ? 1:0),.double(entry.lastAccessedAt.timeIntervalSinceReferenceDate),.double(entry.createdAt.timeIntervalSinceReferenceDate),.int((entry.pinned || wasPinned) ? 1:0),.int(entry.supportsEviction && wasEvictable ? 1:0)])};if downgraded{try drainPendingCleanup()};try evictLocked(now:now)}}
    public func cacheEntries()throws->[VaultCacheEntry]{try sync{var result=[VaultCacheEntry]();try query("SELECT object_id,bytes,full_content,last_accessed,created_at,pinned,supports_eviction FROM cache ORDER BY last_accessed DESC"){r in guard let u=UUID(uuidString:r.text(0) ?? "")else{throw VaultStorageError.sqlite("cache id")};result.append(VaultCacheEntry(objectID:VaultObjectID(rawValue:u),byteCount:r.int(1),fullContent:r.int(2) != 0,lastAccessedAt:Date(timeIntervalSinceReferenceDate:r.double(3)),createdAt:Date(timeIntervalSinceReferenceDate:r.double(4)),pinned:r.int(5) != 0,supportsEviction:r.int(6) != 0))};return result}}
    public func setPinned(_ id:VaultObjectID,pinned:Bool)throws{try sync{try run("UPDATE cache SET pinned=? WHERE object_id=?",[.int(pinned ? 1:0),.text(id.rawValue.uuidString)])}}
    /// Holds a full-content cache entry while an active preview owns its URL.
    /// This state is durable so a second process cannot evict bytes beneath a
    /// reader that is still using them.
    public func setPreviewActive(_ id: VaultObjectID, active: Bool,
                                 now: Date = Date()) throws {
        try sync {
            try run("INSERT INTO cache_activity(object_id,active_preview,updated_at) VALUES(?,?,?) ON CONFLICT(object_id) DO UPDATE SET active_preview=excluded.active_preview,updated_at=excluded.updated_at", [.text(id.rawValue.uuidString), .int(active ? 1 : 0), .double(now.timeIntervalSinceReferenceDate)])
        }
    }

    public func isPreviewActive(_ id: VaultObjectID) throws -> Bool {
        try sync {
            var active = false
            try query("SELECT active_preview FROM cache_activity WHERE object_id=?", [.text(id.rawValue.uuidString)]) { active = $0.int(0) != 0 }
            return active
        }
    }
    public func evictExpired(now:Date=Date())throws{try sync{try evictLocked(now:now)}}
    private func evictLocked(now:Date)throws{let cutoff=now.addingTimeInterval(-7*86400).timeIntervalSinceReferenceDate
        var expired=[VaultObjectID]();try query("SELECT object_id FROM cache WHERE full_content=1 AND pinned=0 AND supports_eviction=1 AND COALESCE((SELECT active_preview FROM cache_activity WHERE object_id=cache.object_id),0)=0 AND last_accessed<? ORDER BY last_accessed",[.double(cutoff)]){r in if let u=UUID(uuidString:r.text(0) ?? ""){expired.append(VaultObjectID(rawValue:u))}}
        for id in expired{try removeFullCacheLocked(id)}
        while try scalar("SELECT COALESCE(SUM(bytes),0) FROM cache WHERE full_content=1")>cacheQuotaBytes{var victim:VaultObjectID?;try query("SELECT object_id FROM cache WHERE full_content=1 AND pinned=0 AND supports_eviction=1 AND COALESCE((SELECT active_preview FROM cache_activity WHERE object_id=cache.object_id),0)=0 ORDER BY last_accessed LIMIT 1"){r in victim=r.text(0).flatMap{UUID(uuidString:$0)}.map{VaultObjectID(rawValue:$0)}};guard let victim else{break};try removeFullCacheLocked(victim)}
    }
    private func removeFullCacheLocked(_ id:VaultObjectID)throws{try transaction{try enqueueCleanupLocked(id);try run("DELETE FROM cache WHERE object_id=? AND full_content=1",[.text(id.rawValue.uuidString)])};try drainPendingCleanup()}

    public func enqueue(_ job:VaultJob)throws{try sync{try run("INSERT OR IGNORE INTO jobs(id,idempotency_key,kind,object_id,state,attempts,next_attempt,last_error,created_at,updated_at,lease_owner,lease_token,lease_expires,revision,backend_key,payload_generation,remote_object_kind,expected_remote_revision) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",[.text(job.id.uuidString),.text(job.idempotencyKey),.text(job.kind.rawValue),job.objectID.map{$0.rawValue.uuidString}.map(SQLiteValue.text) ?? .null,.text(job.state.rawValue),.int(Int64(job.attempts)),job.nextAttemptAt.map{$0.timeIntervalSinceReferenceDate}.map(SQLiteValue.double) ?? .null,job.lastError.map(SQLiteValue.text) ?? .null,.double(job.createdAt.timeIntervalSinceReferenceDate),.double(job.updatedAt.timeIntervalSinceReferenceDate),job.leaseOwner.map(SQLiteValue.text) ?? .null,job.leaseToken.map{$0.uuidString}.map(SQLiteValue.text) ?? .null,job.leaseExpiresAt.map{$0.timeIntervalSinceReferenceDate}.map(SQLiteValue.double) ?? .null,job.revision.map{$0.uuidString}.map(SQLiteValue.text) ?? .null,job.backendKey.map(SQLiteValue.text) ?? .null,job.payloadGeneration.map(SQLiteValue.text) ?? .null,job.remoteObjectKind.map(SQLiteValue.text) ?? .null,job.expectedRemoteRevision.map{$0.uuidString}.map(SQLiteValue.text) ?? .null])}}
    public func job(_ id:UUID)throws->VaultJob?{try sync{try jobLocked(id)}}
    public func job(idempotencyKey:String)throws->VaultJob?{try sync{var result:VaultJob?;try query("SELECT id FROM jobs WHERE idempotency_key=?",[.text(idempotencyKey)]){r in if let raw=r.text(0),let id=UUID(uuidString:raw){result=try jobLocked(id)}};return result}}
    public func jobs()throws->[VaultJob]{try jobs(kinds: nil)}
    /// Returns only jobs owned by the requested worker kinds. The filter is
    /// applied in SQLite so a specialized worker never claims a network job
    /// and increments its attempt counter before deferring it.
    public func jobs(kinds: Set<VaultJobKind>?) throws -> [VaultJob] {
        try sync {
            var result = [VaultJob]()
            let values: [SQLiteValue]
            let whereClause: String
            if let kinds, !kinds.isEmpty {
                let names = kinds.map { $0.rawValue }.sorted()
                whereClause = " WHERE kind IN (" + names.map { _ in "?" }.joined(separator: ",") + ")"
                values = names.map(SQLiteValue.text)
            } else {
                whereClause = ""
                values = []
            }
            try query("SELECT id FROM jobs\(whereClause) ORDER BY created_at,id", values) { row in
                if let raw = row.text(0), let id = UUID(uuidString: raw),
                   let job = try jobLocked(id) { result.append(job) }
            }
            return result
        }
    }
    /// Claims exactly `id`, unlike `claimNextJob`, so two different durable
    /// operations cannot be accidentally crossed when callers share a queue.
    public func claimJob(id:UUID,owner:String,now:Date=Date(),leaseDuration:TimeInterval=120)throws->VaultJob?{try sync{try transaction{
        guard let job=try jobLocked(id) else{return nil}
        let nowValue=now.timeIntervalSinceReferenceDate
        let eligible=(job.state == .queued || job.state == .retrying) && (job.nextAttemptAt == nil || job.nextAttemptAt! <= now) || (job.state == .running && (job.leaseExpiresAt ?? .distantFuture) <= now)
        guard eligible, try jobObjectIsReadyLocked(job) else { return nil }
        guard eligible else{return nil}
        let token=UUID()
        try run("UPDATE jobs SET state='running',attempts=attempts+1,lease_owner=?,lease_token=?,lease_expires=?,updated_at=? WHERE id=?",[.text(owner),.text(token.uuidString),.double(now.addingTimeInterval(leaseDuration).timeIntervalSinceReferenceDate),.double(nowValue),.text(id.uuidString)])
        guard sqlite3_changes(db)==1 else{return nil};return try jobLocked(id)
    }}}
    public func claimNextJob(owner:String, now:Date=Date(), leaseDuration:TimeInterval=120,
                             kinds: Set<VaultJobKind>? = nil) throws -> VaultJob? { try sync { try transaction {
        let kindClause: String
        var kindValues: [SQLiteValue] = []
        if let kinds, !kinds.isEmpty {
            let names = kinds.map { $0.rawValue }.sorted()
            kindClause = " AND kind IN (" + names.map { _ in "?" }.joined(separator: ",") + ")"
            kindValues = names.map(SQLiteValue.text)
        } else { kindClause = "" }
        var candidate:UUID?
        try query("SELECT id FROM jobs WHERE ((state IN ('queued','retrying') AND (next_attempt IS NULL OR next_attempt<=?)) OR (state='running' AND lease_expires<=?)) AND (object_id IS NULL OR EXISTS (SELECT 1 FROM object_visibility ov WHERE ov.object_id=jobs.object_id AND ov.ready=1))\(kindClause) ORDER BY created_at LIMIT 1", [.double(now.timeIntervalSinceReferenceDate), .double(now.timeIntervalSinceReferenceDate)] + kindValues) { r in
            candidate=r.text(0).flatMap{UUID(uuidString:$0)}
        }
        guard let candidate else{return nil}
        let token=UUID()
        try run("UPDATE jobs SET state='running',attempts=attempts+1,lease_owner=?,lease_token=?,lease_expires=?,updated_at=? WHERE id=? AND ((state IN ('queued','retrying') AND (next_attempt IS NULL OR next_attempt<=?)) OR (state='running' AND lease_expires<=?)) AND (object_id IS NULL OR EXISTS (SELECT 1 FROM object_visibility ov WHERE ov.object_id=jobs.object_id AND ov.ready=1))\(kindClause)", [.text(owner),.text(token.uuidString),.double(now.addingTimeInterval(leaseDuration).timeIntervalSinceReferenceDate),.double(now.timeIntervalSinceReferenceDate),.text(candidate.uuidString),.double(now.timeIntervalSinceReferenceDate),.double(now.timeIntervalSinceReferenceDate)] + kindValues)
        guard sqlite3_changes(db)==1 else{return nil};return try jobLocked(candidate)
    }}}
    public func heartbeatJob(id:UUID,leaseToken:UUID,now:Date=Date(),leaseDuration:TimeInterval=120)throws{try sync{try run("UPDATE jobs SET lease_expires=?,updated_at=? WHERE id=? AND state='running' AND lease_token=? AND lease_expires>?",[.double(now.addingTimeInterval(leaseDuration).timeIntervalSinceReferenceDate),.double(now.timeIntervalSinceReferenceDate),.text(id.uuidString),.text(leaseToken.uuidString),.double(now.timeIntervalSinceReferenceDate)]);guard sqlite3_changes(db)==1 else{throw VaultStorageError.invalidTransition}}}
    public func makeJobReady(id:UUID,now:Date=Date())throws{try sync{try run("UPDATE jobs SET next_attempt=NULL,updated_at=? WHERE id=? AND state='retrying'",[.double(now.timeIntervalSinceReferenceDate),.text(id.uuidString)])}}
    public func transitionJob(id:UUID,leaseToken:UUID?=nil,state:VaultJobState,error:String?=nil,nextAttemptAt:Date?=nil,now:Date=Date())throws{try sync{try transaction{guard let job=try jobLocked(id)else{throw VaultStorageError.missingObject};guard legal(job.state,state)else{throw VaultStorageError.invalidTransition};let common:[SQLiteValue]=[.text(state.rawValue),error.map(SQLiteValue.text) ?? .null,nextAttemptAt.map{$0.timeIntervalSinceReferenceDate}.map(SQLiteValue.double) ?? .null,.double(now.timeIntervalSinceReferenceDate),.text(id.uuidString)];if job.state == .running{guard let leaseToken,job.leaseToken==leaseToken,let expiry=job.leaseExpiresAt,expiry>now else{throw VaultStorageError.invalidTransition};try run("UPDATE jobs SET state=?,last_error=?,next_attempt=?,updated_at=?,lease_owner=NULL,lease_token=NULL,lease_expires=NULL WHERE id=? AND state='running' AND lease_token=? AND lease_expires>?",common+[.text(leaseToken.uuidString),.double(now.timeIntervalSinceReferenceDate)])}else{try run("UPDATE jobs SET state=?,last_error=?,next_attempt=?,updated_at=?,lease_owner=NULL,lease_token=NULL,lease_expires=NULL WHERE id=? AND state=? AND updated_at=?",common+[.text(job.state.rawValue),.double(job.updatedAt.timeIntervalSinceReferenceDate)])};guard sqlite3_changes(db)==1 else{throw VaultStorageError.invalidTransition};return ()}}}
    private func legal(_ old:VaultJobState,_ new:VaultJobState)->Bool{switch(old,new){case(.queued,.running),(.queued,.cancelled),(.retrying,.running),(.retrying,.cancelled),(.running,.succeeded),(.running,.retrying),(.running,.failed),(.running,.cancelled):return true;default:return false}}

    public func putEncryptedArtifact(_ artifact:VaultEncryptedArtifact)throws{guard artifact.vaultID==configuration.vaultID else{throw VaultStorageError.invalidArtifact};let validated=try VaultEncryptedArtifact(kind:artifact.kind,vaultID:artifact.vaultID,revision:artifact.revision,rootVersion:artifact.rootVersion,encryptedFrames:artifact.encryptedFrames);let payload=try JSONEncoder().encode(validated.encryptedFrames);try sync{try run("INSERT INTO encrypted_artifacts(kind,vault_id,object_id,payload,revision,root_version,updated_at) VALUES(?,?,?,?,?,?,?) ON CONFLICT(kind) DO UPDATE SET vault_id=excluded.vault_id,object_id=excluded.object_id,payload=excluded.payload,revision=excluded.revision,root_version=excluded.root_version,updated_at=excluded.updated_at",[.text(validated.kind.rawValue),.text(validated.vaultID),.text(validated.objectID.rawValue.uuidString),.blob(payload),.text(validated.revision.uuidString),.int(Int64(validated.rootVersion)),.double(Date().timeIntervalSinceReferenceDate)])}}
    public func encryptedArtifact(_ kind:VaultEncryptedArtifact.Kind)throws->VaultEncryptedArtifact?{try sync{var artifact:VaultEncryptedArtifact?;try query("SELECT vault_id,object_id,payload,revision,root_version FROM encrypted_artifacts WHERE kind=?",[.text(kind.rawValue)]){r in guard r.text(0)==configuration.vaultID,let expectedObject=UUID(uuidString:r.text(1) ?? ""),let data=r.blob(2),let frames=try?JSONDecoder().decode([Data].self,from:data),let revision=UUID(uuidString:r.text(3) ?? "")else{throw VaultStorageError.invalidArtifact};let decoded=try VaultEncryptedArtifact(kind:kind,vaultID:configuration.vaultID,revision:revision,rootVersion:UInt32(r.int(4)),encryptedFrames:frames);guard decoded.objectID.rawValue==expectedObject else{throw VaultStorageError.invalidArtifact};artifact=decoded};return artifact}}

    public func removeDownloadedMaterial(for identity:VaultRemoteObjectIdentity)throws{try sync{
        switch identity.kind {
        case .content:
            guard let object=try objectLocked(identity.objectID),object.revision==identity.revision else{return}
            try transaction{try enqueueCleanupLocked(identity.objectID)};try drainPendingCleanup()
        case .metadata,.manifest,.index:
            let kind=identity.kind == .index ? "index":"manifest"
            try run("DELETE FROM encrypted_artifacts WHERE kind=? AND object_id=? AND revision=?",[.text(kind),.text(identity.objectID.rawValue.uuidString),.text(identity.revision.uuidString)])
        }
    }}

    public func integrityCheck()throws->String{try sync{var value="";try query("PRAGMA integrity_check"){r in value=r.text(0) ?? ""};return value}}
    public func foreignKeysEnabled()throws->Bool{try sync{try scalar("PRAGMA foreign_keys")==1}}
    public func journalMode()throws->String{try sync{var value="";try query("PRAGMA journal_mode"){r in value=r.text(0) ?? ""};return value}}

    public func extractionArtifact(objectID: VaultObjectID, revision: UUID, modelVersion: String) throws -> Data? {
        try sync {
            var result: Data?
            try query("SELECT payload FROM extraction_artifacts WHERE object_id=? AND revision=? AND model_version=?", [
                .text(objectID.rawValue.uuidString), .text(revision.uuidString), .text(modelVersion)
            ]) { row in result = row.blob(0) }
            return result
        }
    }

    public func putExtractionArtifact(_ data: Data, objectID: VaultObjectID, revision: UUID, modelVersion: String) throws {
        try sync {
            try run("INSERT INTO extraction_artifacts(object_id,revision,model_version,payload,updated_at) VALUES(?,?,?,?,?) ON CONFLICT(object_id,revision,model_version) DO UPDATE SET payload=excluded.payload,updated_at=excluded.updated_at", [
                .text(objectID.rawValue.uuidString), .text(revision.uuidString), .text(modelVersion), .blob(data), .double(Date().timeIntervalSinceReferenceDate)
            ])
        }
    }

    public func removeExtractionArtifacts(for objectID: VaultObjectID) throws {
        try sync { try run("DELETE FROM extraction_artifacts WHERE object_id=?", [.text(objectID.rawValue.uuidString)]) }
    }

    /// Enqueues one idempotent index job.  The revision and model version are
    /// part of the key, so a new file revision or model automatically gets a
    /// fresh job while repeated scheduling remains harmless.
    public func enqueueExtractionJob(objectID: VaultObjectID, revision: UUID, modelVersion: String, now: Date = Date()) throws {
        let key = "index:\(objectID.rawValue.uuidString):\(revision.uuidString):\(modelVersion)"
        try enqueue(VaultJob(kind: .index, objectID: objectID, createdAt: now, updatedAt: now,
                             idempotencyKey: key, revision: revision))
    }
    public func enqueueExtractionJob(objectID: VaultObjectID, revision: UUID, modelVersion: String) throws {
        try enqueueExtractionJob(objectID: objectID, revision: revision, modelVersion: modelVersion, now: Date())
    }
    public func beginExtractionJob(objectID: VaultObjectID, revision: UUID, modelVersion: String,
                                   owner: String, now: Date, leaseDuration: TimeInterval = 120) throws -> VaultExtractionJobLease {
        try sync { try transaction {
            let key = "index:\(objectID.rawValue.uuidString):\(revision.uuidString):\(modelVersion)"
            let candidateID = UUID()
            try run("INSERT OR IGNORE INTO jobs(id,idempotency_key,kind,object_id,state,attempts,next_attempt,last_error,created_at,updated_at,lease_owner,lease_token,lease_expires) VALUES(?,?,?,?,?,?,?,?,?,?,NULL,NULL,NULL)", [
                .text(candidateID.uuidString), .text(key), .text(VaultJobKind.index.rawValue),
                .text(objectID.rawValue.uuidString), .text(VaultJobState.queued.rawValue), .int(0), .null, .null,
                .double(now.timeIntervalSinceReferenceDate), .double(now.timeIntervalSinceReferenceDate)
            ])
            var jobID: UUID?
            var state: VaultJobState?
            var leaseExpiry: Date?
            try query("SELECT id,state,lease_expires FROM jobs WHERE idempotency_key=?", [.text(key)]) { row in
                jobID = row.text(0).flatMap(UUID.init(uuidString:)); state = row.text(1).flatMap(VaultJobState.init(rawValue:)); leaseExpiry = row.optionalDouble(2).map(Date.init(timeIntervalSinceReferenceDate:))
            }
            guard let jobID, let state else { throw VaultStorageError.missingObject }
            if state == .succeeded || state == .failed || state == .cancelled {
                try run("UPDATE jobs SET state='queued',next_attempt=NULL,last_error=NULL,lease_owner=NULL,lease_token=NULL,lease_expires=NULL,updated_at=? WHERE id=?", [.double(now.timeIntervalSinceReferenceDate), .text(jobID.uuidString)])
            } else if state == .running, let leaseExpiry, leaseExpiry > now {
                throw VaultStorageError.invalidTransition
            }
            let token = UUID()
            try run("UPDATE jobs SET state='running',attempts=attempts+1,lease_owner=?,lease_token=?,lease_expires=?,updated_at=? WHERE id=? AND (state IN ('queued','retrying') OR (state='running' AND lease_expires<=?))", [
                .text(owner), .text(token.uuidString), .double(now.addingTimeInterval(leaseDuration).timeIntervalSinceReferenceDate),
                .double(now.timeIntervalSinceReferenceDate), .text(jobID.uuidString), .double(now.timeIntervalSinceReferenceDate)
            ])
            guard sqlite3_changes(db) == 1 else { throw VaultStorageError.invalidTransition }
            return VaultExtractionJobLease(jobID: jobID, owner: owner, leaseToken: token)
        }}
    }
    public func transitionExtractionJob(_ lease: VaultExtractionJobLease, to state: VaultJobState,
                                        error: String?, retryAt: Date?, now: Date) throws {
        guard let token = lease.leaseToken else { throw VaultStorageError.invalidTransition }
        try transitionJob(id: lease.jobID, leaseToken: token, state: state, error: error, nextAttemptAt: retryAt, now: now)
    }

    private func hasColumn(_ table: String, _ column: String) throws -> Bool {
        var found = false
        try query("PRAGMA table_info(\(table))") { row in
            if row.text(1) == column { found = true }
        }
        return found
    }

    private func migrate() throws {
        try execute("BEGIN EXCLUSIVE")
        do {
            var version = try scalar("PRAGMA user_version")
            if version == 0 {
                try execute("CREATE TABLE IF NOT EXISTS objects(id TEXT PRIMARY KEY,revision TEXT NOT NULL,logical_time INTEGER NOT NULL CHECK(logical_time>=0),device_id TEXT NOT NULL,size INTEGER NOT NULL CHECK(size>=0),content_type TEXT,created_at REAL NOT NULL,updated_at REAL NOT NULL,accessed_at REAL NOT NULL,tombstone INTEGER NOT NULL CHECK(tombstone IN(0,1)));CREATE TABLE IF NOT EXISTS tombstones(id TEXT PRIMARY KEY,revision TEXT NOT NULL,logical_time INTEGER NOT NULL CHECK(logical_time>=0),device_id TEXT NOT NULL,deleted_at REAL NOT NULL);CREATE TABLE IF NOT EXISTS cache(object_id TEXT PRIMARY KEY REFERENCES objects(id) ON DELETE CASCADE,bytes INTEGER NOT NULL CHECK(bytes>=0),full_content INTEGER NOT NULL CHECK(full_content IN(0,1)),last_accessed REAL NOT NULL,created_at REAL NOT NULL,pinned INTEGER NOT NULL CHECK(pinned IN(0,1)),supports_eviction INTEGER NOT NULL DEFAULT 1 CHECK(supports_eviction IN(0,1)));CREATE TABLE IF NOT EXISTS cache_activity(object_id TEXT PRIMARY KEY REFERENCES objects(id) ON DELETE CASCADE,active_preview INTEGER NOT NULL DEFAULT 0 CHECK(active_preview IN(0,1)),updated_at REAL NOT NULL);CREATE TABLE IF NOT EXISTS jobs(id TEXT PRIMARY KEY,idempotency_key TEXT NOT NULL UNIQUE,kind TEXT NOT NULL CHECK(kind IN('importFile','index','upload','download','delete')),object_id TEXT REFERENCES objects(id) ON DELETE CASCADE,state TEXT NOT NULL CHECK(state IN('queued','running','retrying','succeeded','failed','cancelled')),attempts INTEGER NOT NULL CHECK(attempts>=0),next_attempt REAL,last_error TEXT,created_at REAL NOT NULL,updated_at REAL NOT NULL,lease_owner TEXT,lease_expires REAL,CHECK((state='running')=(lease_owner IS NOT NULL AND lease_expires IS NOT NULL)));CREATE INDEX IF NOT EXISTS jobs_ready ON jobs(state,next_attempt,lease_expires)")
                version = 1
            }
            if version == 1 {
                try execute("DROP TABLE IF EXISTS encrypted_artifacts;CREATE TABLE encrypted_artifacts(kind TEXT PRIMARY KEY CHECK(kind IN('manifest','index')),vault_id TEXT NOT NULL,object_id TEXT NOT NULL,payload BLOB NOT NULL,revision TEXT NOT NULL,root_version INTEGER NOT NULL CHECK(root_version>0),updated_at REAL NOT NULL);CREATE TABLE IF NOT EXISTS pending_file_cleanup(object_id TEXT PRIMARY KEY,path TEXT NOT NULL,created_at REAL NOT NULL);PRAGMA user_version=2")
                version = 2
            }
            if version == 2 {
                try execute("ALTER TABLE pending_file_cleanup RENAME TO pending_file_cleanup_v2;CREATE TABLE pending_file_cleanup(marker_id TEXT PRIMARY KEY,object_id TEXT NOT NULL,revision TEXT NOT NULL,path_token TEXT NOT NULL,created_at REAL NOT NULL,UNIQUE(object_id,revision,path_token));INSERT INTO pending_file_cleanup(marker_id,object_id,revision,path_token,created_at) SELECT lower(hex(randomblob(16))),p.object_id,COALESCE(o.revision,''),'',p.created_at FROM pending_file_cleanup_v2 p LEFT JOIN objects o ON o.id=p.object_id;DROP TABLE pending_file_cleanup_v2;PRAGMA user_version=3")
                version = 3
            }
            if version == 3 {
                try execute("CREATE TABLE IF NOT EXISTS extraction_artifacts(object_id TEXT NOT NULL,revision TEXT NOT NULL,model_version TEXT NOT NULL,payload BLOB NOT NULL,updated_at REAL NOT NULL,PRIMARY KEY(object_id,revision,model_version));ALTER TABLE jobs ADD COLUMN lease_token TEXT;ALTER TABLE jobs ADD COLUMN revision TEXT;ALTER TABLE jobs ADD COLUMN backend_key TEXT;ALTER TABLE jobs ADD COLUMN payload_generation TEXT;CREATE INDEX IF NOT EXISTS jobs_backend_ready ON jobs(backend_key,state,next_attempt);PRAGMA user_version=4")
                version = 4
            }
            if version == 4 {
                // Stage 3 databases already have extraction_artifacts but not
                // the Stage 4 lease columns. Add any missing columns before
                // rebuilding the CHECK-constrained jobs table.
                for (name, definition) in [("lease_token", "TEXT"), ("revision", "TEXT"), ("backend_key", "TEXT"), ("payload_generation", "TEXT")] {
                    if try !hasColumn("jobs", name) { try execute("ALTER TABLE jobs ADD COLUMN \(name) \(definition)") }
                }
                try execute("ALTER TABLE jobs RENAME TO jobs_v4;CREATE TABLE jobs(id TEXT PRIMARY KEY,idempotency_key TEXT NOT NULL UNIQUE,kind TEXT NOT NULL CHECK(kind IN('importFile','index','upload','download','delete')),object_id TEXT,state TEXT NOT NULL CHECK(state IN('queued','running','retrying','succeeded','failed','cancelled')),attempts INTEGER NOT NULL CHECK(attempts>=0),next_attempt REAL,last_error TEXT,created_at REAL NOT NULL,updated_at REAL NOT NULL,lease_owner TEXT,lease_token TEXT,lease_expires REAL,revision TEXT,backend_key TEXT,payload_generation TEXT,remote_object_kind TEXT,expected_remote_revision TEXT,CHECK((state='running')=(lease_owner IS NOT NULL AND lease_token IS NOT NULL AND lease_expires IS NOT NULL)));INSERT INTO jobs(id,idempotency_key,kind,object_id,state,attempts,next_attempt,last_error,created_at,updated_at,lease_owner,lease_token,lease_expires,revision,backend_key,payload_generation) SELECT id,idempotency_key,kind,object_id,state,attempts,next_attempt,last_error,created_at,updated_at,lease_owner,lease_token,lease_expires,revision,backend_key,payload_generation FROM jobs_v4;DROP TABLE jobs_v4;CREATE INDEX jobs_ready ON jobs(state,next_attempt,lease_expires);CREATE INDEX jobs_backend_ready ON jobs(backend_key,state,next_attempt);CREATE INDEX jobs_object_pending ON jobs(object_id,state);PRAGMA user_version=5")
                version = 5
            }
            if version == 5 {
                // Stage 4A databases can arrive here without the extraction
                // table because its earlier branch did not own that feature.
                try execute("CREATE TABLE IF NOT EXISTS extraction_artifacts(object_id TEXT NOT NULL,revision TEXT NOT NULL,model_version TEXT NOT NULL,payload BLOB NOT NULL,updated_at REAL NOT NULL,PRIMARY KEY(object_id,revision,model_version))")
                if try !hasColumn("cache", "supports_eviction") { try execute("ALTER TABLE cache ADD COLUMN supports_eviction INTEGER NOT NULL DEFAULT 1 CHECK(supports_eviction IN(0,1))") }
                try execute("CREATE TABLE IF NOT EXISTS cache_activity(object_id TEXT PRIMARY KEY REFERENCES objects(id) ON DELETE CASCADE,active_preview INTEGER NOT NULL DEFAULT 0 CHECK(active_preview IN(0,1)),updated_at REAL NOT NULL);PRAGMA user_version=6")
                version = 6
            }
            if version == 6 {
                // Keep this branch idempotent for databases created by an
                // interrupted Stage 5 migration.
                try execute("CREATE TABLE IF NOT EXISTS cache_activity(object_id TEXT PRIMARY KEY REFERENCES objects(id) ON DELETE CASCADE,active_preview INTEGER NOT NULL DEFAULT 0 CHECK(active_preview IN(0,1)),updated_at REAL NOT NULL)")
            }
            if version == 6 {
                try execute("CREATE TABLE IF NOT EXISTS object_visibility(object_id TEXT PRIMARY KEY REFERENCES objects(id) ON DELETE CASCADE,ready INTEGER NOT NULL DEFAULT 0 CHECK(ready IN(0,1)),updated_at REAL NOT NULL);CREATE INDEX IF NOT EXISTS object_visibility_ready ON object_visibility(ready);PRAGMA user_version=7")
                version = 7
            }
            guard version == 7 else { throw VaultStorageError.sqlite("unsupported schema \(version)") }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }
    private func objectLocked(_ id:VaultObjectID)throws->VaultObjectRecord?{var result:VaultObjectRecord?;try query("SELECT revision,logical_time,device_id,size,content_type,created_at,updated_at,accessed_at,tombstone FROM objects WHERE id=?",[.text(id.rawValue.uuidString)]){r in result=try decodeRecord(id,r)};return result}
    private func markObjectReadyLocked(_ id: VaultObjectID) throws {
        guard try objectLocked(id) != nil else { throw VaultStorageError.missingObject }
        try run("INSERT INTO object_visibility(object_id,ready,updated_at) VALUES(?,1,?) ON CONFLICT(object_id) DO UPDATE SET ready=1,updated_at=excluded.updated_at", [.text(id.rawValue.uuidString), .double(Date().timeIntervalSinceReferenceDate)])
    }
    private func jobObjectIsReadyLocked(_ job: VaultJob) throws -> Bool {
        guard let objectID = job.objectID else { return true }
        var ready = false
        try query("SELECT ready FROM object_visibility WHERE object_id=?", [.text(objectID.rawValue.uuidString)]) { ready = $0.int(0) != 0 }
        return ready
    }
    private func tombstoneLocked(_ id:VaultObjectID)throws->VaultTombstone?{var result:VaultTombstone?;try query("SELECT revision,logical_time,device_id,deleted_at FROM tombstones WHERE id=?",[.text(id.rawValue.uuidString)]){r in guard let rev=UUID(uuidString:r.text(0) ?? "")else{throw VaultStorageError.sqlite("tombstone")};result=VaultTombstone(id:id,revision:rev,logicalTime:r.int(1),deletedAt:Date(timeIntervalSinceReferenceDate:r.double(3)),deviceID:r.text(2) ?? "")};return result}
    private func decodeRecord(_ id:VaultObjectID,_ r:SQLiteRow,offset:Int=0)throws->VaultObjectRecord{guard let rev=UUID(uuidString:r.text(offset) ?? "")else{throw VaultStorageError.sqlite("revision")};return VaultObjectRecord(id:id,revision:rev,logicalTime:r.int(offset+1),size:r.int(offset+3),contentType:r.text(offset+4),createdAt:Date(timeIntervalSinceReferenceDate:r.double(offset+5)),updatedAt:Date(timeIntervalSinceReferenceDate:r.double(offset+6)),accessedAt:Date(timeIntervalSinceReferenceDate:r.double(offset+7)),isTombstone:r.int(offset+8) != 0,deviceID:r.text(offset+2) ?? "")}
    private func jobLocked(_ id:UUID)throws->VaultJob?{var result:VaultJob?;try query("SELECT kind,object_id,state,attempts,next_attempt,last_error,created_at,updated_at,idempotency_key,lease_owner,lease_token,lease_expires,revision,backend_key,payload_generation,remote_object_kind,expected_remote_revision FROM jobs WHERE id=?",[.text(id.uuidString)]){r in guard let kind=VaultJobKind(rawValue:r.text(0) ?? ""),let state=VaultJobState(rawValue:r.text(2) ?? "")else{throw VaultStorageError.sqlite("job")};result=VaultJob(id:id,kind:kind,objectID:r.text(1).flatMap{UUID(uuidString:$0)}.map{VaultObjectID(rawValue:$0)},state:state,attempts:Int(r.int(3)),nextAttemptAt:r.optionalDouble(4).map{Date(timeIntervalSinceReferenceDate:$0)},lastError:r.text(5),createdAt:Date(timeIntervalSinceReferenceDate:r.double(6)),updatedAt:Date(timeIntervalSinceReferenceDate:r.double(7)),idempotencyKey:r.text(8),revision:r.text(12).flatMap{UUID(uuidString:$0)},backendKey:r.text(13),payloadGeneration:r.text(14),remoteObjectKind:r.text(15),expectedRemoteRevision:r.text(16).flatMap{UUID(uuidString:$0)},leaseOwner:r.text(9),leaseToken:r.text(10).flatMap{UUID(uuidString:$0)},leaseExpiresAt:r.optionalDouble(11).map{Date(timeIntervalSinceReferenceDate:$0)})};return result}
    private func compare(_ lt:Int64,_ ld:String,_ lr:UUID,_ rt:Int64,_ rd:String,_ rr:UUID)->Int{if lt != rt{return lt < rt ? -1:1};if ld != rd{return ld < rd ? -1:1};return lr.uuidString == rr.uuidString ? 0:(lr.uuidString < rr.uuidString ? -1:1)}
    private func contentURL(_ id:VaultObjectID)->URL{contentDirectory.appendingPathComponent(id.rawValue.uuidString).appendingPathComponent("content")}
    private func generationURL(_ id:VaultObjectID)->URL{contentDirectory.appendingPathComponent(id.rawValue.uuidString).appendingPathComponent(".content-generation")}
    private func removeContentLocked(_ id:VaultObjectID)throws{let dir=contentDirectory.appendingPathComponent(id.rawValue.uuidString);if fileManager.fileExists(atPath:dir.path){try fileManager.removeItem(at:dir)}}
    private func enqueueCleanupLocked(_ id:VaultObjectID)throws{
        let revision=try objectLocked(id)?.revision.uuidString ?? ""
        let token=(try?String(contentsOf:generationURL(id),encoding:.utf8)) ?? ""
        try run("INSERT OR IGNORE INTO pending_file_cleanup(marker_id,object_id,revision,path_token,created_at) VALUES(?,?,?,?,?)",[.text(UUID().uuidString),.text(id.rawValue.uuidString),.text(revision),.text(token),.double(Date().timeIntervalSinceReferenceDate)])
    }
    private func drainPendingCleanup()throws{
        var entries=[(String,VaultObjectID,String,String)]();try query("SELECT marker_id,object_id,revision,path_token FROM pending_file_cleanup ORDER BY created_at"){r in if let marker=r.text(0),let raw=r.text(1),let uuid=UUID(uuidString:raw),let revision=r.text(2),let token=r.text(3){entries.append((marker,VaultObjectID(rawValue:uuid),revision,token))}}
        for(marker,id,revision,token)in entries{
            let currentRevision=try objectLocked(id)?.revision.uuidString ?? "",currentToken=(try?String(contentsOf:generationURL(id),encoding:.utf8)) ?? ""
            guard currentRevision==revision,currentToken==token else{try run("DELETE FROM pending_file_cleanup WHERE marker_id=?",[.text(marker)]);continue}
            let final=contentURL(id),generation=generationURL(id);if fileManager.fileExists(atPath:final.path){try fileManager.removeItem(at:final)};if fileManager.fileExists(atPath:generation.path){try fileManager.removeItem(at:generation)}
            try run("DELETE FROM pending_file_cleanup WHERE marker_id=?",[.text(marker)])
        }
    }
    private func repairFileLayout()throws{
        guard let children=try?fileManager.contentsOfDirectory(at:contentDirectory,includingPropertiesForKeys:nil)else{return}
        for dir in children{
            guard let rawID=UUID(uuidString:dir.lastPathComponent)else{continue};let id=VaultObjectID(rawValue:rawID)
            let final=dir.appendingPathComponent("content"),generation=dir.appendingPathComponent(".content-generation"),previous=dir.appendingPathComponent(".previous"),previousGeneration=dir.appendingPathComponent(".previous-generation")
            let items=(try?fileManager.contentsOfDirectory(at:dir,includingPropertiesForKeys:nil)) ?? []
            for item in items where item.lastPathComponent.hasPrefix(".staging-") || item.lastPathComponent.hasPrefix(".generation-staging-"){try fileManager.removeItem(at:item)}
            let currentRevision=try objectLocked(id)?.revision.uuidString
            let finalValid=try installedGenerationIsValid(content:final,generation:generation,expectedRevision:currentRevision)
            if fileManager.fileExists(atPath:previous.path){
                if finalValid{
                    try fileManager.removeItem(at:previous);if fileManager.fileExists(atPath:previousGeneration.path){try fileManager.removeItem(at:previousGeneration)}
                }else{
                    if fileManager.fileExists(atPath:final.path){try fileManager.removeItem(at:final)};if fileManager.fileExists(atPath:generation.path){try fileManager.removeItem(at:generation)}
                    let previousValid=try installedGenerationIsValid(content:previous,generation:previousGeneration,expectedRevision:nil)
                    if previousValid{
                        try fileManager.moveItem(at:previous,to:final);try fileManager.moveItem(at:previousGeneration,to:generation)
                        VaultSimulatorProtectionLedger.record(final)
                        VaultSimulatorProtectionLedger.record(generation)
                    }
                    else{try fileManager.removeItem(at:previous);if fileManager.fileExists(atPath:previousGeneration.path){try fileManager.removeItem(at:previousGeneration)}}
                }
            }else if !finalValid{
                if fileManager.fileExists(atPath:final.path){try fileManager.removeItem(at:final)};if fileManager.fileExists(atPath:generation.path){try fileManager.removeItem(at:generation)}
            }
        }
    }
    private func installedGenerationIsValid(content:URL,generation:URL,expectedRevision:String?)throws->Bool{
        guard fileManager.fileExists(atPath:content.path),fileManager.fileExists(atPath:generation.path),try protectionApplier.hasRequiredProtection(at:content),try protectionApplier.hasRequiredProtection(at:generation),let contentValues=try?content.resourceValues(forKeys:[.isDirectoryKey,.isSymbolicLinkKey]),contentValues.isDirectory != true,contentValues.isSymbolicLink != true,let markerData=try?readBoundedFile(generation,maximumBytes:256),let marker=String(data:markerData,encoding:.utf8),let separator=marker.firstIndex(of:":") else{return false}
        let digest=String(marker[marker.index(after:separator)...])
        guard digest.count == 64, digest.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else{return false}
        guard expectedRevision.map({String(marker[..<separator])==$0}) ?? true else{return false}
        // The generation marker authenticates the revision, but it must not
        // be trusted as a content digest until the installed bytes agree.
        guard (try? digestFile(content)) == digest else{return false}
        return true
    }
    /// Data Protection is a required postcondition. An attribute being
    /// present (or `.none`) is not sufficient: only the exact class accepted
    /// by the injected applier may reach durable storage.
    private func protect(_ url:URL)throws{
        try protectionApplier.apply(to:url)
        guard try protectionApplier.hasRequiredProtection(at:url) else {
            throw VaultStorageError.protectionRequired
        }
    }
    private func protectDatabaseFiles()throws{for suffix in ["","-wal","-shm"]{let u=URL(fileURLWithPath:databaseURL.path+suffix);if fileManager.fileExists(atPath:u.path){do{try protect(u)}catch{if fileManager.fileExists(atPath:u.path){throw error}}}}}
    private func sync<T>(_ body:()throws->T)throws->T{try queue.sync{let result=try body();try protectDatabaseFiles();return result}}
    private func transaction<T>(_ body:()throws->T)throws->T{try execute("BEGIN IMMEDIATE");do{let value=try body();try execute("COMMIT");return value}catch{try?execute("ROLLBACK");throw error}}
    private func retryingBusy<T>(attempts:Int=12,_ body:()throws->T)throws->T{var attempt=0;while true{do{return try body()}catch let error as VaultStorageError{if case.sqlite(let message)=error,(message.contains("locked")||message.contains("busy")),attempt<attempts{Thread.sleep(forTimeInterval:0.01*Double(attempt+1));attempt+=1;continue};throw error}}}
    private func execute(_ sql:String)throws{var message:UnsafeMutablePointer<CChar>?;let status=sqlite3_exec(db,sql,nil,nil,&message);guard status==SQLITE_OK else{let text=message.map{String(cString:$0)} ?? String(cString:sqlite3_errmsg(db));sqlite3_free(message);throw VaultStorageError.sqlite(text)};sqlite3_free(message)}
    private func scalar(_ sql:String,_ values:[SQLiteValue]=[])throws->Int64{var value:Int64?;try query(sql,values){r in if value==nil{value=r.int(0)}};guard let value else{throw VaultStorageError.sqlite("missing scalar")};return value}
    private func run(_ sql:String,_ values:[SQLiteValue]=[])throws{try statement(sql,values){stmt in let status=sqlite3_step(stmt);guard status==SQLITE_DONE else{throw VaultStorageError.sqlite(String(cString:sqlite3_errmsg(db)))}}}
    private func query(_ sql:String,_ values:[SQLiteValue]=[],body:(SQLiteRow)throws->Void)throws{try statement(sql,values){stmt in while true{let status=sqlite3_step(stmt);if status==SQLITE_DONE{return};guard status==SQLITE_ROW else{throw VaultStorageError.sqlite(String(cString:sqlite3_errmsg(db)))};try body(SQLiteRow(stmt))}}}
    private func statement<T>(_ sql:String,_ values:[SQLiteValue],body:(OpaquePointer)throws->T)throws->T{var stmt:OpaquePointer?;guard sqlite3_prepare_v2(db,sql,-1,&stmt,nil)==SQLITE_OK,let stmt else{throw VaultStorageError.sqlite(String(cString:sqlite3_errmsg(db)))};defer{sqlite3_finalize(stmt)};for(index,value)in values.enumerated(){try value.bind(stmt,Int32(index+1))};return try body(stmt)}

    private func readBoundedFile(_ url: URL, maximumBytes: Int64) throws -> Data {
        guard maximumBytes >= 0, maximumBytes <= Int64(Int.max) else { throw VaultStorageError.invalidArtifact }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var result = Data()
        result.reserveCapacity(Int(min(maximumBytes, 1_048_576)))
        var remaining = maximumBytes
        while remaining > 0 {
            guard let chunk = try handle.read(upToCount: Int(min(remaining, 1_048_576))), !chunk.isEmpty else { break }
            result.append(chunk)
            remaining -= Int64(chunk.count)
        }
        guard remaining >= 0, (try handle.read(upToCount: 1)?.isEmpty != false) else {
            throw VaultStorageError.stagingLimit
        }
        return result
    }
}

extension VaultRepository: VaultObjectStoring { public func data(for id:VaultObjectID)throws->Data?{try readContent(for:id)};public func setData(_ data:Data,for id:VaultObjectID)throws{_=try writeContent(data,for:id)};public func removeData(for id:VaultObjectID)throws{try removeContent(for:id)} }
extension VaultRepository: VaultExtractionArtifactStoring, VaultExtractionJobScheduling, VaultExtractionJobCoordinating {}
private enum SQLiteValue{case null,text(String),int(Int64),double(Double),blob(Data);func bind(_ stmt:OpaquePointer,_ index:Int32)throws{let status:Int32;switch self{case.null:status=sqlite3_bind_null(stmt,index);case.text(let value):status=sqlite3_bind_text(stmt,index,value,-1,SQLITE_TRANSIENT);case.int(let value):status=sqlite3_bind_int64(stmt,index,value);case.double(let value):status=sqlite3_bind_double(stmt,index,value);case.blob(let value):status=value.withUnsafeBytes{sqlite3_bind_blob(stmt,index,$0.baseAddress,Int32(value.count),SQLITE_TRANSIENT)}};guard status==SQLITE_OK else{throw VaultStorageError.sqlite("bind")}}}
private struct SQLiteRow{let stmt:OpaquePointer;init(_ stmt:OpaquePointer){self.stmt=stmt};func text(_ i:Int)->String?{guard let p=sqlite3_column_text(stmt,Int32(i))else{return nil};return String(cString:p)};func int(_ i:Int)->Int64{sqlite3_column_int64(stmt,Int32(i))};func double(_ i:Int)->Double{sqlite3_column_double(stmt,Int32(i))};func optionalDouble(_ i:Int)->Double?{sqlite3_column_type(stmt,Int32(i))==SQLITE_NULL ? nil:double(i)};func blob(_ i:Int)->Data?{guard sqlite3_column_type(stmt,Int32(i)) != SQLITE_NULL,let p=sqlite3_column_blob(stmt,Int32(i))else{return nil};return Data(bytes:p,count:Int(sqlite3_column_bytes(stmt,Int32(i))))}}
private let SQLITE_TRANSIENT=unsafeBitCast(-1,to:sqlite3_destructor_type.self)
private extension FileHandle{func closeAfterSynchronize()throws{try synchronize();try close()}}
private extension UInt32{init(bigEndianBytes bytes:Data.SubSequence){self=bytes.reduce(UInt32(0)){($0<<8)|UInt32($1)}}}
