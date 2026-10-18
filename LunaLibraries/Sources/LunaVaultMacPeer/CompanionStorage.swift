import Foundation
import Darwin
import LunaVaultBEP
import LunaMusicFiles

/// Walks only Luna's configured shared folder and companion state. It never
/// scans the rest of the Mac, follows symlinks, or reads file contents.
public struct CompanionStorageScanner: Sendable {
    public let rootURL: URL
    public let stateURL: URL?
    public init(rootURL: URL, stateURL: URL? = nil) {
        self.rootURL = rootURL; self.stateURL = stateURL
    }

    public func scan() throws -> LunaMacStorageSnapshot {
        var volumes: [dev_t: (URL, [LunaMacStorageCategory: Int64])] = [:]
        var seen = Set<String>()
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey]
        func add(_ url: URL, state: Bool, relativePath: String) throws -> Bool {
            try Task.checkCancellation()
            var info = stat()
            guard lstat(url.path, &info) == 0 else { throw CocoaError(.fileReadUnknown) }
            let kind = info.st_mode & S_IFMT
            guard kind != S_IFLNK else { return false }
            guard kind == S_IFDIR || kind == S_IFREG else { return false }
            let identity = "\(info.st_dev):\(info.st_ino)"
            guard seen.insert(identity).inserted else { return false }
            let allocated = try url.resourceValues(forKeys: keys).totalFileAllocatedSize
            let bytes = max(0, allocated.map(Int64.init) ?? Int64(info.st_blocks) * 512)
            let category: LunaMacStorageCategory
            if state { category = relativePath.split(separator: "/").first == "Code" ? .code : .appData }
            else if kind == S_IFDIR || relativePath.split(separator: "/").contains(where: { $0.hasPrefix(".") }) { category = .appData }
            else { category = Self.category(for: url) }
            var volume = volumes[info.st_dev] ?? (url, [:])
            volume.1[category, default: 0] += bytes
            volumes[info.st_dev] = volume
            return kind == S_IFDIR
        }
        // State comes first so an overlapping shared folder cannot count it twice
        // or reclassify companion indexes and identity files as user documents.
        for (input, state) in [(stateURL, true), (Optional(rootURL), false)] {
            guard let input else { continue }
            let root = input.standardizedFileURL.resolvingSymlinksInPath()
            guard try add(root, state: state, relativePath: "") else { continue }
            var failure: Error?
            guard let entries = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(keys),
                options: [.producesRelativePathURLs], errorHandler: { _, error in failure = error; return false }) else {
                throw VaultMacBrowseError("Cannot measure Luna Mac storage. Check folder access on your Mac.")
            }
            for case let url as URL in entries {
                let relative = url.relativePath
                if try !add(url, state: state, relativePath: relative) { entries.skipDescendants() }
            }
            if let failure { throw failure }
        }
        let result = try volumes.map { device, value in
            let capacity = try value.0.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey, .volumeNameKey])
            guard let total = capacity.volumeTotalCapacity, let free = capacity.volumeAvailableCapacity else {
                throw VaultMacBrowseError("Disk capacity is unavailable on your Mac.")
            }
            return LunaMacStorageVolume(id: String(device), name: capacity.volumeName ?? "Mac Storage",
                totalBytes: Int64(total), freeBytes: Int64(free), categories: value.1)
        }.sorted { $0.id < $1.id }
        let snapshot = LunaMacStorageSnapshot(volumes: result)
        try snapshot.validate()
        return snapshot
    }

    public static func category(for url: URL) -> LunaMacStorageCategory {
        let ext = url.pathExtension.lowercased()
        if MusicFileProtocol.extensions.contains(ext) { return .music }
        if ["jpg", "jpeg", "png", "heic", "heif", "gif", "webp", "tif", "tiff", "bmp", "avif", "dng", "raw", "cr2", "cr3", "nef", "arw"].contains(ext) { return .photos }
        if ["mp4", "mov", "m4v", "mkv", "avi", "webm", "mpeg", "mpg", "mts", "m2ts", "3gp"].contains(ext) { return .videos }
        return .files
    }
}

/// One in-flight metadata walk, cached briefly so repeated settings refreshes
/// do not continually traverse a large shared library.
public actor CompanionStorageService {
    private let scanner: CompanionStorageScanner
    private var cached: LunaMacStorageSnapshot?
    private var task: Task<LunaMacStorageSnapshot, Error>?
    public init(rootURL: URL, stateURL: URL? = nil) {
        scanner = CompanionStorageScanner(rootURL: rootURL, stateURL: stateURL)
    }
    public func response(refresh: Bool = false) async -> Data {
        let response: LunaMacStorageResponse
        do { response = LunaMacStorageResponse(snapshot: try await snapshot(refresh: refresh)) }
        catch { response = LunaMacStorageResponse(error: error.localizedDescription) }
        return (try? JSONEncoder().encode(response)) ?? Data()
    }
    private func snapshot(refresh: Bool) async throws -> LunaMacStorageSnapshot {
        if let task { return try await task.value }
        if !refresh, let cached, Date().timeIntervalSince(cached.measuredAt) < 30 { return cached }
        let task = Task.detached(priority: .utility) { [scanner] in try scanner.scan() }
        self.task = task
        defer { self.task = nil }
        let value = try await task.value
        cached = value
        return value
    }
}
