import Foundation
import LunaVaultBEP

public struct CompanionFileRecord: Equatable, Sendable {
    public var info: BEPFileInfo
    public var absoluteURL: URL?

    public init(info: BEPFileInfo, absoluteURL: URL? = nil) {
        self.info = info
        self.absoluteURL = absoluteURL
    }
}

/// The companion's authoritative folder index. It intentionally has no
/// dependency on the iPhone store: the Mac can scan and serve the folder while
/// the phone is offline.
public final class CompanionIndex: @unchecked Sendable {
    private let db: CompanionSQLite
    private let lock = NSLock()

    public init(databaseURL: URL) throws {
        db = try CompanionSQLite(path: databaseURL.path)
        try db.execute("""
        CREATE TABLE IF NOT EXISTS files (
            name TEXT PRIMARY KEY, type INTEGER NOT NULL, size INTEGER NOT NULL,
            modified_s INTEGER NOT NULL, modified_ns INTEGER NOT NULL,
            blocks_hash BLOB NOT NULL, block_hashes BLOB NOT NULL,
            block_size INTEGER NOT NULL, version BLOB NOT NULL,
            sequence INTEGER NOT NULL)
        """)
    }

    public func replace(with records: [CompanionFileRecord]) throws {
        lock.lock(); defer { lock.unlock() }
        try db.transaction {
            try db.execute("DELETE FROM files")
            for (offset, record) in records.enumerated() {
                try insert(record.info, sequence: Int64(offset + 1))
            }
        }
    }

    public func upsert(_ record: CompanionFileRecord) throws {
        lock.lock(); defer { lock.unlock() }
        try insert(record.info, sequence: record.info.sequence)
    }

    public func all() throws -> [BEPFileInfo] {
        lock.lock(); defer { lock.unlock() }
        var result: [BEPFileInfo] = []
        try db.query("SELECT name,type,size,modified_s,modified_ns,blocks_hash,block_hashes,block_size,version,sequence FROM files ORDER BY name") {
            result.append(try Self.info(from: $0))
        }
        return result
    }

    public func file(named name: String) throws -> BEPFileInfo? {
        lock.lock(); defer { lock.unlock() }
        var result: BEPFileInfo?
        try db.query("SELECT name,type,size,modified_s,modified_ns,blocks_hash,block_hashes,block_size,version,sequence FROM files WHERE name = ?", [.text(name)]) {
            result = try Self.info(from: $0)
        }
        return result
    }

    public func maxSequence() throws -> Int64 {
        lock.lock(); defer { lock.unlock() }
        var result: Int64 = 0
        try db.query("SELECT COALESCE(MAX(sequence), 0) FROM files") { result = $0.int(0) }
        return result
    }

    private func insert(_ info: BEPFileInfo, sequence: Int64) throws {
        try db.run("""
        INSERT INTO files(name,type,size,modified_s,modified_ns,blocks_hash,block_hashes,block_size,version,sequence)
        VALUES(?,?,?,?,?,?,?,?,?,?)
        ON CONFLICT(name) DO UPDATE SET type=excluded.type,size=excluded.size,modified_s=excluded.modified_s,
          modified_ns=excluded.modified_ns,blocks_hash=excluded.blocks_hash,block_hashes=excluded.block_hashes,
          block_size=excluded.block_size,version=excluded.version,sequence=excluded.sequence
        """, [.text(info.name), .int(Int64(info.type.rawValue)), .int(info.size), .int(info.modifiedS),
               .int(Int64(info.modifiedNs)), .blob(info.blocksHash), .blob(BlockLayout.concatenatedHashes(info.blocks)),
               .int(Int64(info.blockSize)), .blob(info.version.storageBytes), .int(sequence)])
    }

    private static func info(from row: CompanionSQLite.Row) throws -> BEPFileInfo {
        let size = row.int(2)
        let blockSize = Int32(truncatingIfNeeded: row.int(7))
        return BEPFileInfo(name: row.text(0), type: BEPFileType(rawValue: Int(row.int(1))) ?? .file,
                           size: size, modifiedS: row.int(3), modifiedNs: Int32(truncatingIfNeeded: row.int(4)),
                           modifiedBy: 0, deleted: false, invalid: false, noPermissions: true,
                           version: try VersionVector(storageBytes: row.blob(8)), sequence: row.int(9),
                           blockSize: blockSize,
                           blocks: BlockLayout.blocks(fromConcatenatedHashes: row.blob(6), fileSize: size, blockSize: Int(blockSize)),
                           blocksHash: row.blob(5))
    }
}

/// Scans the selected folder and computes Syncthing-compatible blocks. The
/// scanner follows regular files and directories and ignores Syncthing's own
/// marker/temporary directories.
public struct CompanionFolderScanner: Sendable {
    public let rootURL: URL
    public let deviceShortID: UInt64

    public init(rootURL: URL, deviceShortID: UInt64) {
        self.rootURL = rootURL.standardizedFileURL
        self.deviceShortID = deviceShortID
    }

    public func scan() throws -> [CompanionFileRecord] {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .contentModificationDateKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(at: rootURL, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]) else { return [] }
        var records: [CompanionFileRecord] = []
        for case let url as URL in enumerator {
            let relative = url.path.replacingOccurrences(of: rootURL.path + "/", with: "")
            if relative == ".stfolder" || relative.hasPrefix(".stfolder/") || relative.hasPrefix(".stversions/") { enumerator.skipDescendants(); continue }
            do { try BEPFileInfo.validateName(relative) } catch { continue }
            let values = try url.resourceValues(forKeys: keys)
            let modified = values.contentModificationDate ?? Date(timeIntervalSince1970: 0)
            let modifiedS = Int64(modified.timeIntervalSince1970.rounded(.down))
            let modifiedNs = Int32((modified.timeIntervalSince1970 - TimeInterval(modifiedS)) * 1_000_000_000)
            if values.isDirectory == true {
                records.append(CompanionFileRecord(info: BEPFileInfo(name: relative, type: .directory,
                    modifiedS: modifiedS, modifiedNs: modifiedNs, modifiedBy: deviceShortID,
                    noPermissions: true, version: VersionVector(counters: [VersionCounter(id: deviceShortID, value: UInt64(max(1, modifiedS)))]))))
            } else if values.isRegularFile == true {
                let (blockSize, blocks) = try BlockLayout.blocks(forFileAt: url)
                records.append(CompanionFileRecord(info: BEPFileInfo(name: relative, size: values.fileSize.map(Int64.init) ?? 0,
                    modifiedS: modifiedS, modifiedNs: modifiedNs, modifiedBy: deviceShortID, noPermissions: true,
                    version: VersionVector(counters: [VersionCounter(id: deviceShortID, value: UInt64(max(1, modifiedS)))]),
                    blockSize: Int32(blockSize), blocks: blocks, blocksHash: BlockLayout.blocksHash(blocks)), absoluteURL: url))
            }
        }
        return records.sorted { $0.info.name < $1.info.name }
    }
}

/// Handles one authenticated BEP connection for the companion.
public final class CompanionBEPDelegate: BEPConnectionDelegate, @unchecked Sendable {
    private let rootURL: URL
    private let index: CompanionIndex
    private let localDevice: DeviceID
    private let folderID: String

    public init(rootURL: URL, index: CompanionIndex, localDevice: DeviceID, folderID: String) {
        self.rootURL = rootURL.standardizedFileURL
        self.index = index
        self.localDevice = localDevice
        self.folderID = folderID
    }

    public func connection(_ connection: BEPConnection, didReceive clusterConfig: BEPClusterConfig) async {
        // The companion is single-folder in v1. The peer's config is still
        // accepted so the protocol state machine can advance normally.
    }

    public func connection(_ connection: BEPConnection, didReceive incoming: BEPIndex) async {
        guard incoming.folder == folderID else { return }
        for file in incoming.files where !file.deleted {
            try? self.index.upsert(CompanionFileRecord(info: file))
        }
    }

    public func connection(_ connection: BEPConnection, serve request: BEPRequest) async -> Result<Data, BEPErrorCode> {
        guard request.folder == folderID,
              let record = try? index.file(named: request.name),
              record.blocks.indices.contains(Int(request.blockNo)),
              record.blocks[Int(request.blockNo)].hash == request.hash else { return .failure(.noSuchFile) }
        let url = rootURL.appendingPathComponent(request.name)
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            try handle.seek(toOffset: UInt64(request.offset))
            let data = try handle.read(upToCount: Int(request.size)) ?? Data()
            guard SHA256Digest.hash(data) == request.hash else { return .failure(.generic) }
            return .success(data)
        } catch { return .failure(.noSuchFile) }
    }

    public func connection(_ connection: BEPConnection, didCloseWith error: Error?) async {}
}

/// A small pairing gate shared by the status-item UI and the listener.
public final class CompanionPairingController: @unchecked Sendable {
    public struct Request: Equatable, Sendable {
        public let device: DeviceID
        public let name: String
        public let createdAt: Date
        public init(device: DeviceID, name: String, createdAt: Date = Date()) {
            self.device = device; self.name = name; self.createdAt = createdAt
        }
    }

    private let lock = NSLock()
    private var pendingRequest: Request?

    public init() {}
    public var pending: Request? { lock.withLock { pendingRequest } }
    public func request(device: DeviceID, name: String) { lock.withLock { pendingRequest = Request(device: device, name: name) } }
    public func accept() -> Request? { lock.withLock { defer { pendingRequest = nil }; return pendingRequest } }
    public func reject() { lock.withLock { pendingRequest = nil } }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T { lock(); defer { unlock() }; return body() }
}
