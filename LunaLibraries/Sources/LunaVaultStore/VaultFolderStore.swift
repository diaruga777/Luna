import Foundation
import LunaAppConfig
import LunaVaultBEP

/// The iPhone's mirror of the Mac's folder index plus every local state a
/// file has here: cache, dirty bit, thumbnail, pending local changes.
///
/// One SQLite file, `vault.sqlite`, under the App Group. Everything the
/// session layer learns from the Mac lands here first; the search index,
/// cache directory and thumbnail store are projections driven by the
/// `VaultIndexApplyResult` this store returns.
public final class VaultFolderStore: @unchecked Sendable {
    public static let schemaVersion: Int64 = 1

    public let rootURL: URL
    public let databaseURL: URL
    private let db: SQLiteDatabase

    /// Directories the store owns. Callers create files only inside these.
    public var cacheDirectory: URL { rootURL.appendingPathComponent("Cache", isDirectory: true) }
    public var scratchDirectory: URL { rootURL.appendingPathComponent("Scratch", isDirectory: true) }
    public var thumbnailDirectory: URL { rootURL.appendingPathComponent("Thumbnails", isDirectory: true) }
    public var identityDirectory: URL { rootURL.appendingPathComponent("Identity", isDirectory: true) }
    public var stagingDirectory: URL { rootURL.appendingPathComponent("Staging", isDirectory: true) }
    public var searchIndexURL: URL { rootURL.appendingPathComponent("vault-index.sqlite") }

    /// Opens the store under the App Group container.
    public static func production() throws -> VaultFolderStore {
        guard let container = AppConfig.sharedContainerURL() else { throw VaultStoreError.containerUnavailable }
        return try VaultFolderStore(rootURL: container.appendingPathComponent("Vault", isDirectory: true))
    }

    public init(rootURL: URL) throws {
        self.rootURL = rootURL
        databaseURL = rootURL.appendingPathComponent("vault.sqlite")
        for directory in [rootURL, rootURL.appendingPathComponent("Cache"), rootURL.appendingPathComponent("Scratch"),
                          rootURL.appendingPathComponent("Thumbnails"), rootURL.appendingPathComponent("Identity"),
                          rootURL.appendingPathComponent("Staging")] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            VaultFolderStore.protect(directory)
        }
        db = try SQLiteDatabase(url: databaseURL)
        try migrate()
    }

    static func protect(_ url: URL) {
        #if os(iOS)
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
        #endif
    }

    /// The on-disk location of a file's cached copy, by name.
    public func cacheFileURL(for name: String) -> URL {
        cacheDirectory.appendingPathComponent(SHA256Digest.hash(Data(name.utf8)).map { String(format: "%02x", $0) }.joined())
    }

    private func migrate() throws {
        try db.transaction {
            let version = try db.scalarUnlocked("PRAGMA user_version")
            if version >= VaultFolderStore.schemaVersion { return }
            try db.executeUnlocked("""
            CREATE TABLE IF NOT EXISTS peer (
                id INTEGER PRIMARY KEY, device_id TEXT NOT NULL, name TEXT NOT NULL, network_mode TEXT NOT NULL,
                manual_addresses TEXT NOT NULL, folder_id TEXT NOT NULL, folder_label TEXT NOT NULL,
                their_index_id INTEGER NOT NULL, their_max_sequence INTEGER NOT NULL, our_index_id INTEGER NOT NULL,
                index_generation INTEGER NOT NULL, paired_at REAL NOT NULL, last_connected_at REAL)
            """)
            try db.executeUnlocked("""
            CREATE TABLE IF NOT EXISTS files (
                name TEXT PRIMARY KEY, parent TEXT NOT NULL, type INTEGER NOT NULL, size INTEGER NOT NULL,
                modified_s INTEGER NOT NULL, modified_ns INTEGER NOT NULL, modified_by INTEGER NOT NULL,
                deleted INTEGER NOT NULL, invalid INTEGER NOT NULL, version BLOB NOT NULL, sequence INTEGER NOT NULL,
                block_size INTEGER NOT NULL, blocks_hash BLOB NOT NULL, block_hashes BLOB NOT NULL,
                origin INTEGER NOT NULL, generation INTEGER NOT NULL, change_seq INTEGER NOT NULL,
                first_seen REAL NOT NULL, needs_index INTEGER NOT NULL, indexed_blocks_hash BLOB NOT NULL,
                thumbnail_blocks_hash BLOB NOT NULL, cache_blocks_hash BLOB, cache_bytes INTEGER NOT NULL,
                cache_last_access REAL, cache_pinned INTEGER NOT NULL)
            """)
            try db.executeUnlocked("CREATE INDEX IF NOT EXISTS files_parent ON files(parent, deleted, type, name)")
            try db.executeUnlocked("CREATE INDEX IF NOT EXISTS files_needs_index ON files(needs_index, deleted, type)")
            try db.executeUnlocked("CREATE INDEX IF NOT EXISTS files_cache ON files(cache_last_access) WHERE cache_blocks_hash IS NOT NULL")
            try db.executeUnlocked("""
            CREATE TABLE IF NOT EXISTS local_changes (
                name TEXT PRIMARY KEY REFERENCES files(name) ON DELETE CASCADE, kind INTEGER NOT NULL,
                version BLOB NOT NULL, created_at REAL NOT NULL)
            """)
            try db.executeUnlocked("CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
            try db.executeUnlocked("CREATE TABLE IF NOT EXISTS counters (key TEXT PRIMARY KEY, value INTEGER NOT NULL)")
            try db.executeUnlocked("INSERT OR IGNORE INTO counters(key, value) VALUES ('change_seq', 0)")
            try db.executeUnlocked("PRAGMA user_version = \(VaultFolderStore.schemaVersion)")
        }
    }

    // MARK: - Peer

    public func peer() throws -> VaultPeerRecord? {
        try db.sync { try peerUnlocked() }
    }

    private func peerUnlocked() throws -> VaultPeerRecord? {
        var record: VaultPeerRecord?
        try db.queryUnlocked("""
        SELECT device_id, name, network_mode, manual_addresses, folder_id, folder_label, their_index_id,
               their_max_sequence, our_index_id, paired_at, last_connected_at FROM peer WHERE id = 1
        """) { row in
            let addresses = (try? JSONDecoder().decode([VaultPeerAddress].self, from: Data(row.text(3).utf8))) ?? []
            record = VaultPeerRecord(
                deviceID: try DeviceID(string: row.text(0)), name: row.text(1),
                networkMode: VaultNetworkMode(rawValue: row.text(2)) ?? .syncthingPublic,
                manualAddresses: addresses, folderID: row.text(4), folderLabel: row.text(5),
                theirIndexID: UInt64(bitPattern: row.int64(6)), theirMaxSequence: row.int64(7),
                ourIndexID: UInt64(bitPattern: row.int64(8)),
                pairedAt: Date(timeIntervalSinceReferenceDate: row.double(9)),
                lastConnectedAt: row.optionalDouble(10).map(Date.init(timeIntervalSinceReferenceDate:)))
        }
        return record
    }

    /// Creates or replaces the paired Mac. Replacing a different device
    /// wipes the mirrored index.
    public func savePeer(_ peer: VaultPeerRecord) throws {
        try db.transaction {
            let existing = try peerUnlocked()
            if let existing, existing.deviceID != peer.deviceID {
                try wipeFilesUnlocked()
            }
            var saved = peer
            if saved.ourIndexID == 0 {
                saved.ourIndexID = existing?.ourIndexID ?? VaultFolderStore.randomIndexID()
            }
            let addresses = String(data: try JSONEncoder().encode(saved.manualAddresses), encoding: .utf8) ?? "[]"
            try db.executeUnlocked("""
            INSERT INTO peer(id, device_id, name, network_mode, manual_addresses, folder_id, folder_label, their_index_id,
                             their_max_sequence, our_index_id, index_generation, paired_at, last_connected_at)
            VALUES (1, ?, ?, ?, ?, ?, ?, ?, ?, ?, COALESCE((SELECT index_generation FROM peer WHERE id = 1), 0), ?, ?)
            ON CONFLICT(id) DO UPDATE SET device_id = excluded.device_id, name = excluded.name,
                network_mode = excluded.network_mode, manual_addresses = excluded.manual_addresses,
                folder_id = excluded.folder_id, folder_label = excluded.folder_label,
                their_index_id = excluded.their_index_id, their_max_sequence = excluded.their_max_sequence,
                our_index_id = excluded.our_index_id, paired_at = excluded.paired_at,
                last_connected_at = excluded.last_connected_at
            """, [.text(saved.deviceID.description), .text(saved.name), .text(saved.networkMode.rawValue), .text(addresses),
                  .text(saved.folderID), .text(saved.folderLabel), .integer(Int64(bitPattern: saved.theirIndexID)),
                  .integer(saved.theirMaxSequence), .integer(Int64(bitPattern: saved.ourIndexID)),
                  .double(saved.pairedAt.timeIntervalSinceReferenceDate),
                  saved.lastConnectedAt.map { .double($0.timeIntervalSinceReferenceDate) } ?? .null])
        }
    }

    /// Forgets the Mac and every mirrored file.
    public func removePeer() throws {
        try db.transaction {
            try wipeFilesUnlocked()
            try db.executeUnlocked("DELETE FROM peer")
        }
    }

    public func recordConnected(at date: Date) throws {
        try db.execute("UPDATE peer SET last_connected_at = ? WHERE id = 1", [.double(date.timeIntervalSinceReferenceDate)])
    }

    /// Stores the peer's index id and the highest sequence applied so far.
    public func updateTheirIndexState(indexID: UInt64, maxSequence: Int64) throws {
        try db.execute("UPDATE peer SET their_index_id = ?, their_max_sequence = MAX(their_max_sequence, ?) WHERE id = 1",
                       [.integer(Int64(bitPattern: indexID)), .integer(maxSequence)])
    }

    /// Resets the delta state so the next session asks for a full Index.
    public func forgetTheirIndex() throws {
        try db.execute("UPDATE peer SET their_index_id = 0, their_max_sequence = 0 WHERE id = 1")
    }

    private func wipeFilesUnlocked() throws {
        try db.executeUnlocked("DELETE FROM local_changes")
        try db.executeUnlocked("DELETE FROM files")
        try db.executeUnlocked("UPDATE peer SET their_index_id = 0, their_max_sequence = 0, index_generation = 0")
    }

    static func randomIndexID() -> UInt64 {
        var value: UInt64 = 0
        repeat { value = UInt64.random(in: 1...UInt64.max) } while value == 0
        return value
    }

    // MARK: - Applying the peer's index

    /// Applies one `Index` or `IndexUpdate` batch. A full `Index` starts a
    /// new generation; rows the peer no longer lists are purged by
    /// `purgeStaleGenerations()` at the start of the next session.
    public func applyIndex(_ index: BEPIndex, ourShortID: UInt64, now: Date = Date()) throws -> VaultIndexApplyResult {
        try db.transaction {
            var result = VaultIndexApplyResult()
            var generation = try db.scalarUnlocked("SELECT index_generation FROM peer WHERE id = 1")
            if !index.isUpdate {
                generation += 1
                try db.executeUnlocked("UPDATE peer SET index_generation = ? WHERE id = 1", [.integer(generation)])
            }
            var maxSequence: Int64 = 0
            for file in index.files {
                maxSequence = max(maxSequence, file.sequence)
                guard (try? BEPFileInfo.validateName(file.name)) != nil else { continue }
                try applyOne(file, generation: generation, ourShortID: ourShortID, now: now, into: &result)
            }
            if maxSequence > 0 {
                try db.executeUnlocked("UPDATE peer SET their_max_sequence = MAX(their_max_sequence, ?) WHERE id = 1", [.integer(maxSequence)])
            }
            return result
        }
    }

    private func applyOne(_ file: BEPFileInfo, generation: Int64, ourShortID: UInt64, now: Date,
                          into result: inout VaultIndexApplyResult) throws {
        let existing = try fileUnlocked(named: file.name)
        let incomingLive = !file.deleted && !file.invalid && file.type == .file
        guard let existing else {
            try insertPeerRow(file, generation: generation, now: now)
            if incomingLive { result.changed.append(file.name); result.contentChanged.append(file.name) }
            else if file.type == .directory && !file.deleted { result.changed.append(file.name) }
            return
        }
        let ordering = file.version.compare(existing.version)
        switch existing.origin {
        case .localPending:
            switch ordering {
            case .equal, .greater, .concurrentGreater:
                result.confirmed.append(file.name)
                try db.executeUnlocked("DELETE FROM local_changes WHERE name = ?", [.text(file.name)])
            case .lesser, .concurrentLesser:
                return
            }
        case .peer:
            switch ordering {
            case .greater, .concurrentGreater: break
            case .equal:
                try db.executeUnlocked("UPDATE files SET generation = ?, sequence = ? WHERE name = ?",
                                       [.integer(generation), .integer(file.sequence), .text(file.name)])
                return
            case .lesser, .concurrentLesser:
                return
            }
        }
        let contentChanged = file.blocksHash != existing.blocksHash || file.type != existing.type
            || file.deleted != existing.deleted || file.invalid != existing.invalid || file.size != existing.size
        let cacheStillValid = incomingLive && existing.cache?.blocksHash == file.blocksHash && !file.blocksHash.isEmpty
        if existing.cache != nil && !cacheStillValid { result.cacheInvalidated.append(file.name) }
        let needsIndex = incomingLive && (contentChanged || existing.needsIndex)
        try db.executeUnlocked("""
        UPDATE files SET type = ?, size = ?, modified_s = ?, modified_ns = ?, modified_by = ?, deleted = ?, invalid = ?,
            version = ?, sequence = ?, block_size = ?, blocks_hash = ?, block_hashes = ?, origin = 0, generation = ?,
            change_seq = ?, needs_index = ?,
            indexed_blocks_hash = CASE WHEN ? THEN indexed_blocks_hash ELSE X'' END,
            thumbnail_blocks_hash = CASE WHEN ? THEN thumbnail_blocks_hash ELSE X'' END,
            cache_blocks_hash = CASE WHEN ? THEN cache_blocks_hash ELSE NULL END,
            cache_bytes = CASE WHEN ? THEN cache_bytes ELSE 0 END,
            cache_last_access = CASE WHEN ? THEN cache_last_access ELSE NULL END,
            cache_pinned = CASE WHEN ? THEN cache_pinned ELSE 0 END
        WHERE name = ?
        """, [.integer(Int64(file.type.rawValue)), .integer(file.size), .integer(file.modifiedS), .integer(Int64(file.modifiedNs)),
              .integer(Int64(bitPattern: file.modifiedBy)), .integer(file.deleted ? 1 : 0), .integer(file.invalid ? 1 : 0),
              .blob(file.version.storageBytes), .integer(file.sequence), .integer(Int64(file.effectiveBlockSize)),
              .blob(file.blocksHash), .blob(BlockLayout.concatenatedHashes(file.blocks)), .integer(generation),
              .integer(try nextChangeSequenceUnlocked()), .integer(needsIndex ? 1 : 0),
              .integer(contentChanged ? 0 : 1), .integer(contentChanged ? 0 : 1),
              .integer(cacheStillValid ? 1 : 0), .integer(cacheStillValid ? 1 : 0), .integer(cacheStillValid ? 1 : 0),
              .integer(cacheStillValid ? 1 : 0), .text(file.name)])
        if incomingLive || (file.type == .directory && !file.deleted) {
            result.changed.append(file.name)
            if contentChanged && incomingLive { result.contentChanged.append(file.name) }
        } else {
            result.removed.append(file.name)
        }
    }

    private func insertPeerRow(_ file: BEPFileInfo, generation: Int64, now: Date) throws {
        let live = !file.deleted && !file.invalid && file.type == .file
        try db.executeUnlocked("""
        INSERT INTO files(name, parent, type, size, modified_s, modified_ns, modified_by, deleted, invalid, version, sequence,
            block_size, blocks_hash, block_hashes, origin, generation, change_seq, first_seen, needs_index,
            indexed_blocks_hash, thumbnail_blocks_hash, cache_blocks_hash, cache_bytes, cache_last_access, cache_pinned)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?, ?, ?, ?, X'', X'', NULL, 0, NULL, 0)
        """, [.text(file.name), .text(VaultFolderStore.parent(of: file.name)), .integer(Int64(file.type.rawValue)),
              .integer(file.size), .integer(file.modifiedS), .integer(Int64(file.modifiedNs)),
              .integer(Int64(bitPattern: file.modifiedBy)), .integer(file.deleted ? 1 : 0), .integer(file.invalid ? 1 : 0),
              .blob(file.version.storageBytes), .integer(file.sequence), .integer(Int64(file.effectiveBlockSize)),
              .blob(file.blocksHash), .blob(BlockLayout.concatenatedHashes(file.blocks)), .integer(generation),
              .integer(try nextChangeSequenceUnlocked()), .double(now.timeIntervalSinceReferenceDate),
              .integer(live ? 1 : 0)])
    }

    /// Drops peer rows a full `Index` did not repeat. Call at session start,
    /// when the previous full transfer has certainly finished.
    public func purgeStaleGenerations() throws -> [String] {
        try db.transaction {
            let generation = try db.scalarUnlocked("SELECT index_generation FROM peer WHERE id = 1")
            var names: [String] = []
            try db.queryUnlocked("SELECT name FROM files WHERE origin = 0 AND generation < ? AND deleted = 0", [.integer(generation)]) {
                names.append($0.text(0))
            }
            try db.executeUnlocked("DELETE FROM files WHERE origin = 0 AND generation < ?", [.integer(generation)])
            return names
        }
    }

    static func parent(of name: String) -> String {
        guard let slash = name.lastIndex(of: "/") else { return "" }
        return String(name[name.startIndex..<slash])
    }

    // MARK: - Local changes

    /// Records an import: the file row with our version, a pinned cache
    /// entry, and a pending change to announce.
    @discardableResult
    public func stageImport(name: String, size: Int64, blockSize: Int, blocks: [BlockInfo], modified: Date,
                            ourShortID: UInt64, now: Date = Date()) throws -> VaultFileRecord {
        try BEPFileInfo.validateName(name)
        return try db.transaction {
            let existing = try fileUnlocked(named: name)
            let version = (existing?.version ?? .empty).updated(by: ourShortID, now: now)
            let blocksHash = BlockLayout.blocksHash(blocks)
            let modifiedS = Int64(modified.timeIntervalSince1970.rounded(.down))
            let modifiedNs = Int32((modified.timeIntervalSince1970 - TimeInterval(modifiedS)) * 1_000_000_000)
            let generation = try db.scalarUnlocked("SELECT COALESCE((SELECT index_generation FROM peer WHERE id = 1), 0)")
            try db.executeUnlocked("""
            INSERT INTO files(name, parent, type, size, modified_s, modified_ns, modified_by, deleted, invalid, version, sequence,
                block_size, blocks_hash, block_hashes, origin, generation, change_seq, first_seen, needs_index,
                indexed_blocks_hash, thumbnail_blocks_hash, cache_blocks_hash, cache_bytes, cache_last_access, cache_pinned)
            VALUES (?, ?, 0, ?, ?, ?, ?, 0, 0, ?, 0, ?, ?, ?, 1, ?, ?, ?, 1, X'', X'', ?, ?, ?, 1)
            ON CONFLICT(name) DO UPDATE SET type = 0, size = excluded.size, modified_s = excluded.modified_s,
                modified_ns = excluded.modified_ns, modified_by = excluded.modified_by, deleted = 0, invalid = 0,
                version = excluded.version, block_size = excluded.block_size, blocks_hash = excluded.blocks_hash,
                block_hashes = excluded.block_hashes, origin = 1, change_seq = excluded.change_seq, needs_index = 1,
                indexed_blocks_hash = X'', thumbnail_blocks_hash = X'', cache_blocks_hash = excluded.cache_blocks_hash,
                cache_bytes = excluded.cache_bytes, cache_last_access = excluded.cache_last_access, cache_pinned = 1
            """, [.text(name), .text(VaultFolderStore.parent(of: name)), .integer(size), .integer(modifiedS),
                  .integer(Int64(modifiedNs)), .integer(Int64(bitPattern: ourShortID)), .blob(version.storageBytes),
                  .integer(Int64(blockSize)), .blob(blocksHash), .blob(BlockLayout.concatenatedHashes(blocks)),
                  .integer(generation), .integer(try nextChangeSequenceUnlocked()),
                  .double(now.timeIntervalSinceReferenceDate), .blob(blocksHash), .integer(size),
                  .double(now.timeIntervalSinceReferenceDate)])
            try db.executeUnlocked("""
            INSERT INTO local_changes(name, kind, version, created_at) VALUES (?, 0, ?, ?)
            ON CONFLICT(name) DO UPDATE SET kind = 0, version = excluded.version, created_at = excluded.created_at
            """, [.text(name), .blob(version.storageBytes), .double(now.timeIntervalSinceReferenceDate)])
            guard let record = try fileUnlocked(named: name) else { throw VaultStoreError.invalidRecord(name) }
            return record
        }
    }

    /// Records a delete: a tombstone with our version and a pending change.
    /// Returns nil when the file is unknown or already deleted.
    @discardableResult
    public func stageDelete(name: String, ourShortID: UInt64, now: Date = Date()) throws -> VaultFileRecord? {
        try db.transaction {
            guard let existing = try fileUnlocked(named: name), !existing.deleted else { return nil }
            let version = existing.version.updated(by: ourShortID, now: now)
            let modifiedS = Int64(now.timeIntervalSince1970.rounded(.down))
            try db.executeUnlocked("""
            UPDATE files SET deleted = 1, size = 0, blocks_hash = X'', block_hashes = X'', version = ?, modified_s = ?,
                modified_ns = 0, modified_by = ?, origin = 1, change_seq = ?, needs_index = 0, indexed_blocks_hash = X'',
                thumbnail_blocks_hash = X'', cache_blocks_hash = NULL, cache_bytes = 0, cache_last_access = NULL, cache_pinned = 0
            WHERE name = ?
            """, [.blob(version.storageBytes), .integer(modifiedS), .integer(Int64(bitPattern: ourShortID)),
                  .integer(try nextChangeSequenceUnlocked()), .text(name)])
            try db.executeUnlocked("""
            INSERT INTO local_changes(name, kind, version, created_at) VALUES (?, 1, ?, ?)
            ON CONFLICT(name) DO UPDATE SET kind = 1, version = excluded.version, created_at = excluded.created_at
            """, [.text(name), .blob(version.storageBytes), .double(now.timeIntervalSinceReferenceDate)])
            return try fileUnlocked(named: name)
        }
    }

    public func pendingLocalChanges() throws -> [VaultLocalChange] {
        try db.sync {
            var changes: [VaultLocalChange] = []
            try db.queryUnlocked("SELECT name, kind, version, created_at FROM local_changes ORDER BY created_at, name") { row in
                changes.append(VaultLocalChange(
                    name: row.text(0), kind: VaultLocalChangeKind(rawValue: row.int(1)) ?? .add,
                    version: try VersionVector(storageBytes: row.blob(2)),
                    createdAt: Date(timeIntervalSinceReferenceDate: row.double(3))))
            }
            return changes
        }
    }

    /// The honest index: pending local changes plus files whose cached copy
    /// is current. Sequences are assigned in message order.
    public func announcedIndexEntries() throws -> [BEPFileInfo] {
        try db.sync {
            var entries: [BEPFileInfo] = []
            try db.queryUnlocked("""
            SELECT \(VaultFolderStore.fileColumns) FROM files
            WHERE origin = 1 OR (deleted = 0 AND invalid = 0 AND type = 0 AND cache_blocks_hash IS NOT NULL AND cache_blocks_hash = blocks_hash)
            ORDER BY change_seq
            """) { row in
                entries.append(try VaultFolderStore.record(from: row).fileInfo())
            }
            for index in entries.indices { entries[index].sequence = Int64(index + 1) }
            return entries
        }
    }

    // MARK: - Files

    static let fileColumns = """
    name, type, size, modified_s, modified_ns, modified_by, deleted, invalid, version, sequence, block_size, blocks_hash,
    block_hashes, origin, first_seen, needs_index, indexed_blocks_hash, thumbnail_blocks_hash, cache_blocks_hash,
    cache_bytes, cache_last_access, cache_pinned
    """

    static func record(from row: SQLiteDatabase.Row) throws -> VaultFileRecord {
        var cache: VaultCacheState?
        if !row.isNull(18) {
            cache = VaultCacheState(blocksHash: row.blob(18), bytes: row.int64(19),
                                    lastAccess: Date(timeIntervalSinceReferenceDate: row.optionalDouble(20) ?? 0),
                                    pinned: row.bool(21))
        }
        return VaultFileRecord(
            name: row.text(0), type: BEPFileType(rawValue: row.int(1)) ?? .file, size: row.int64(2),
            modifiedS: row.int64(3), modifiedNs: Int32(truncatingIfNeeded: row.int64(4)),
            modifiedBy: UInt64(bitPattern: row.int64(5)), deleted: row.bool(6), invalid: row.bool(7),
            version: try VersionVector(storageBytes: row.blob(8)), sequence: row.int64(9), blockSize: row.int(10),
            blocksHash: row.blob(11), blockHashes: row.blob(12), origin: VaultFileOrigin(rawValue: row.int(13)) ?? .peer,
            firstSeen: Date(timeIntervalSinceReferenceDate: row.double(14)), needsIndex: row.bool(15),
            indexedBlocksHash: row.blob(16), thumbnailBlocksHash: row.blob(17), cache: cache)
    }

    private func fileUnlocked(named name: String) throws -> VaultFileRecord? {
        var record: VaultFileRecord?
        try db.queryUnlocked("SELECT \(VaultFolderStore.fileColumns) FROM files WHERE name = ?", [.text(name)]) {
            record = try VaultFolderStore.record(from: $0)
        }
        return record
    }

    public func file(named name: String) throws -> VaultFileRecord? {
        try db.sync { try fileUnlocked(named: name) }
    }

    /// Live entries directly under `parent` ("" for the root): directories
    /// first, then files, both by name.
    public func children(of parent: String) throws -> [VaultFileRecord] {
        try db.sync {
            var records: [VaultFileRecord] = []
            try db.queryUnlocked("""
            SELECT \(VaultFolderStore.fileColumns) FROM files WHERE parent = ? AND deleted = 0 AND invalid = 0
            ORDER BY CASE type WHEN 1 THEN 0 ELSE 1 END, name COLLATE NOCASE
            """, [.text(parent)]) { records.append(try VaultFolderStore.record(from: $0)) }
            return records
        }
    }

    public func liveFiles(limit: Int = Int.max, offset: Int = 0) throws -> [VaultFileRecord] {
        try db.sync {
            var records: [VaultFileRecord] = []
            try db.queryUnlocked("""
            SELECT \(VaultFolderStore.fileColumns) FROM files WHERE deleted = 0 AND invalid = 0 AND type = 0
            ORDER BY modified_s DESC, name LIMIT ? OFFSET ?
            """, [.integer(Int64(limit)), .integer(Int64(offset))]) { records.append(try VaultFolderStore.record(from: $0)) }
            return records
        }
    }

    public func liveFileCount() throws -> Int {
        try db.sync { Int(try db.scalarUnlocked("SELECT COUNT(*) FROM files WHERE deleted = 0 AND invalid = 0 AND type = 0")) }
    }

    /// The monotonic stamp the search index uses as logical time.
    public func changeSequence(for name: String) throws -> Int64 {
        try db.sync { try db.scalarUnlocked("SELECT change_seq FROM files WHERE name = ?", [.text(name)]) }
    }

    private func nextChangeSequenceUnlocked() throws -> Int64 {
        try db.executeUnlocked("UPDATE counters SET value = value + 1 WHERE key = 'change_seq'")
        return try db.scalarUnlocked("SELECT value FROM counters WHERE key = 'change_seq'")
    }

    // MARK: - Cache

    public func recordCacheInstall(name: String, blocksHash: Data, bytes: Int64, pinned: Bool = false, now: Date = Date()) throws {
        try db.execute("""
        UPDATE files SET cache_blocks_hash = ?, cache_bytes = ?, cache_last_access = ?, cache_pinned = MAX(cache_pinned, ?) WHERE name = ?
        """, [.blob(blocksHash), .integer(bytes), .double(now.timeIntervalSinceReferenceDate), .integer(pinned ? 1 : 0), .text(name)])
    }

    public func markCacheAccess(name: String, now: Date = Date()) throws {
        try db.execute("UPDATE files SET cache_last_access = ? WHERE name = ? AND cache_blocks_hash IS NOT NULL",
                       [.double(now.timeIntervalSinceReferenceDate), .text(name)])
    }

    public func setCachePinned(name: String, pinned: Bool) throws {
        try db.execute("UPDATE files SET cache_pinned = ? WHERE name = ?", [.integer(pinned ? 1 : 0), .text(name)])
    }

    public func clearCache(name: String) throws {
        try db.execute("UPDATE files SET cache_blocks_hash = NULL, cache_bytes = 0, cache_last_access = NULL, cache_pinned = 0 WHERE name = ?",
                       [.text(name)])
    }

    public struct CacheTotals: Equatable, Sendable {
        public var bytes: Int64
        public var count: Int
        public var pinnedBytes: Int64

        public init(bytes: Int64, count: Int, pinnedBytes: Int64) {
            self.bytes = bytes
            self.count = count
            self.pinnedBytes = pinnedBytes
        }
    }

    public func cacheTotals() throws -> CacheTotals {
        try db.sync {
            var totals = CacheTotals(bytes: 0, count: 0, pinnedBytes: 0)
            try db.queryUnlocked("""
            SELECT COALESCE(SUM(cache_bytes), 0), COUNT(*), COALESCE(SUM(CASE WHEN cache_pinned = 1 OR origin = 1 THEN cache_bytes ELSE 0 END), 0)
            FROM files WHERE cache_blocks_hash IS NOT NULL
            """) { totals = CacheTotals(bytes: $0.int64(0), count: $0.int(1), pinnedBytes: $0.int64(2)) }
            return totals
        }
    }

    /// Unpinned cached files, least recently used first. Pending local
    /// changes never appear: the Mac still has to pull them.
    public func cacheEvictionCandidates() throws -> [VaultFileRecord] {
        try db.sync {
            var records: [VaultFileRecord] = []
            try db.queryUnlocked("""
            SELECT \(VaultFolderStore.fileColumns) FROM files
            WHERE cache_blocks_hash IS NOT NULL AND cache_pinned = 0 AND origin = 0 ORDER BY cache_last_access ASC
            """) { records.append(try VaultFolderStore.record(from: $0)) }
            return records
        }
    }

    public func cachedFiles() throws -> [VaultFileRecord] {
        try db.sync {
            var records: [VaultFileRecord] = []
            try db.queryUnlocked("SELECT \(VaultFolderStore.fileColumns) FROM files WHERE cache_blocks_hash IS NOT NULL ORDER BY name") {
                records.append(try VaultFolderStore.record(from: $0))
            }
            return records
        }
    }

    // MARK: - Indexing

    public func filesNeedingIndex(limit: Int) throws -> [VaultFileRecord] {
        try db.sync {
            var records: [VaultFileRecord] = []
            try db.queryUnlocked("""
            SELECT \(VaultFolderStore.fileColumns) FROM files
            WHERE needs_index = 1 AND deleted = 0 AND invalid = 0 AND type = 0
            ORDER BY CASE WHEN cache_blocks_hash = blocks_hash THEN 0 ELSE 1 END, modified_s DESC, name LIMIT ?
            """, [.integer(Int64(limit))]) { records.append(try VaultFolderStore.record(from: $0)) }
            return records
        }
    }

    public func indexBacklogCount() throws -> Int {
        try db.sync { Int(try db.scalarUnlocked("SELECT COUNT(*) FROM files WHERE needs_index = 1 AND deleted = 0 AND invalid = 0 AND type = 0")) }
    }

    /// Clears the dirty bit only if the content indexed is still current.
    public func markIndexed(name: String, blocksHash: Data) throws {
        try db.execute("""
        UPDATE files SET indexed_blocks_hash = ?, needs_index = CASE WHEN blocks_hash = ? THEN 0 ELSE needs_index END WHERE name = ?
        """, [.blob(blocksHash), .blob(blocksHash), .text(name)])
    }

    public func markThumbnail(name: String, blocksHash: Data) throws {
        try db.execute("UPDATE files SET thumbnail_blocks_hash = ? WHERE name = ?", [.blob(blocksHash), .text(name)])
    }

    /// Marks every live file dirty, for a full rebuild.
    public func markAllNeedingIndex() throws {
        try db.execute("UPDATE files SET needs_index = 1, indexed_blocks_hash = X'' WHERE deleted = 0 AND invalid = 0 AND type = 0")
    }

    // MARK: - Settings

    public func settings() throws -> VaultStoreSettings {
        try db.sync {
            var settings = VaultStoreSettings()
            try db.queryUnlocked("SELECT key, value FROM settings") { row in
                switch row.text(0) {
                case "cache_quota": settings.cacheQuotaBytes = Int64(row.text(1)) ?? settings.cacheQuotaBytes
                case "scratch_quota": settings.scratchQuotaBytes = Int64(row.text(1)) ?? settings.scratchQuotaBytes
                default: break
                }
            }
            return settings
        }
    }

    public func saveSettings(_ settings: VaultStoreSettings) throws {
        try db.transaction {
            for (key, value) in [("cache_quota", settings.cacheQuotaBytes), ("scratch_quota", settings.scratchQuotaBytes)] {
                try db.executeUnlocked("INSERT INTO settings(key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                                       [.text(key), .text(String(value))])
            }
        }
    }

    /// Arbitrary small values other layers persist (last nightly run, …).
    public func value(forKey key: String) throws -> String? {
        try db.sync {
            var value: String?
            try db.queryUnlocked("SELECT value FROM settings WHERE key = ?", [.text(key)]) { value = $0.text(0) }
            return value
        }
    }

    public func setValue(_ value: String?, forKey key: String) throws {
        if let value {
            try db.execute("INSERT INTO settings(key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                           [.text(key), .text(value)])
        } else {
            try db.execute("DELETE FROM settings WHERE key = ?", [.text(key)])
        }
    }
}
