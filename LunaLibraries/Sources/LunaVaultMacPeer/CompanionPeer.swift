import LunaMusicFiles
import Foundation
import LunaVaultBEP
import Darwin

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
            sequence INTEGER NOT NULL, deleted INTEGER NOT NULL DEFAULT 0)
        """)
        var hasDeleted = false
        try db.query("PRAGMA table_info(files)") { if $0.text(1) == "deleted" { hasDeleted = true } }
        if !hasDeleted { try db.execute("ALTER TABLE files ADD COLUMN deleted INTEGER NOT NULL DEFAULT 0") }
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

    /// Merge a disk scan with the protocol index. A scan must not replace the
    /// version received from the iPhone, or forget a deletion on reconnect.
    public func reconcileScan(_ records: [CompanionFileRecord], deviceShortID: UInt64,
                              now: Date = Date()) throws {
        lock.lock(); defer { lock.unlock() }
        var previous: [String: BEPFileInfo] = [:]
        try db.query("SELECT name,type,size,modified_s,modified_ns,blocks_hash,block_hashes,block_size,version,sequence,deleted FROM files") {
            let info = try Self.info(from: $0)
            previous[info.name] = info
        }
        var nextSequence = previous.values.map(\.sequence).max() ?? 0
        var updated: [BEPFileInfo] = []
        for record in records {
            var info = record.info
            if let old = previous.removeValue(forKey: info.name) {
                if !old.deleted && old.type == info.type && old.size == info.size &&
                    old.blocksHash == info.blocksHash {
                    info.version = old.version
                    info.sequence = old.sequence
                } else {
                    info.version = old.version.updated(by: deviceShortID, now: now)
                    nextSequence += 1
                    info.sequence = nextSequence
                }
            } else {
                nextSequence += 1
                info.sequence = nextSequence
            }
            updated.append(info)
        }
        for old in previous.values {
            if old.deleted { updated.append(old); continue }
            var tombstone = old
            tombstone.deleted = true
            tombstone.size = 0
            tombstone.blocks = []
            tombstone.blocksHash = Data()
            tombstone.version = old.version.updated(by: deviceShortID, now: now)
            nextSequence += 1
            tombstone.sequence = nextSequence
            updated.append(tombstone)
        }
        try db.transaction {
            try db.execute("DELETE FROM files")
            for info in updated { try insert(info, sequence: info.sequence) }
        }
    }

    public func upsert(_ record: CompanionFileRecord) throws {
        lock.lock(); defer { lock.unlock() }
        try insert(record.info, sequence: record.info.sequence)
    }

    public func all() throws -> [BEPFileInfo] {
        lock.lock(); defer { lock.unlock() }
        var result: [BEPFileInfo] = []
        try db.query("SELECT name,type,size,modified_s,modified_ns,blocks_hash,block_hashes,block_size,version,sequence,deleted FROM files ORDER BY name") {
            result.append(try Self.info(from: $0))
        }
        return result
    }

    public func file(named name: String) throws -> BEPFileInfo? {
        lock.lock(); defer { lock.unlock() }
        var result: BEPFileInfo?
        try db.query("SELECT name,type,size,modified_s,modified_ns,blocks_hash,block_hashes,block_size,version,sequence,deleted FROM files WHERE name = ?", [.text(name)]) {
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
        INSERT INTO files(name,type,size,modified_s,modified_ns,blocks_hash,block_hashes,block_size,version,sequence,deleted)
        VALUES(?,?,?,?,?,?,?,?,?,?,?)
        ON CONFLICT(name) DO UPDATE SET type=excluded.type,size=excluded.size,modified_s=excluded.modified_s,
          modified_ns=excluded.modified_ns,blocks_hash=excluded.blocks_hash,block_hashes=excluded.block_hashes,
          block_size=excluded.block_size,version=excluded.version,sequence=excluded.sequence,deleted=excluded.deleted
        """, [.text(info.name), .int(Int64(info.type.rawValue)), .int(info.size), .int(info.modifiedS),
               .int(Int64(info.modifiedNs)), .blob(info.blocksHash), .blob(BlockLayout.concatenatedHashes(info.blocks)),
               .int(Int64(info.blockSize)), .blob(info.version.storageBytes), .int(sequence), .int(info.deleted ? 1 : 0)])
    }

    private static func info(from row: CompanionSQLite.Row) throws -> BEPFileInfo {
        let size = row.int(2)
        let blockSize = Int32(truncatingIfNeeded: row.int(7))
        return BEPFileInfo(name: row.text(0), type: BEPFileType(rawValue: Int(row.int(1))) ?? .file,
                           size: size, modifiedS: row.int(3), modifiedNs: Int32(truncatingIfNeeded: row.int(4)),
                           modifiedBy: 0, deleted: row.int(10) != 0, invalid: false, noPermissions: true,
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

    public func scan(previous: [String: BEPFileInfo] = [:]) throws -> [CompanionFileRecord] {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(at: rootURL, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]) else { return [] }
        var records: [CompanionFileRecord] = []
        for case let url as URL in enumerator {
            let relative = url.path.replacingOccurrences(of: rootURL.path + "/", with: "")
            if relative == ".stfolder" || relative.hasPrefix(".stfolder/") || relative.hasPrefix(".stversions/") { enumerator.skipDescendants(); continue }
            do { try BEPFileInfo.validateName(relative) } catch { continue }
            let values = try url.resourceValues(forKeys: keys)
            if values.isSymbolicLink == true { enumerator.skipDescendants(); continue }
            let modified = values.contentModificationDate ?? Date(timeIntervalSince1970: 0)
            let modifiedS = Int64(modified.timeIntervalSince1970.rounded(.down))
            let modifiedNs = Int32((modified.timeIntervalSince1970 - TimeInterval(modifiedS)) * 1_000_000_000)
            if values.isDirectory == true {
                records.append(CompanionFileRecord(info: BEPFileInfo(name: relative, type: .directory,
                    modifiedS: modifiedS, modifiedNs: modifiedNs, modifiedBy: deviceShortID,
                    noPermissions: true, version: VersionVector(counters: [VersionCounter(id: deviceShortID, value: UInt64(max(1, modifiedS)))]))))
            } else if values.isRegularFile == true {
                let size = values.fileSize.map(Int64.init) ?? 0
                let cached = previous[relative]
                let blockSize: Int
                let blocks: [BlockInfo]
                if let cached, !cached.deleted, cached.type == .file, cached.size == size,
                   cached.modifiedS == modifiedS, cached.modifiedNs == modifiedNs,
                   !cached.blocks.isEmpty {
                    blockSize = cached.effectiveBlockSize
                    blocks = cached.blocks
                } else {
                    (blockSize, blocks) = try BlockLayout.blocks(forFileAt: url)
                }
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
    private let transferLock = NSLock()
    private var authorized = false
    private let music: CompanionMusicLibrary
    private let codeHandler: (@Sendable (Data) async -> Data)?
    private var pending: [BEPIndex] = []
    private var transferTask: Task<Void, Never>?

    public init(rootURL: URL, index: CompanionIndex, localDevice: DeviceID, folderID: String,
                codeHandler: (@Sendable (Data) async -> Data)? = nil) {
        self.music = CompanionMusicLibrary(vaultRoot: rootURL, cacheURL: rootURL.appendingPathComponent(".luna-music-index.json"))
        self.codeHandler = codeHandler
        self.rootURL = rootURL.standardizedFileURL
        self.index = index
        self.localDevice = localDevice
        self.folderID = folderID
    }

    public func connection(_ connection: BEPConnection, didReceive clusterConfig: BEPClusterConfig) async {
        // The companion is single-folder in v1. The peer's config is still
        // accepted so the protocol state machine can advance normally.
    }

    /// Called only after the Mac user has approved this device and the
    /// initial ClusterConfig/Index have been sent. No file access before it.
    public func startServing(_ connection: BEPConnection) {
        let queued = transferLock.withLock { () -> [BEPIndex] in
            authorized = true
            defer { pending.removeAll() }
            return pending
        }
        for incoming in queued { enqueue(incoming, connection: connection) }
    }

    public func connection(_ connection: BEPConnection, didReceive incoming: BEPIndex) async {
        guard incoming.folder == folderID else { return }
        let ready = transferLock.withLock { () -> Bool in
            if !authorized { pending.append(incoming); return false }
            return true
        }
        if ready { enqueue(incoming, connection: connection) }
    }

    private func enqueue(_ incoming: BEPIndex, connection: BEPConnection) {
        transferLock.withLock {
            let previous = transferTask
            transferTask = Task { [self] in
                await previous?.value
                guard !Task.isCancelled else { return }
                do {
                    for removed in incoming.files.filter({ $0.deleted && !$0.invalid })
                        .sorted(by: { $0.name.split(separator: "/").count > $1.name.split(separator: "/").count }) {
                        try receiveDeletion(removed)
                    }
                    for folder in incoming.files where folder.type == .directory && !folder.invalid && !folder.deleted {
                        try receiveDirectory(folder)
                    }
                    for file in incoming.files where file.type == .file && !file.invalid && !file.deleted {
                        try await receive(file, from: connection)
                    }
                    guard !incoming.files.isEmpty else { return }
                    let files = try index.all()
                    try await connection.send(index: BEPIndex(folder: folderID, files: files,
                        lastSequence: files.map(\.sequence).max() ?? 0, isUpdate: false))
                } catch { await connection.close(reason: "Could not save iPhone changes: \(error)") }
            }
        }
    }

    private func safeURL(_ name: String) throws -> URL {
        try BEPFileInfo.validateName(name)
        let root = rootURL.resolvingSymlinksInPath()
        var url = root
        for component in name.split(separator: "/") {
            url.appendPathComponent(String(component))
            var info = stat()
            let result = url.path.withCString { lstat($0, &info) }
            if result == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFLNK) {
                throw VaultTransportError.internalError("A link replaced \(name) on the Mac")
            }
            if result != 0 && errno != ENOENT { throw BEPStreamError.posix(errno) }
        }
        guard url.path.hasPrefix(root.path + "/") else { throw BEPStreamError.closed }
        return url
    }

    private func receive(_ file: BEPFileInfo, from connection: BEPConnection) async throws {
        try file.validateForWire()
        let destination = try safeURL(file.name)
        // Deletions require conflict/tombstone handling; never silently remove
        // an unrelated or newer Mac file from a stale phone announcement.
        if file.deleted { throw BEPStreamError.closed }
        if let current = try index.file(named: file.name), current.type == .file,
           current.blocksHash == file.blocksHash,
           FileManager.default.fileExists(atPath: destination.path) {
            let actual = try BlockLayout.blocks(forFileAt: destination, blockSize: file.effectiveBlockSize)
            guard BlockLayout.blocksHash(actual.blocks) == file.blocksHash else {
                throw VaultTransportError.internalError("The Mac file \(file.name) changed")
            }
            // A prior transfer may have installed the bytes and crashed
            // before echoing the iPhone's version. Confirm that version now.
            var saved = file; saved.sequence = try index.maxSequence() + 1
            try index.upsert(CompanionFileRecord(info: saved))
            return
        }
        if FileManager.default.fileExists(atPath: destination.path) {
            throw VaultTransportError.internalError("A different Mac file already has this name: \(file.name)")
        }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = uploadTempURL(for: file)
        if !FileManager.default.fileExists(atPath: temporary.path) {
            guard FileManager.default.createFile(atPath: temporary.path, contents: nil) else {
                throw VaultTransportError.internalError("Could not prepare Mac upload file")
            }
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: temporary.path)
        guard (attributes[.type] as? FileAttributeType) == .typeRegular,
              (try temporary.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true else {
            throw VaultTransportError.internalError("Mac upload staging was replaced")
        }
        let storedSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        guard storedSize <= file.size else { throw VaultTransportError.internalError("Mac upload staging has an invalid size") }
        let output = try FileHandle(forUpdating: temporary)
        defer { try? output.close() }
        var written: Int64 = 0
        var nextBlock = 0
        for block in file.blocks {
            let end = block.offset + Int64(block.size)
            guard end <= storedSize else { break }
            try output.seek(toOffset: UInt64(block.offset))
            let bytes = try output.read(upToCount: Int(block.size)) ?? Data()
            guard bytes.count == Int(block.size), SHA256Digest.hash(bytes) == block.hash else { break }
            written = end
            nextBlock += 1
        }
        if storedSize != written { try output.truncate(atOffset: UInt64(written)) }
        if nextBlock > 0 {
            try await connection.send(downloadProgress: BEPDownloadProgress(
                folder: folderID, updates: [BEPFileDownloadProgressUpdate(
                    name: file.name, version: file.version, blockIndexes: Array(0..<nextBlock))]))
        }
        var unsynchronizedBytes = 0
        try await BEPBlockTransfer.receive(blocks: file.blocks, startingAt: nextBlock,
            request: { [folderID] offset, block in
                try await connection.request(folder: folderID, name: file.name,
                                             block: block, blockNo: Int32(offset))
            }, write: { _, block, bytes in
                try output.seek(toOffset: UInt64(block.offset))
                try output.write(contentsOf: bytes)
                written += Int64(bytes.count)
                unsynchronizedBytes += bytes.count
                if unsynchronizedBytes >= BEPBlockTransfer.maximumBufferedBytes {
                    try output.synchronize()
                    unsynchronizedBytes = 0
                }
            })
        guard written == file.size else { throw BEPStreamError.closed }
        try output.synchronize()
        try FileManager.default.moveItem(at: temporary, to: destination)
        try? removeUploadTemps(named: file.name)
        let modified = Date(timeIntervalSince1970: Double(file.modifiedS) + Double(file.modifiedNs) / 1_000_000_000)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: destination.path)
        var saved = file; saved.sequence = try index.maxSequence() + 1
        try index.upsert(CompanionFileRecord(info: saved))
    }

    private func uploadTempURL(for file: BEPFileInfo) -> URL {
        let nameHash = SHA256Digest.hash(Data(file.name.utf8)).map { String(format: "%02x", $0) }.joined()
        let versionHash = SHA256Digest.hash(file.version.storageBytes).map { String(format: "%02x", $0) }.joined()
        return rootURL.appendingPathComponent(file.name).deletingLastPathComponent()
            .appendingPathComponent(".luna-upload-\(nameHash)-\(versionHash)")
    }

    private func removeUploadTemps(named name: String) throws {
        let nameHash = SHA256Digest.hash(Data(name.utf8)).map { String(format: "%02x", $0) }.joined()
        let parent = try safeURL(name).deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: parent.path) else { return }
        for url in try FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: [.isSymbolicLinkKey])
        where url.lastPathComponent.hasPrefix(".luna-upload-\(nameHash)-") {
            guard (try url.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true,
                  (try FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType) == .typeRegular else {
                throw VaultTransportError.internalError("Mac upload staging was replaced")
            }
            try FileManager.default.removeItem(at: url)
        }
    }

    private func receiveDirectory(_ folder: BEPFileInfo) throws {
        try folder.validateForWire()
        let destination = try safeURL(folder.name)
        if let existing = try index.file(named: folder.name) {
            guard existing.type == .directory else {
                throw VaultTransportError.internalError("A Mac file already has this folder name: \(folder.name)")
            }
            return
        }
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: destination.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                throw VaultTransportError.internalError("A Mac file already has this folder name: \(folder.name)")
            }
        } else {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        }
        var saved = folder; saved.sequence = try index.maxSequence() + 1
        try index.upsert(CompanionFileRecord(info: saved))
    }

    private func receiveDeletion(_ tombstone: BEPFileInfo) throws {
        try tombstone.validateForWire()
        let destination = try safeURL(tombstone.name)
        let current = try index.file(named: tombstone.name)
        if let current {
            switch tombstone.version.compare(current.version) {
            case .lesser, .concurrentLesser:
                throw VaultTransportError.internalError("The Mac has a newer version of \(tombstone.name)")
            case .equal, .greater, .concurrentGreater: break
            }
        }
        if FileManager.default.fileExists(atPath: destination.path) {
            // A file unknown to the index, or one edited since the index was
            // built, belongs to the Mac user. Never remove it on a stale
            // iPhone cancellation.
            guard let current, !current.deleted else {
                throw VaultTransportError.internalError("The Mac has an unindexed item named \(tombstone.name)")
            }
            if (try destination.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink == true {
                throw VaultTransportError.internalError("A link replaced \(tombstone.name) on the Mac")
            }
            if current.type == .directory {
                guard try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty else {
                    throw VaultTransportError.internalError("The Mac folder \(tombstone.name) is not empty")
                }
            } else {
                let attrs = try FileManager.default.attributesOfItem(atPath: destination.path)
                guard (attrs[.type] as? FileAttributeType) == .typeRegular,
                      (attrs[.size] as? NSNumber)?.int64Value == current.size else {
                    throw VaultTransportError.internalError("The Mac file \(tombstone.name) changed")
                }
                let blocks = try BlockLayout.blocks(forFileAt: destination, blockSize: current.effectiveBlockSize)
                guard BlockLayout.blocksHash(blocks.blocks) == current.blocksHash else {
                    throw VaultTransportError.internalError("The Mac file \(tombstone.name) changed")
                }
            }
            try FileManager.default.removeItem(at: destination)
        }
        try removeUploadTemps(named: tombstone.name)
        var saved = tombstone; saved.sequence = try index.maxSequence() + 1
        try index.upsert(CompanionFileRecord(info: saved))
    }

    public func connection(_ connection: BEPConnection, serve request: BEPRequest) async -> Result<Data, BEPErrorCode> {
        guard transferLock.withLock({ authorized }) else { return .failure(.noSuchFile) }
        if request.folder == MusicFileProtocol.folder {
            guard request.offset == 0, request.size == 0, request.hash.isEmpty, !request.fromTemporary,
                  request.name.utf8.count <= 32_768, let data = Data(base64Encoded: request.name) else { return .failure(.invalidFile) }
            let response = await music.handle(data)
            guard response.count <= MusicFileProtocol.maximumResponseSize else { return .failure(.generic) }
            return .success(response)
        }
        if request.folder == "luna-code-v1" {
            guard let codeHandler, request.offset == 0, request.size == 0, request.hash.isEmpty,
                  !request.fromTemporary, request.name.utf8.count <= 16 * 1024 * 1024,
                  let data = Data(base64Encoded: request.name), data.count <= 12 * 1024 * 1024 else { return .failure(.invalidFile) }
            let response = await codeHandler(data)
            guard response.count <= 12 * 1024 * 1024 else { return .failure(.generic) }
            return .success(response)
        }
        if request.folder == VaultMacBrowseProtocol.folder {
            return await Task.detached(priority: .userInitiated) { CompanionMacBrowser().respond(to: request) }.value
        }
        guard request.folder == folderID,
              let record = try? index.file(named: request.name),
              record.blocks.indices.contains(Int(request.blockNo)),
              record.blocks[Int(request.blockNo)].hash == request.hash,
              record.blocks[Int(request.blockNo)].offset == request.offset,
              record.blocks[Int(request.blockNo)].size == request.size else { return .failure(.noSuchFile) }
        do {
            let url = try safeURL(request.name)
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            try handle.seek(toOffset: UInt64(request.offset))
            let data = try handle.read(upToCount: Int(request.size)) ?? Data()
            guard SHA256Digest.hash(data) == request.hash else { return .failure(.generic) }
            return .success(data)
        } catch { return .failure(.noSuchFile) }
    }

    public func connection(_ connection: BEPConnection, didCloseWith error: Error?) async {
        transferLock.withLock { authorized = false; pending.removeAll(); transferTask?.cancel(); transferTask = nil }
    }
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
