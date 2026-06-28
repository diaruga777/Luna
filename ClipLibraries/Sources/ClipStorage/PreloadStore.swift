//
//  PreloadStore.swift
//  ReaderKit
//

import ClipModels
import CryptoKit
import Foundation

/// What a preloaded link resolved to (mirrors the on-disk forms a real save can take).
public enum PreloadKind: String, Codable {
    case article          // reader content persisted as <key>.json
    case platform         // a social/video/audio URL — store the descriptor only
    case webArchive       // a non-reader page snapshot persisted as <key>.webarchive
    case unrepresentable  // paywalled (silent bypass failed) / failed — no content
}

public enum PreloadState: String, Codable { case pending, loaded, failed }

/// The platform descriptor for a `.platform` preload (so the viewer can show it
/// without re-recognizing).
public struct PreloadPlatform: Codable, Equatable {
    public var platform: String
    public var itemID: String?

    public init(platform: String, itemID: String?) {
        self.platform = platform
        self.itemID = itemID
    }
}

/// One entry in the shared preload cache, keyed by the canonical URL's hash.
public struct PreloadEntry: Codable, Equatable {
    public var urlString: String
    public var kind: PreloadKind
    public var contentFile: String?
    public var platform: PreloadPlatform?
    /// Root SAVE item UUID strings whose preload subtree reaches this URL. The
    /// refcount is `owners.count`; the entry's files are deleted when it hits zero.
    public var owners: Set<String>
    /// Hashed keys of outbound links discovered on this page (for subtree teardown
    /// and resume). Empty for non-article kinds.
    public var children: [String]
    /// How many more levels we still intend to crawl from here (for resume).
    public var depthRemaining: Int
    public var state: PreloadState
    public var updated: Date
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
public final class PreloadStore {
    public static let shared = PreloadStore()

    private let fileManager = FileManager.default
    private let overrideContainerURL: URL?
    private let lock = NSLock()
    /// Refcount for the images these preloaded pages downloaded into the shared
    /// `Articles/` cache, so an orphaned page's images are freed too (and never freed
    /// while another page/save still references them). Same container as this store.
    private let imageReferences: ImageReferenceStore

    /// In-memory cache of decoded article content, keyed by URL hash. Lets the inline
    /// link viewer resolve a preloaded page **synchronously on the main thread** (no
    /// disk read / JSON decode), so a cache hit renders the reader on the first frame
    /// with NO spinner. Boxed because `NSCache` requires a class value. Purged on
    /// memory pressure; a miss just falls back to the on-disk decode.
    private final class ContentBox { let content: ArticleContent
        init(_ content: ArticleContent) { self.content = content } }
    private let memoryCache: NSCache<NSString, ContentBox> = {
        let cache = NSCache<NSString, ContentBox>()
        cache.countLimit = 32   // recent reader-reachable pages; bounded for memory
        return cache
    }()

    public init(containerURL: URL? = nil) {
        self.overrideContainerURL = containerURL
        self.imageReferences = ImageReferenceStore(containerURL: containerURL)
    }

    private var containerURL: URL {
        if let overrideContainerURL { return overrideContainerURL }
        return fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: ReadingListStore.appGroupID)
            ?? fileManager.temporaryDirectory
    }

    private var preloadsDirectory: URL {
        let dir = containerURL.appendingPathComponent("Preloads", isDirectory: true)
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private var indexURL: URL { preloadsDirectory.appendingPathComponent("preloads.json") }

    /// File URL for a preloaded entry's content (article JSON / webarchive).
    public func contentURL(fileName: String) -> URL {
        preloadsDirectory.appendingPathComponent(fileName)
    }

    // MARK: - Canonical key

    /// Canonical URL string used for keying (unwrap-free: callers pass the resolved
    /// URL). Lowercased host, no fragment.
    public static func canonicalString(for url: URL) -> String {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.fragment = nil
        if let host = components?.host { components?.host = host.lowercased() }
        return components?.url?.absoluteString ?? url.absoluteString
    }

    /// Stable, filesystem-safe key for a URL (sha256 hex of the canonical string).
    public static func key(for url: URL) -> String {
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

    public func entry(for url: URL) -> PreloadEntry? {
        lock.lock(); defer { lock.unlock() }
        return loadIndex()[Self.key(for: url)]
    }

    /// Largest preloaded article we'll decode SYNCHRONOUSLY on the main thread (an
    /// init-time instant open). Comfortably above a normal article's JSON; a rare
    /// larger page falls back to the async probe rather than risk a main-thread hitch.
    private static let maxSyncDecodeBytes = 2_000_000

    /// The cached reader content for a preloaded `.article` URL, resolvable WITHOUT a
    /// thread/await hop so the inline link viewer can render the reader on the first
    /// frame with no spinner. Serves an in-memory hit immediately; on a memory miss it
    /// does a size-bounded synchronous disk decode (and warms memory). Returns nil for
    /// a genuine miss or an oversized file (which defers to the async path).
    public func synchronousArticleContent(for url: URL) -> ArticleContent? {
        let cacheKey = Self.key(for: url) as NSString
        if let boxed = memoryCache.object(forKey: cacheKey) { return boxed.content }
        guard let entry = entry(for: url), entry.kind == .article, entry.state == .loaded,
              let file = entry.contentFile else { return nil }
        let fileURL = contentURL(fileName: file)
        let size = (try? fileManager.attributesOfItem(atPath: fileURL.path)[.size] as? Int) ?? nil
        guard (size ?? 0) <= Self.maxSyncDecodeBytes,
              let data = try? Data(contentsOf: fileURL),
              let content = try? JSONDecoder().decode(ArticleContent.self, from: data)
        else { return nil }
        memoryCache.setObject(ContentBox(content), forKey: cacheKey)
        return content
    }

    /// The cached reader content for a preloaded `.article` URL, or nil. Serves an
    /// in-memory hit immediately; otherwise decodes from disk and warms memory so the
    /// next open is synchronous. Run off-main for the disk path.
    public func articleContent(for url: URL) -> ArticleContent? {
        let cacheKey = Self.key(for: url) as NSString
        if let boxed = memoryCache.object(forKey: cacheKey) { return boxed.content }
        guard let entry = entry(for: url), entry.kind == .article, entry.state == .loaded,
              let file = entry.contentFile,
              let data = try? Data(contentsOf: contentURL(fileName: file)),
              let content = try? JSONDecoder().decode(ArticleContent.self, from: data)
        else { return nil }
        memoryCache.setObject(ContentBox(content), forKey: cacheKey)
        return content
    }

    // MARK: - Writes

    /// Records a loaded/failed preload result for `url`, owned by `rootID`, returning
    /// the stored entry. `content`/`platform`/`archiveData` are persisted per `kind`.
    @discardableResult
    public func record(
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
        let entry: PreloadEntry = mutate { index in
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
        // Tie this page's downloaded images to the page key so they're freed when (and
        // only when) the page itself is released.
        if kind == .article, let content {
            imageReferences.setReferences(
                contentKey: key, files: ImageReferenceStore.imageFiles(in: content))
            // Warm the in-memory cache so the very first tap after a preload is a
            // synchronous, spinner-free hit (no disk read on the way to the reader).
            memoryCache.setObject(ContentBox(content), forKey: key as NSString)
        }
        return entry
    }

    /// Adds `rootID` as an owner of an EXISTING entry (dedup: a second tree reaching
    /// an already-cached URL). Returns the entry's children keys so the caller can
    /// extend ownership down the shared subtree.
    @discardableResult
    public func addOwner(_ rootID: UUID, toKey key: String) -> PreloadEntry? {
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
    public func refreshArticle(for url: URL, content: ArticleContent) {
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
            memoryCache.setObject(ContentBox(content), forKey: key as NSString)
        }
        lock.unlock()
    }

    // MARK: - Teardown

    /// Releases the entire preload subtree owned by `rootID`: removes it from every
    /// entry's `owners`; any entry left with no owners has its files deleted and is
    /// dropped. Only ever deletes files under `Preloads/`.
    public func releaseTree(rootID: UUID) {
        let id = rootID.uuidString
        var orphanedKeys: [String] = []
        let orphanedFiles: [String] = mutate { index in
            var files: [String] = []
            for (key, var entry) in index where entry.owners.contains(id) {
                entry.owners.remove(id)
                if entry.owners.isEmpty {
                    if let file = entry.contentFile { files.append(file) }
                    orphanedKeys.append(key)
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
        // Release each orphaned page's images (deleted only if no other page/save owns
        // them) and drop its decoded copy from the in-memory cache.
        for key in orphanedKeys {
            imageReferences.removeReferences(contentKey: key)
            memoryCache.removeObject(forKey: key as NSString)
        }
    }

    /// Registers the images of every already-loaded `.article` entry with `imageStore`
    /// (one-time migration backfill — see `ImageReferenceStore.backfillIfNeeded`).
    public func backfillImageOwnership(into imageStore: ImageReferenceStore) {
        lock.lock()
        let index = loadIndex()
        lock.unlock()
        for (key, entry) in index where entry.kind == .article {
            guard let file = entry.contentFile,
                  let data = try? Data(contentsOf: contentURL(fileName: file)),
                  let content = try? JSONDecoder().decode(ArticleContent.self, from: data)
            else { continue }
            imageStore.setReferences(
                contentKey: key, files: ImageReferenceStore.imageFiles(in: content))
        }
    }

    /// All entries (for resume / diagnostics).
    public func allEntries() -> [PreloadEntry] {
        lock.lock(); defer { lock.unlock() }
        return Array(loadIndex().values)
    }
}
