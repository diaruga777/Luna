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
public struct SystemVaultFileProtectionApplier: VaultFileProtectionApplying {
    public init() {}
    public func apply(to url: URL) throws {
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
    }
    public func hasRequiredProtection(at url: URL) throws -> Bool {
        let value = try FileManager.default.attributesOfItem(atPath: url.path)[.protectionKey]
        if let protection = value as? FileProtectionType { return protection == .completeUntilFirstUserAuthentication }
        if let rawValue = value as? String { return rawValue == FileProtectionType.completeUntilFirstUserAuthentication.rawValue }
        return false
    }
}

public enum VaultStorageError: Error, Equatable, Sendable {
    case appGroupUnavailable, sqlite(String), missingObject, invalidTransition, invalidArtifact, stagingLimit
}
public protocol VaultObjectStoring: Sendable {
    func data(for id: VaultObjectID) throws -> Data?
    func setData(_ data: Data, for id: VaultObjectID) throws
    func removeData(for id: VaultObjectID) throws
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
        try enqueueCleanupLocked(tombstone.id);try run("DELETE FROM cache WHERE object_id=?",[.text(tombstone.id.rawValue.uuidString)]);try run("DELETE FROM jobs WHERE object_id=? AND state NOT IN ('succeeded','failed','cancelled')",[.text(tombstone.id.rawValue.uuidString)]);return true}
        if advanced{try drainPendingCleanup()};return advanced}}

    public func writeContent(_ data:Data,for id:VaultObjectID)throws->URL{try sync{
        guard let object=try objectLocked(id),!object.isTombstone else{throw VaultStorageError.missingObject}
        let dir=contentDirectory.appendingPathComponent(id.rawValue.uuidString,isDirectory:true);try fileManager.createDirectory(at:dir,withIntermediateDirectories:true);try protect(dir)
        let token=UUID().uuidString,staging=dir.appendingPathComponent(".staging-\(token)"),stagingGeneration=dir.appendingPathComponent(".generation-staging-\(token)")
        let final=dir.appendingPathComponent("content"),generation=dir.appendingPathComponent(".content-generation"),backup=dir.appendingPathComponent(".previous"),backupGeneration=dir.appendingPathComponent(".previous-generation")
        guard Int64(data.count)<=cacheQuotaBytes+stagingAllowanceBytes else{throw VaultStorageError.stagingLimit}
        do{
            try data.write(to:staging,options:[.atomic]);try protect(staging);let handle=try FileHandle(forWritingTo:staging);try handle.closeAfterSynchronize()
            try Data("\(object.revision.uuidString):\(token)".utf8).write(to:stagingGeneration,options:[.atomic]);try protect(stagingGeneration);let generationHandle=try FileHandle(forWritingTo:stagingGeneration);try generationHandle.closeAfterSynchronize()
            for oldBackup in [backup,backupGeneration] where fileManager.fileExists(atPath:oldBackup.path){try fileManager.removeItem(at:oldBackup)}
            if fileManager.fileExists(atPath:final.path){try fileManager.moveItem(at:final,to:backup)}
            if fileManager.fileExists(atPath:generation.path){try fileManager.moveItem(at:generation,to:backupGeneration)}
            do{
                // Data Protection attributes were applied and fsynced on staging and
                // survive rename. Never install first and protect afterward.
                try fileManager.moveItem(at:staging,to:final)
                try fileManager.moveItem(at:stagingGeneration,to:generation)
                for oldBackup in [backup,backupGeneration] where fileManager.fileExists(atPath:oldBackup.path){try fileManager.removeItem(at:oldBackup)}
            }catch{
                if fileManager.fileExists(atPath:final.path){try?fileManager.removeItem(at:final)}
                if fileManager.fileExists(atPath:generation.path){try?fileManager.removeItem(at:generation)}
                if fileManager.fileExists(atPath:backup.path){try fileManager.moveItem(at:backup,to:final)}
                if fileManager.fileExists(atPath:backupGeneration.path){try fileManager.moveItem(at:backupGeneration,to:generation)}
                throw error
            }
            return final
        }catch{try?fileManager.removeItem(at:staging);try?fileManager.removeItem(at:stagingGeneration);throw error}
    }}
    public func readContent(for id:VaultObjectID)throws->Data?{try sync{fileManager.contents(atPath:contentURL(id).path)}}
    public func removeContent(for id:VaultObjectID)throws{try sync{try transaction{try enqueueCleanupLocked(id)};try drainPendingCleanup()}}

    public func putCache(_ entry:VaultCacheEntry,now:Date=Date())throws{try sync{var downgraded=false;try transaction{var wasFull=false;try query("SELECT full_content FROM cache WHERE object_id=?",[.text(entry.objectID.rawValue.uuidString)]){wasFull=$0.int(0) != 0};downgraded=wasFull && !entry.fullContent;if downgraded{try enqueueCleanupLocked(entry.objectID)};try run("INSERT INTO cache(object_id,bytes,full_content,last_accessed,created_at,pinned) VALUES(?,?,?,?,?,?) ON CONFLICT(object_id) DO UPDATE SET bytes=excluded.bytes,full_content=excluded.full_content,last_accessed=excluded.last_accessed,pinned=excluded.pinned",[.text(entry.objectID.rawValue.uuidString),.int(entry.byteCount),.int(entry.fullContent ? 1:0),.double(entry.lastAccessedAt.timeIntervalSinceReferenceDate),.double(entry.createdAt.timeIntervalSinceReferenceDate),.int(entry.pinned ? 1:0)])};if downgraded{try drainPendingCleanup()};try evictLocked(now:now)}}
    public func cacheEntries()throws->[VaultCacheEntry]{try sync{var result=[VaultCacheEntry]();try query("SELECT object_id,bytes,full_content,last_accessed,created_at,pinned FROM cache ORDER BY last_accessed DESC"){r in guard let u=UUID(uuidString:r.text(0) ?? "")else{throw VaultStorageError.sqlite("cache id")};result.append(VaultCacheEntry(objectID:VaultObjectID(rawValue:u),byteCount:r.int(1),fullContent:r.int(2) != 0,lastAccessedAt:Date(timeIntervalSinceReferenceDate:r.double(3)),createdAt:Date(timeIntervalSinceReferenceDate:r.double(4)),pinned:r.int(5) != 0))};return result}}
    public func setPinned(_ id:VaultObjectID,pinned:Bool)throws{try sync{try run("UPDATE cache SET pinned=? WHERE object_id=?",[.int(pinned ? 1:0),.text(id.rawValue.uuidString)])}}
    public func evictExpired(now:Date=Date())throws{try sync{try evictLocked(now:now)}}
    private func evictLocked(now:Date)throws{let cutoff=now.addingTimeInterval(-7*86400).timeIntervalSinceReferenceDate
        var expired=[VaultObjectID]();try query("SELECT object_id FROM cache WHERE full_content=1 AND pinned=0 AND last_accessed<? ORDER BY last_accessed",[.double(cutoff)]){r in if let u=UUID(uuidString:r.text(0) ?? ""){expired.append(VaultObjectID(rawValue:u))}}
        for id in expired{try removeFullCacheLocked(id)}
        while try scalar("SELECT COALESCE(SUM(bytes),0) FROM cache WHERE full_content=1")>cacheQuotaBytes{var victim:VaultObjectID?;try query("SELECT object_id FROM cache WHERE full_content=1 AND pinned=0 ORDER BY last_accessed LIMIT 1"){r in victim=r.text(0).flatMap{UUID(uuidString:$0)}.map{VaultObjectID(rawValue:$0)}};guard let victim else{break};try removeFullCacheLocked(victim)}
    }
    private func removeFullCacheLocked(_ id:VaultObjectID)throws{try transaction{try enqueueCleanupLocked(id);try run("DELETE FROM cache WHERE object_id=? AND full_content=1",[.text(id.rawValue.uuidString)])};try drainPendingCleanup()}

    public func enqueue(_ job:VaultJob)throws{try sync{try run("INSERT OR IGNORE INTO jobs(id,idempotency_key,kind,object_id,state,attempts,next_attempt,last_error,created_at,updated_at,lease_owner,lease_expires) VALUES(?,?,?,?,?,?,?,?,?,?,?,?)",[.text(job.id.uuidString),.text(job.idempotencyKey),.text(job.kind.rawValue),job.objectID.map{$0.rawValue.uuidString}.map(SQLiteValue.text) ?? .null,.text(job.state.rawValue),.int(Int64(job.attempts)),job.nextAttemptAt.map{$0.timeIntervalSinceReferenceDate}.map(SQLiteValue.double) ?? .null,job.lastError.map(SQLiteValue.text) ?? .null,.double(job.createdAt.timeIntervalSinceReferenceDate),.double(job.updatedAt.timeIntervalSinceReferenceDate),job.leaseOwner.map(SQLiteValue.text) ?? .null,job.leaseExpiresAt.map{$0.timeIntervalSinceReferenceDate}.map(SQLiteValue.double) ?? .null])}}
    public func claimNextJob(owner:String,now:Date=Date(),leaseDuration:TimeInterval=120)throws->VaultJob?{try sync{try transaction{
        var candidate:UUID?;try query("SELECT id FROM jobs WHERE (state IN ('queued','retrying') AND (next_attempt IS NULL OR next_attempt<=?)) OR (state='running' AND lease_expires<=?) ORDER BY created_at LIMIT 1",[.double(now.timeIntervalSinceReferenceDate),.double(now.timeIntervalSinceReferenceDate)]){r in candidate=r.text(0).flatMap{UUID(uuidString:$0)}};guard let candidate else{return nil}
        try run("UPDATE jobs SET state='running',attempts=attempts+1,lease_owner=?,lease_expires=?,updated_at=? WHERE id=? AND ((state IN ('queued','retrying') AND (next_attempt IS NULL OR next_attempt<=?)) OR (state='running' AND lease_expires<=?))",[.text(owner),.double(now.addingTimeInterval(leaseDuration).timeIntervalSinceReferenceDate),.double(now.timeIntervalSinceReferenceDate),.text(candidate.uuidString),.double(now.timeIntervalSinceReferenceDate),.double(now.timeIntervalSinceReferenceDate)])
        guard sqlite3_changes(db)==1 else{return nil};return try jobLocked(candidate)
    }}}
    public func heartbeatJob(id:UUID,owner:String,now:Date=Date(),leaseDuration:TimeInterval=120)throws{try sync{try run("UPDATE jobs SET lease_expires=?,updated_at=? WHERE id=? AND state='running' AND lease_owner=? AND lease_expires>?",[.double(now.addingTimeInterval(leaseDuration).timeIntervalSinceReferenceDate),.double(now.timeIntervalSinceReferenceDate),.text(id.uuidString),.text(owner),.double(now.timeIntervalSinceReferenceDate)]);guard sqlite3_changes(db)==1 else{throw VaultStorageError.invalidTransition}}}
    public func transitionJob(id:UUID,owner:String?=nil,state:VaultJobState,error:String?=nil,nextAttemptAt:Date?=nil,now:Date=Date())throws{try sync{try transaction{guard let job=try jobLocked(id)else{throw VaultStorageError.missingObject};guard legal(job.state,state)else{throw VaultStorageError.invalidTransition};let common:[SQLiteValue]=[.text(state.rawValue),error.map(SQLiteValue.text) ?? .null,nextAttemptAt.map{$0.timeIntervalSinceReferenceDate}.map(SQLiteValue.double) ?? .null,.double(now.timeIntervalSinceReferenceDate),.text(id.uuidString)];if job.state == .running{guard let owner,job.leaseOwner==owner,let expiry=job.leaseExpiresAt,expiry>now else{throw VaultStorageError.invalidTransition};try run("UPDATE jobs SET state=?,last_error=?,next_attempt=?,updated_at=?,lease_owner=NULL,lease_expires=NULL WHERE id=? AND state='running' AND lease_owner=? AND lease_expires>?",common+[.text(owner),.double(now.timeIntervalSinceReferenceDate)])}else{try run("UPDATE jobs SET state=?,last_error=?,next_attempt=?,updated_at=?,lease_owner=NULL,lease_expires=NULL WHERE id=? AND state=? AND updated_at=?",common+[.text(job.state.rawValue),.double(job.updatedAt.timeIntervalSinceReferenceDate)])};guard sqlite3_changes(db)==1 else{throw VaultStorageError.invalidTransition};return ()}}}
    private func legal(_ old:VaultJobState,_ new:VaultJobState)->Bool{switch(old,new){case(.queued,.running),(.queued,.cancelled),(.retrying,.running),(.retrying,.cancelled),(.running,.succeeded),(.running,.retrying),(.running,.failed),(.running,.cancelled):return true;default:return false}}

    public func putEncryptedArtifact(_ artifact:VaultEncryptedArtifact)throws{guard artifact.vaultID==configuration.vaultID else{throw VaultStorageError.invalidArtifact};let validated=try VaultEncryptedArtifact(kind:artifact.kind,vaultID:artifact.vaultID,revision:artifact.revision,rootVersion:artifact.rootVersion,encryptedFrames:artifact.encryptedFrames);let payload=try JSONEncoder().encode(validated.encryptedFrames);try sync{try run("INSERT INTO encrypted_artifacts(kind,vault_id,object_id,payload,revision,root_version,updated_at) VALUES(?,?,?,?,?,?,?) ON CONFLICT(kind) DO UPDATE SET vault_id=excluded.vault_id,object_id=excluded.object_id,payload=excluded.payload,revision=excluded.revision,root_version=excluded.root_version,updated_at=excluded.updated_at",[.text(validated.kind.rawValue),.text(validated.vaultID),.text(validated.objectID.rawValue.uuidString),.blob(payload),.text(validated.revision.uuidString),.int(Int64(validated.rootVersion)),.double(Date().timeIntervalSinceReferenceDate)])}}
    public func encryptedArtifact(_ kind:VaultEncryptedArtifact.Kind)throws->VaultEncryptedArtifact?{try sync{var artifact:VaultEncryptedArtifact?;try query("SELECT vault_id,object_id,payload,revision,root_version FROM encrypted_artifacts WHERE kind=?",[.text(kind.rawValue)]){r in guard r.text(0)==configuration.vaultID,let expectedObject=UUID(uuidString:r.text(1) ?? ""),let data=r.blob(2),let frames=try?JSONDecoder().decode([Data].self,from:data),let revision=UUID(uuidString:r.text(3) ?? "")else{throw VaultStorageError.invalidArtifact};let decoded=try VaultEncryptedArtifact(kind:kind,vaultID:configuration.vaultID,revision:revision,rootVersion:UInt32(r.int(4)),encryptedFrames:frames);guard decoded.objectID.rawValue==expectedObject else{throw VaultStorageError.invalidArtifact};artifact=decoded};return artifact}}

    public func integrityCheck()throws->String{try sync{var value="";try query("PRAGMA integrity_check"){r in value=r.text(0) ?? ""};return value}}
    public func foreignKeysEnabled()throws->Bool{try sync{try scalar("PRAGMA foreign_keys")==1}}
    public func journalMode()throws->String{try sync{var value="";try query("PRAGMA journal_mode"){r in value=r.text(0) ?? ""};return value}}

    private func migrate()throws{try execute("BEGIN EXCLUSIVE");do{var version=try scalar("PRAGMA user_version");if version==0{try execute("CREATE TABLE IF NOT EXISTS objects(id TEXT PRIMARY KEY,revision TEXT NOT NULL,logical_time INTEGER NOT NULL CHECK(logical_time>=0),device_id TEXT NOT NULL,size INTEGER NOT NULL CHECK(size>=0),content_type TEXT,created_at REAL NOT NULL,updated_at REAL NOT NULL,accessed_at REAL NOT NULL,tombstone INTEGER NOT NULL CHECK(tombstone IN(0,1)));CREATE TABLE IF NOT EXISTS tombstones(id TEXT PRIMARY KEY,revision TEXT NOT NULL,logical_time INTEGER NOT NULL CHECK(logical_time>=0),device_id TEXT NOT NULL,deleted_at REAL NOT NULL);CREATE TABLE IF NOT EXISTS cache(object_id TEXT PRIMARY KEY REFERENCES objects(id) ON DELETE CASCADE,bytes INTEGER NOT NULL CHECK(bytes>=0),full_content INTEGER NOT NULL CHECK(full_content IN(0,1)),last_accessed REAL NOT NULL,created_at REAL NOT NULL,pinned INTEGER NOT NULL CHECK(pinned IN(0,1)));CREATE TABLE IF NOT EXISTS jobs(id TEXT PRIMARY KEY,idempotency_key TEXT NOT NULL UNIQUE,kind TEXT NOT NULL CHECK(kind IN('importFile','index','upload','download','delete')),object_id TEXT REFERENCES objects(id) ON DELETE CASCADE,state TEXT NOT NULL CHECK(state IN('queued','running','retrying','succeeded','failed','cancelled')),attempts INTEGER NOT NULL CHECK(attempts>=0),next_attempt REAL,last_error TEXT,created_at REAL NOT NULL,updated_at REAL NOT NULL,lease_owner TEXT,lease_expires REAL,CHECK((state='running')=(lease_owner IS NOT NULL AND lease_expires IS NOT NULL)));CREATE INDEX IF NOT EXISTS jobs_ready ON jobs(state,next_attempt,lease_expires)");version=1};if version==1{try execute("DROP TABLE IF EXISTS encrypted_artifacts;CREATE TABLE encrypted_artifacts(kind TEXT PRIMARY KEY CHECK(kind IN('manifest','index')),vault_id TEXT NOT NULL,object_id TEXT NOT NULL,payload BLOB NOT NULL,revision TEXT NOT NULL,root_version INTEGER NOT NULL CHECK(root_version>0),updated_at REAL NOT NULL);CREATE TABLE IF NOT EXISTS pending_file_cleanup(object_id TEXT PRIMARY KEY,path TEXT NOT NULL,created_at REAL NOT NULL);PRAGMA user_version=2");version=2};if version==2{try execute("ALTER TABLE pending_file_cleanup RENAME TO pending_file_cleanup_v2;CREATE TABLE pending_file_cleanup(marker_id TEXT PRIMARY KEY,object_id TEXT NOT NULL,revision TEXT NOT NULL,path_token TEXT NOT NULL,created_at REAL NOT NULL,UNIQUE(object_id,revision,path_token));INSERT INTO pending_file_cleanup(marker_id,object_id,revision,path_token,created_at) SELECT lower(hex(randomblob(16))),p.object_id,COALESCE(o.revision,''),'',p.created_at FROM pending_file_cleanup_v2 p LEFT JOIN objects o ON o.id=p.object_id;DROP TABLE pending_file_cleanup_v2;PRAGMA user_version=3");version=3};guard version==3 else{throw VaultStorageError.sqlite("unsupported schema \(version)")};try execute("COMMIT")}catch{try?execute("ROLLBACK");throw error}}
    private func objectLocked(_ id:VaultObjectID)throws->VaultObjectRecord?{var result:VaultObjectRecord?;try query("SELECT revision,logical_time,device_id,size,content_type,created_at,updated_at,accessed_at,tombstone FROM objects WHERE id=?",[.text(id.rawValue.uuidString)]){r in result=try decodeRecord(id,r)};return result}
    private func tombstoneLocked(_ id:VaultObjectID)throws->VaultTombstone?{var result:VaultTombstone?;try query("SELECT revision,logical_time,device_id,deleted_at FROM tombstones WHERE id=?",[.text(id.rawValue.uuidString)]){r in guard let rev=UUID(uuidString:r.text(0) ?? "")else{throw VaultStorageError.sqlite("tombstone")};result=VaultTombstone(id:id,revision:rev,logicalTime:r.int(1),deletedAt:Date(timeIntervalSinceReferenceDate:r.double(3)),deviceID:r.text(2) ?? "")};return result}
    private func decodeRecord(_ id:VaultObjectID,_ r:SQLiteRow,offset:Int=0)throws->VaultObjectRecord{guard let rev=UUID(uuidString:r.text(offset) ?? "")else{throw VaultStorageError.sqlite("revision")};return VaultObjectRecord(id:id,revision:rev,logicalTime:r.int(offset+1),size:r.int(offset+3),contentType:r.text(offset+4),createdAt:Date(timeIntervalSinceReferenceDate:r.double(offset+5)),updatedAt:Date(timeIntervalSinceReferenceDate:r.double(offset+6)),accessedAt:Date(timeIntervalSinceReferenceDate:r.double(offset+7)),isTombstone:r.int(offset+8) != 0,deviceID:r.text(offset+2) ?? "")}
    private func jobLocked(_ id:UUID)throws->VaultJob?{var result:VaultJob?;try query("SELECT kind,object_id,state,attempts,next_attempt,last_error,created_at,updated_at,idempotency_key,lease_owner,lease_expires FROM jobs WHERE id=?",[.text(id.uuidString)]){r in guard let kind=VaultJobKind(rawValue:r.text(0) ?? ""),let state=VaultJobState(rawValue:r.text(2) ?? "")else{throw VaultStorageError.sqlite("job")};result=VaultJob(id:id,kind:kind,objectID:r.text(1).flatMap{UUID(uuidString:$0)}.map{VaultObjectID(rawValue:$0)},state:state,attempts:Int(r.int(3)),nextAttemptAt:r.optionalDouble(4).map{Date(timeIntervalSinceReferenceDate:$0)},lastError:r.text(5),createdAt:Date(timeIntervalSinceReferenceDate:r.double(6)),updatedAt:Date(timeIntervalSinceReferenceDate:r.double(7)),idempotencyKey:r.text(8),leaseOwner:r.text(9),leaseExpiresAt:r.optionalDouble(10).map{Date(timeIntervalSinceReferenceDate:$0)})};return result}
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
                    if previousValid{try fileManager.moveItem(at:previous,to:final);try fileManager.moveItem(at:previousGeneration,to:generation)}
                    else{try fileManager.removeItem(at:previous);if fileManager.fileExists(atPath:previousGeneration.path){try fileManager.removeItem(at:previousGeneration)}}
                }
            }else if !finalValid{
                if fileManager.fileExists(atPath:final.path){try fileManager.removeItem(at:final)};if fileManager.fileExists(atPath:generation.path){try fileManager.removeItem(at:generation)}
            }
        }
    }
    private func installedGenerationIsValid(content:URL,generation:URL,expectedRevision:String?)throws->Bool{
        guard fileManager.fileExists(atPath:content.path),fileManager.fileExists(atPath:generation.path),try protectionApplier.hasRequiredProtection(at:content),try protectionApplier.hasRequiredProtection(at:generation),let marker=try?String(contentsOf:generation,encoding:.utf8),let separator=marker.firstIndex(of:":"),!marker[marker.index(after:separator)...].isEmpty else{return false}
        return expectedRevision.map{String(marker[..<separator])==$0} ?? true
    }
    private func protect(_ url:URL)throws{try protectionApplier.apply(to:url)}
    private func protectDatabaseFiles()throws{for suffix in ["","-wal","-shm"]{let u=URL(fileURLWithPath:databaseURL.path+suffix);if fileManager.fileExists(atPath:u.path){try protect(u)}}}
    private func sync<T>(_ body:()throws->T)throws->T{try queue.sync{let result=try body();try protectDatabaseFiles();return result}}
    private func transaction<T>(_ body:()throws->T)throws->T{try execute("BEGIN IMMEDIATE");do{let value=try body();try execute("COMMIT");return value}catch{try?execute("ROLLBACK");throw error}}
    private func retryingBusy<T>(attempts:Int=12,_ body:()throws->T)throws->T{var attempt=0;while true{do{return try body()}catch let error as VaultStorageError{if case.sqlite(let message)=error,(message.contains("locked")||message.contains("busy")),attempt<attempts{Thread.sleep(forTimeInterval:0.01*Double(attempt+1));attempt+=1;continue};throw error}}}
    private func execute(_ sql:String)throws{var message:UnsafeMutablePointer<CChar>?;let status=sqlite3_exec(db,sql,nil,nil,&message);guard status==SQLITE_OK else{let text=message.map{String(cString:$0)} ?? String(cString:sqlite3_errmsg(db));sqlite3_free(message);throw VaultStorageError.sqlite(text)};sqlite3_free(message)}
    private func scalar(_ sql:String,_ values:[SQLiteValue]=[])throws->Int64{var value:Int64?;try query(sql,values){r in if value==nil{value=r.int(0)}};guard let value else{throw VaultStorageError.sqlite("missing scalar")};return value}
    private func run(_ sql:String,_ values:[SQLiteValue]=[])throws{try statement(sql,values){stmt in let status=sqlite3_step(stmt);guard status==SQLITE_DONE else{throw VaultStorageError.sqlite(String(cString:sqlite3_errmsg(db)))}}}
    private func query(_ sql:String,_ values:[SQLiteValue]=[],body:(SQLiteRow)throws->Void)throws{try statement(sql,values){stmt in while true{let status=sqlite3_step(stmt);if status==SQLITE_DONE{return};guard status==SQLITE_ROW else{throw VaultStorageError.sqlite(String(cString:sqlite3_errmsg(db)))};try body(SQLiteRow(stmt))}}}
    private func statement<T>(_ sql:String,_ values:[SQLiteValue],body:(OpaquePointer)throws->T)throws->T{var stmt:OpaquePointer?;guard sqlite3_prepare_v2(db,sql,-1,&stmt,nil)==SQLITE_OK,let stmt else{throw VaultStorageError.sqlite(String(cString:sqlite3_errmsg(db)))};defer{sqlite3_finalize(stmt)};for(index,value)in values.enumerated(){try value.bind(stmt,Int32(index+1))};return try body(stmt)}
}

extension VaultRepository: VaultObjectStoring { public func data(for id:VaultObjectID)throws->Data?{try readContent(for:id)};public func setData(_ data:Data,for id:VaultObjectID)throws{_=try writeContent(data,for:id)};public func removeData(for id:VaultObjectID)throws{try removeContent(for:id)} }
private enum SQLiteValue{case null,text(String),int(Int64),double(Double),blob(Data);func bind(_ stmt:OpaquePointer,_ index:Int32)throws{let status:Int32;switch self{case.null:status=sqlite3_bind_null(stmt,index);case.text(let value):status=sqlite3_bind_text(stmt,index,value,-1,SQLITE_TRANSIENT);case.int(let value):status=sqlite3_bind_int64(stmt,index,value);case.double(let value):status=sqlite3_bind_double(stmt,index,value);case.blob(let value):status=value.withUnsafeBytes{sqlite3_bind_blob(stmt,index,$0.baseAddress,Int32(value.count),SQLITE_TRANSIENT)}};guard status==SQLITE_OK else{throw VaultStorageError.sqlite("bind")}}}
private struct SQLiteRow{let stmt:OpaquePointer;init(_ stmt:OpaquePointer){self.stmt=stmt};func text(_ i:Int)->String?{guard let p=sqlite3_column_text(stmt,Int32(i))else{return nil};return String(cString:p)};func int(_ i:Int)->Int64{sqlite3_column_int64(stmt,Int32(i))};func double(_ i:Int)->Double{sqlite3_column_double(stmt,Int32(i))};func optionalDouble(_ i:Int)->Double?{sqlite3_column_type(stmt,Int32(i))==SQLITE_NULL ? nil:double(i)};func blob(_ i:Int)->Data?{guard sqlite3_column_type(stmt,Int32(i)) != SQLITE_NULL,let p=sqlite3_column_blob(stmt,Int32(i))else{return nil};return Data(bytes:p,count:Int(sqlite3_column_bytes(stmt,Int32(i))))}}
private let SQLITE_TRANSIENT=unsafeBitCast(-1,to:sqlite3_destructor_type.self)
private extension FileHandle{func closeAfterSynchronize()throws{try synchronize();try close()}}
private extension UInt32{init(bigEndianBytes bytes:Data.SubSequence){self=bytes.reduce(UInt32(0)){($0<<8)|UInt32($1)}}}
