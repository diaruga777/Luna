//
//  PreloadStore.swift
//  ReaderKit
//

import ClipModels
import CryptoKit
import Foundation

/// What a preloaded link resolved to (mirrors the on-disk forms a real save can take).
enum PreloadKind: String, Codable {
    case article          // reader content persisted as <key>.json
    case platform         // a social/video/audio URL — store the descriptor only
    case webArchive       // a non-reader page snapshot persisted as <key>.webarchive
    case unrepresentable  // paywalled (silent bypass failed) / failed — no content
}

enum PreloadState: String, Codable { case pending, loaded, failed }

/// The platform descriptor for a `.platform` preload (so the viewer can show it
/// without re-recognizing).
struct PreloadPlatform: Codable, Equatable {
    var platform: String
    var itemID: String?
}

/// One entry in the shared preload cache, keyed by the canonical URL's hash.
struct PreloadEntry: Codable, Equatable {
    var urlString: String
    var kind: PreloadKind
    var contentFile: String?
    var platform: PreloadPlatform?
    /// Root SAVE item UUID strings whose preload subtree reaches this URL. The
    /// refcount is `owners.count`; the entry's files are deleted when it hits zero.
    var owners: Set<String>
    /// Hashed keys of outbound links discovered on this page (for subtree teardown
    /// and resume). Empty for non-article kinds.
    var children: [String]
    /// How many more levels we still intend to crawl from here (for resume).
    var depthRemaining: Int
    var state: PreloadState
    var updated: Date
}

/// The shared, URL-keyed, refcounted cache of preloaded link pages. **Physically
/// isolated** from real saves: it lives in its own `Preloads/` directory and
/// `preloads.json` index and NEVER touches `readingList.json` / `Articles/`, so a
/// preload bug can only waste cache space, never corrupt the user's library.
///
/// Duplicate links (within one save's tree or across saves) share a single on-disk
/// copy; each referencing root save is an "owner". Deleting a save releases its
/// subtree (removes it from every entry's `owners`); entries with no owners left are
/// deleted. Pure index logic is unit-tested; file I/O is best-effort (a cache).
final class PreloadStore {
    static let shared = PreloadStore()

    private let fileManager = FileManager.default
    private let overrideContainerURL: URL?
    private let lock = NSLock()

    init(containerURL: URL? = nil) {
        self.overrideContainerURL = containerURL
    }

    private var containerURL: URL {
        if let overrideContainerURL { return overrideContainerURL }
        return fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: ReaderSettings.appGroupID)
            ?? fileManager.temporaryDirectory
    }

    private var preloadsDirectory: URL {
        let dir = containerURL.appendingPathComponent("Preloads", isDirectory: true)
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private var indexURL: URL { preloadsDirectory.appendingPathComponent("preloads.json") }

    /// File URL for a preloaded entry's content (article JSON / webarchive).
    func contentURL(fileName: String) -> URL {
        preloadsDirectory.appendingPathComponent(fileName)
    }

    // MARK: - Canonical key

    /// Canonical URL string used for keying (unwrap-free: callers pass the resolved
    /// URL). Lowercased host, no fragment.
    static func canonicalString(for url: URL) -> String {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.fragment = nil
        if let host = components?.host { components?.host = host.lowercased() }
        return components?.url?.absoluteString ?? url.absoluteString
    }

    /// Stable, filesystem-safe key for a URL (sha256 hex of the canonical string).
    static func key(for url: URL) -> String {
        let digest = SHA256.hash(data: Data(canonicalString(for: url).utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Index access

    private func loadIndex() -> [String: PreloadEntry] {
        guard let data = try? Data(contentsOf: indexURL),
              let index = try? JSONDecoder().decode([String: PreloadEntry].self, from: data)
        else { return [:] }
        return index
    }

    private func saveIndex(_ index: [String: PreloadEntry]) {
        guard let data = try? JSONEncoder().encode(index) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }

    /// Read-modify-write the index under the lock, reloading fresh each time so an
    /// extension's concurrent read sees a consistent file.
    @discardableResult
    private func mutate<T>(_ body: (inout [String: PreloadEntry]) -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        var index = loadIndex()
        let result = body(&index)
        saveIndex(index)
        return result
    }

    // MARK: - Reads (safe from any process)

    func entry(for url: URL) -> PreloadEntry? {
        lock.lock(); defer { lock.unlock() }
        return loadIndex()[Self.key(for: url)]
    }

    /// The cached reader content for a preloaded `.article` URL, or nil.
    func articleContent(for url: URL) -> ArticleContent? {
        guard let entry = entry(for: url), entry.kind == .article, entry.state == .loaded,
              let file = entry.contentFile,
              let data = try? Data(contentsOf: contentURL(fileName: file)),
              let content = try? JSONDecoder().decode(ArticleContent.self, from: data)
        else { return nil }
        return content
    }

    // MARK: - Writes

    /// Records a loaded/failed preload result for `url`, owned by `rootID`, returning
    /// the stored entry. `content`/`platform`/`archiveData` are persisted per `kind`.
    @discardableResult
    func record(
        url: URL, rootID: UUID, kind: PreloadKind, depthRemaining: Int,
        content: ArticleContent? = nil, platform: PreloadPlatform? = nil,
        archiveData: Data? = nil, children: [URL] = []
    ) -> PreloadEntry {
        let key = Self.key(for: url)
        var contentFile: String?
        switch kind {
        case .article:
            if let content, let data = try? JSONEncoder().encode(content) {
                contentFile = "\(key).json"
                try? data.write(to: contentURL(fileName: "\(key).json"), options: .atomic)
            }
        case .webArchive:
            if let archiveData {
                contentFile = "\(key).webarchive"
                try? archiveData.write(to: contentURL(fileName: "\(key).webarchive"), options: .atomic)
            }
        case .platform, .unrepresentable:
            break
        }
        let childKeys = children.map { Self.key(for: $0) }
        return mutate { index in
            var entry = index[key] ?? PreloadEntry(
                urlString: Self.canonicalString(for: url), kind: kind, contentFile: contentFile,
                platform: platform, owners: [], children: childKeys,
                depthRemaining: depthRemaining, state: .loaded, updated: Date())
            entry.kind = kind
            if contentFile != nil { entry.contentFile = contentFile }
            if platform != nil { entry.platform = platform }
            entry.children = childKeys
            entry.depthRemaining = max(entry.depthRemaining, depthRemaining)
            entry.state = (kind == .unrepresentable) ? .failed : .loaded
            entry.owners.insert(rootID.uuidString)
            entry.updated = Date()
            index[key] = entry
            return entry
        }
    }

    /// Adds `rootID` as an owner of an EXISTING entry (dedup: a second tree reaching
    /// an already-cached URL). Returns the entry's children keys so the caller can
    /// extend ownership down the shared subtree.
    @discardableResult
    func addOwner(_ rootID: UUID, toKey key: String) -> PreloadEntry? {
        mutate { index in
            guard var entry = index[key] else { return nil }
            entry.owners.insert(rootID.uuidString)
            index[key] = entry
            return entry
        }
    }

    /// Overwrites the cached article content for `url` IF an entry already exists
    /// (a viewer background-refresh), preserving owners/kind. No-op otherwise — a
    /// refresh never creates an unowned entry.
    func refreshArticle(for url: URL, content: ArticleContent) {
        let key = Self.key(for: url)
        lock.lock()
        var index = loadIndex()
        guard var entry = index[key], entry.kind == .article else { lock.unlock(); return }
        let file = entry.contentFile ?? "\(key).json"
        if let data = try? JSONEncoder().encode(content) {
            try? data.write(to: contentURL(fileName: file), options: .atomic)
            entry.contentFile = file
            entry.updated = Date()
            index[key] = entry
            saveIndex(index)
        }
        lock.unlock()
    }

    // MARK: - Teardown

    /// Releases the entire preload subtree owned by `rootID`: removes it from every
    /// entry's `owners`; any entry left with no owners has its files deleted and is
    /// dropped. Only ever deletes files under `Preloads/`.
    func releaseTree(rootID: UUID) {
        let id = rootID.uuidString
        let orphanedFiles: [String] = mutate { index in
            var files: [String] = []
            for (key, var entry) in index where entry.owners.contains(id) {
                entry.owners.remove(id)
                if entry.owners.isEmpty {
                    if let file = entry.contentFile { files.append(file) }
                    index[key] = nil
                } else {
                    index[key] = entry
                }
            }
            return files
        }
        for file in orphanedFiles {
            try? fileManager.removeItem(at: contentURL(fileName: file))
        }
    }

    /// All entries (for resume / diagnostics).
    func allEntries() -> [PreloadEntry] {
        lock.lock(); defer { lock.unlock() }
        return Array(loadIndex().values)
    }
}
