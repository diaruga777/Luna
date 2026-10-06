import Foundation
import LunaMusicFiles

/// Disk downloads and a bounded range LRU share version-qualified identities.
/// This actor never writes to Vault's synced folder or sends mutations to the Mac.
public actor VaultMusicCache {
    public typealias Request = @Sendable (Data) async throws -> Data
    private let root: URL
    private let request: Request
    private let peerID: (@Sendable () -> String)?
    private var blocks: [String: Data] = [:]
    private var order: [String] = []
    private var inFlight: [String: Task<Data, Error>] = [:]
    private let maximumBlocks = 24 // 12 MiB, independent of song/library size.
    public init(root: URL, peerID: (@Sendable () -> String)? = nil, request: @escaping Request) throws {
        self.root = root; self.request = request; self.peerID = peerID
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var directory = root
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
        for file in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) where file.pathExtension == "partial" {
            try? FileManager.default.removeItem(at: file)
        }
    }
    public nonisolated static func url(root: URL, song: MusicSong) -> URL {
        root.appendingPathComponent(MusicFileProtocol.key(song.persistentID.rawValue + ":" + (song.file?.version ?? "")))
            .appendingPathExtension((song.file?.path as NSString?)?.pathExtension ?? "m4a")
    }
    public func range(song: MusicSong, offset: Int64, length: Int) async throws -> Data {
        if let peerID, peerID() != song.peer { throw MusicFileError("This song belongs to a different Mac. Reconnect its Mac or play a downloaded copy.") }
        guard let file = song.file, offset >= 0, length > 0, offset <= file.size,
              Int64(length) <= file.size - offset else { throw MusicFileError("Invalid music range.") }
        var result = Data()
        var cursor = offset
        while cursor < offset + Int64(length) {
            try Task.checkCancellation()
            let blockOffset = cursor / Int64(MusicFileProtocol.chunkSize) * Int64(MusicFileProtocol.chunkSize)
            let blockLength = Int(min(Int64(MusicFileProtocol.chunkSize), file.size - blockOffset))
            let key = song.persistentID.rawValue + ":" + file.version + ":\(blockOffset)"
            let bytes: Data
            if let cached = blocks[key] { bytes = cached }
            else {
                let task: Task<Data, Error>
                if let existing = inFlight[key] { task = existing }
                else {
                    task = Task { [request, peerID] in
                        let payload = try JSONEncoder().encode(MusicFileRequest(.read, path: file.path, version: file.version, offset: blockOffset, length: blockLength))
                        for attempt in 0..<3 {
                            try Task.checkCancellation()
                            do {
                                let data = try await request(payload)
                                if let peerID, peerID() != song.peer { throw MusicFileError("The paired Mac changed during playback. Refresh your library.") }
                                let response = try JSONDecoder().decode(MusicFileResponse.self, from: data)
                                if let error = response.error { throw MusicFileError(error) }
                                guard let bytes = response.data, bytes.count == blockLength else { throw MusicFileError("The Mac returned an incomplete music range.") }
                                return bytes
                            } catch {
                                if error is CancellationError || error is MusicFileError || attempt == 2 { throw error }
                                try await Task.sleep(for: .seconds(attempt + 1))
                            }
                        }
                        throw MusicFileError("The Mac is unavailable.")
                    }
                    inFlight[key] = task
                }
                do { bytes = try await task.value; inFlight[key] = nil }
                catch { inFlight[key] = nil; throw error }
                blocks[key] = bytes
            }
            order.removeAll { $0 == key }; order.append(key)
            while order.count > maximumBlocks { blocks.removeValue(forKey: order.removeFirst()) }
            let start = Int(cursor - blockOffset)
            let count = min(bytes.count - start, Int(offset + Int64(length) - cursor))
            result.append(bytes.subdata(in: start..<start + count)); cursor += Int64(count)
        }
        return result
    }
    public func download(_ song: MusicSong) async throws -> URL {
        guard let file = song.file else { throw MusicFileError("Only Vault songs use this cache.") }
        let destination = Self.url(root: root, song: song)
        if Self.complete(destination, size: file.size) { return destination }
        let free = try FileManager.default.attributesOfFileSystem(forPath: root.path)[.systemFreeSize] as? NSNumber
        guard let free, file.size <= max(0, free.int64Value - 200 * 1024 * 1024) else { throw MusicFileError("There isn’t enough space to cache this song. Free some storage and try again.") }
        let staging = root.appendingPathComponent(UUID().uuidString + ".partial")
        guard FileManager.default.createFile(atPath: staging.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: staging.path)
        #endif
        defer { try? FileManager.default.removeItem(at: staging) }
        let handle = try FileHandle(forWritingTo: staging)
        defer { try? handle.close() }
        var offset: Int64 = 0
        while offset < file.size {
            try Task.checkCancellation()
            let data = try await range(song: song, offset: offset, length: Int(min(Int64(MusicFileProtocol.chunkSize), file.size - offset)))
            try Task.checkCancellation()
            try handle.write(contentsOf: data); offset += Int64(data.count)
        }
        try handle.synchronize(); try handle.close()
        try Task.checkCancellation()
        if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
        try FileManager.default.moveItem(at: staging, to: destination)
        return destination
    }
    public nonisolated static func complete(_ url: URL, size: Int64) -> Bool {
        guard size > 0, let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return false }
        return (attributes[.size] as? NSNumber)?.int64Value == size
    }
    public func purge(keeping: Set<URL>) throws {
        for url in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            where url.pathExtension != "partial" && !keeping.contains(url) {
            try FileManager.default.removeItem(at: url)
        }
    }
}
