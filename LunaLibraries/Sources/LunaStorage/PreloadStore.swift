//
//  PreloadStore.swift
//  ReaderKit
//

import LunaAppConfig
import LunaModels
import CryptoKit
import Foundation

/// What a preloaded link resolved to (mirrors the on-disk forms a real save can take).
public enum PreloadKind: String, Codable {
    case article          // reader content persisted as <key>.json
    case platform         // a social/video/audio URL — store the descriptor only
    case unrepresentable  // paywalled (silent bypass failed) / failed — no content
}

/// One entry in the shared preload cache, keyed by the canonical URL's hash.
///
/// It carries what the page IS. Who holds it is not here — that is the saves
/// database's `preload_pages` mapping and the ownership edges on the file it
/// points at, so a save's delete cascades to a preloaded page the same way it
/// reaches every other artifact.
public struct PreloadEntry: Codable, Equatable {
    public var urlString: String
    public var kind: PreloadKind
    public var contentFile: String?
    /// Last time this page was successfully loaded/refreshed into the preload cache.
    /// nil means the entry predates this field and may be refreshed once on open.
    public var lastLoadedAt: Date?
    /// Hashed keys of outbound links discovered on this page (so a second save
    /// reaching this page can claim the subtree below it). Empty for non-article
    /// kinds.
    public var children: [String]
    /// The owners an index written before version 5 recorded here. Read once, by
    /// the pass that moves them into the database, and never written again.
    var legacyOwners: Set<String>?

    private enum CodingKeys: String, CodingKey {
        case urlString, kind, contentFile, lastLoadedAt, children
        case legacyOwners = "owners"
    }

    public init(
        urlString: String, kind: PreloadKind, contentFile: String? = nil,
        lastLoadedAt: Date? = nil,
        children: [String]
    ) {
        self.urlString = urlString
        self.kind = kind
        self.contentFile = contentFile
        self.lastLoadedAt = lastLoadedAt
        self.children = children
    }

    /// Whether the crawl reached this URL successfully — an article or a
    /// resolved platform link, as opposed to `.unrepresentable`. Derived from
    /// `kind` alone.
    public var loadedSuccessfully: Bool { kind != .unrepresentable }
}

/// Who holds a preloaded page.
///
/// A save's claim is a `file_refs` edge, so deleting the save cascades it away.
/// A session owner has no row to cascade from — it is one of the two fixed
/// sentinels — so its claim is a `file_holders` edge that only it releases.
public enum PreloadPageOwner: Hashable {
    case save(UUID)
    case session(UUID)

    /// The `file_holders` key a session owner writes, and nil for a save, which
    /// holds through `file_refs` instead. Namespaced, because that table also
    /// counts the images a preloaded page holds, keyed by page.
    var holderKey: String? {
        guard case let .session(id) = self else { return nil }
        return "preload-owner:\(id.uuidString)"
    }
}

/// The shared, URL-keyed, refcounted cache of preloaded link pages. Its own
/// content lives in its own `Preloads/` directory under its own `preloads.json`
/// index, so a preload bug can only waste cache space, never corrupt a save.
/// The one thing it shares with the library is the downloaded IMAGES, which go in
/// `Articles/` because a save and a preloaded page routinely point at the same
/// picture; the saves database counts who holds those (`ownershipStore` below) and
/// this store touches nothing else in it.
///
/// Duplicate links (within one save's tree or across saves) share a single on-disk
/// copy, and each referencing root is an owner. The owners are ownership edges in
/// the saves database — `preload_pages` points at the page's file, `file_refs` and
/// `file_holders` count who holds it — so deleting a save cascades to its whole
/// subtree, and the page's file is freed by the trigger and the reaper that free
/// every other artifact. This index says what a page IS, never who wants it.
/// File I/O is best-effort (a cache).
public final class PreloadStore {
    public static let shared = PreloadStore()

    /// A fixed sentinel "owner" for ad-hoc links the user actually TAPS in the reader
    /// (vs. the save-time crawl's per-save owners). A tapped link is materialized on
    /// first open and recorded under this durable owner so it survives app relaunches
    /// and is NOT torn down when the save that surfaced it is deleted — the user reached
    /// it, so it stays instant forever after. (Distinct from the speculative
    /// `pasteboardOwner` below, whose tree is released when the candidate changes.)
    public static let tappedLinkOwner = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

    /// A fixed sentinel "owner" for the CURRENT pasteboard candidate's preloads — bounds
    /// pasteboard preloading to the single clipboard link (its tree is released and
    /// re-crawled when the candidate changes). A real save claims the same cached subtree
    /// on actual save, so content survives this owner later being released.
    public static let pasteboardOwner = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!

    /// The owners that are not saves. Everything else `record` is given is a save
    /// id, whose claim cascades with the save.
    private static let sessionOwners: Set<UUID> = [tappedLinkOwner, pasteboardOwner]

    /// How a root id claims a page. The two sentinels have no row in the saves
    /// database to cascade from, so they hold as sessions.
    static func owner(for rootID: UUID) -> PreloadPageOwner {
        sessionOwners.contains(rootID) ? .session(rootID) : .save(rootID)
    }

    /// The index's own file name, which is never a page's.
    static let indexFileName = "preloads.json"

    private let fileManager = FileManager.default
    private let overrideContainerURL: URL?
    private let lock = NSLock()
    private let fileCoordinator = NSFileCoordinator(filePresenter: nil)
    /// Process-local snapshot of the on-disk index, used ONLY by the synchronous
    /// reader-open fast path so a link tap never re-decodes the whole `preloads.json`
    /// on the main thread (it grows with the preload tree). Refreshed whenever THIS
    /// process writes the index; a concurrent write from another process (the share
    /// extension) can leave it slightly stale, which at worst sends one open down the
    /// async path. The cross-process `entry(for:)`/`mutate` paths still read fresh.
    private var cachedIndex: [String: PreloadEntry]?
    /// Guards the lazy resolution of `ownershipStore` only.
    private let ownershipLock = NSLock()
    private var resolvedOwnershipStore: SavesStore?
    /// Guards the once-per-process move of a pre-version-5 index's owner sets into
    /// the database. Held across the work, so a second thread waits for it rather
    /// than racing past a flag that is set but not yet true.
    private let migrationLock = NSLock()
    private var migratedLegacyOwners = false

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
    }

    /// The store that counts who holds the shared `Articles/img-…` files. A
    /// preloaded page and a save can point at the same downloaded image, so the
    /// saves database counts both (`SavedFileOwnership`) and this cache's own index
    /// counts only its pages.
    ///
    /// Resolved lazily, and to the shared store whenever this store is the shared
    /// one, so the process ends up with one connection to the database rather than
    /// two.
    private func ownershipStore() -> SavesStore {
        guard let overrideContainerURL else { return .shared }
        ownershipLock.lock()
        defer { ownershipLock.unlock() }
        if let resolvedOwnershipStore { return resolvedOwnershipStore }
        let store = SavesStore(containerURL: overrideContainerURL, preloadStore: self)
        resolvedOwnershipStore = store
        return store
    }

    private var containerURL: URL {
        if let overrideContainerURL { return overrideContainerURL }
        // The one container resolution, shared with `SavesStore`: the
        // preload cache sits beside the list it feeds, and a staged run points
        // both at the same scratch directory.
        return AppConfig.sharedContainerURL(fileManager) ?? fileManager.temporaryDirectory
    }

    private var preloadsDirectory: URL {
        let dir = containerURL.appendingPathComponent("Preloads", isDirectory: true)
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        BackupPolicy.excludeFromBackups(dir)
        return dir
    }

    private var indexURL: URL { preloadsDirectory.appendingPathComponent(Self.indexFileName) }

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

    private func loadIndex(at url: URL? = nil) -> [String: PreloadEntry] {
        guard let data = try? Data(contentsOf: url ?? indexURL),
              let index = try? JSONDecoder().decode([String: PreloadEntry].self, from: data)
        else { return [:] }
        return index
    }

    private func saveIndex(_ index: [String: PreloadEntry], to url: URL) {
        guard let data = try? JSONEncoder().encode(index) else { return }
        try? data.write(to: url, options: .atomic)
        BackupPolicy.excludeFromBackups(preloadsDirectory)
    }

    /// Read-modify-write the index under the in-process lock AND an
    /// `NSFileCoordinator` writing coordination — the app and its extensions all
    /// mutate this shared index, and an uncoordinated load→save would let the
    /// last writer clobber the others' owner sets (leaking or over-deleting
    /// preloaded pages).
    @discardableResult
    private func mutate<T>(_ body: (inout [String: PreloadEntry]) -> T) -> T {
        coordinatedMutateJSONIndex(
            lock: lock, fileCoordinator: fileCoordinator, indexURL: indexURL,
            load: { self.loadIndex(at: $0) },
            save: { index, url in
                self.saveIndex(index, to: url)
                self.cachedIndex = index   // keep the sync fast-path snapshot fresh for this process
            },
            body: body)
    }

    /// Index lookup for the synchronous reader-open fast path: serves from the
    /// process-local snapshot, decoding `preloads.json` at most ONCE per process
    /// (vs. `entry(for:)`, which re-decodes the whole file every call).
    private func synchronousEntry(for url: URL) -> PreloadEntry? {
        lock.lock(); defer { lock.unlock() }
        if cachedIndex == nil { cachedIndex = loadIndex() }
        return cachedIndex?[Self.key(for: url)]
    }

    // MARK: - Reads (safe from any process)

    public func entry(for url: URL) -> PreloadEntry? {
        entry(forKey: Self.key(for: url))
    }

    func entry(forKey key: String) -> PreloadEntry? {
        lock.lock(); defer { lock.unlock() }
        return loadIndex()[key]
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
        if let boxed = memoryCache.object(forKey: cacheKey) {
            SharedDiagnosticLog.record("cache HIT (memory) \(url.absoluteString)", category: "preload-tap")
            return boxed.content
        }
        guard let entry = synchronousEntry(for: url), entry.kind == .article,
              let file = entry.contentFile else {
            SharedDiagnosticLog.record("cache MISS \(url.absoluteString)", category: "preload-tap")
            return nil
        }
        let fileURL = contentURL(fileName: file)
        let size = (try? fileManager.attributesOfItem(atPath: fileURL.path)[.size] as? Int) ?? nil
        guard (size ?? 0) <= Self.maxSyncDecodeBytes,
              let data = try? Data(contentsOf: fileURL),
              let content = try? JSONDecoder().decode(ArticleContent.self, from: data)
        else {
            SharedDiagnosticLog.record("cache MISS (disk decode failed/oversized) \(url.absoluteString)",
                                       category: "preload-tap")
            return nil
        }
        memoryCache.setObject(ContentBox(content), forKey: cacheKey)
        SharedDiagnosticLog.record("cache HIT (disk, sync-decoded) \(url.absoluteString)",
                                   category: "preload-tap")
        return content
    }

    /// The cached reader content for a preloaded `.article` URL, or nil. Serves an
    /// in-memory hit immediately; otherwise decodes from disk and warms memory so the
    /// next open is synchronous. Run off-main for the disk path.
    public func articleContent(for url: URL) -> ArticleContent? {
        let cacheKey = Self.key(for: url) as NSString
        if let boxed = memoryCache.object(forKey: cacheKey) { return boxed.content }
        guard let entry = entry(for: url), entry.kind == .article,
              let file = entry.contentFile,
              let data = try? Data(contentsOf: contentURL(fileName: file)),
              let content = try? JSONDecoder().decode(ArticleContent.self, from: data)
        else { return nil }
        memoryCache.setObject(ContentBox(content), forKey: cacheKey)
        return content
    }

    public func articleRefreshDue(
        for url: URL, now: Date = Date(), minimumAge: TimeInterval
    ) -> Bool {
        guard let entry = entry(for: url), entry.kind == .article
        else { return false }
        guard let lastLoadedAt = entry.lastLoadedAt else { return true }
        return now.timeIntervalSince(lastLoadedAt) >= minimumAge
    }

    // MARK: - Writes

    /// Records a loaded/failed preload result for `url`, owned by `rootID`, returning
    /// the stored entry. `content` is persisted only for `kind == .article`.
    @discardableResult
    public func record(
        url: URL, rootID: UUID, kind: PreloadKind,
        content: ArticleContent? = nil,
        children: [URL] = []
    ) -> PreloadEntry? {
        migrateLegacyOwnersIfNeeded()
        let key = Self.key(for: url)
        // The page's file is claimed before it is written: the database decides
        // the name, so a page another process registered first is written once
        // rather than twice, and a page that nothing can own is not written at
        // all. A page caching no content reserves its name without using it.
        guard let fileName = ownershipStore().claimPreloadPage(
            urlKey: key, owner: Self.owner(for: rootID))
        else { return nil }
        var contentFile: String?
        if kind == .article, let content, let data = try? JSONEncoder().encode(content) {
            contentFile = fileName
            let fileURL = contentURL(fileName: fileName)
            try? data.write(to: fileURL, options: .atomic)
            BackupPolicy.excludeFromBackups(fileURL)
        }
        let childKeys = children.map { Self.key(for: $0) }
        let now = Date()
        let entry: PreloadEntry = mutate { index in
            var entry = index[key] ?? PreloadEntry(
                urlString: Self.canonicalString(for: url), kind: kind, contentFile: contentFile,
                lastLoadedAt: kind == .unrepresentable ? nil : now,
                children: childKeys)
            entry.kind = kind
            if contentFile != nil { entry.contentFile = contentFile }
            entry.children = childKeys
            if entry.loadedSuccessfully { entry.lastLoadedAt = now }
            index[key] = entry
            return entry
        }
        // Tie this page's downloaded images to the page key so they're freed when (and
        // only when) the page itself is released.
        if kind == .article, let content {
            ownershipStore().setPreloadedPageImages(
                pageKey: key, fileNames: ArticleImageFiles.referencedNames(in: content))
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
        migrateLegacyOwnersIfNeeded()
        guard ownershipStore().holdPreloadPage(urlKey: key, owner: Self.owner(for: rootID))
        else { return nil }
        return entry(forKey: key)
    }

    /// Overwrites the cached article content for `url` IF the cache already holds
    /// the page (a viewer background-refresh), preserving its kind and its owners.
    /// No-op otherwise — a refresh never creates an unowned entry.
    public func refreshArticle(for url: URL, content: ArticleContent) {
        migrateLegacyOwnersIfNeeded()
        let key = Self.key(for: url)
        let now = Date()
        // The page's own file, which it holds whether or not it has written one
        // yet. An entry that failed to encode its content on first record has a
        // name reserved and nothing in it.
        guard let file = ownershipStore().preloadPageFileName(urlKey: key) else { return }
        let refreshed: Bool = mutate { index in
            guard var entry = index[key], entry.kind == .article,
                  let data = try? JSONEncoder().encode(content) else { return false }
            let fileURL = contentURL(fileName: file)
            try? data.write(to: fileURL, options: .atomic)
            BackupPolicy.excludeFromBackups(fileURL)
            entry.contentFile = file
            entry.lastLoadedAt = now
            index[key] = entry
            return true
        }
        if refreshed {
            memoryCache.setObject(ContentBox(content), forKey: key as NSString)
        }
    }

    // MARK: - Teardown

    /// Releases the entire preload subtree owned by `rootID`.
    ///
    /// One call, no tree walk: every page the crawl reached carries an ownership
    /// edge for its root, so dropping that root's edges releases the subtree at
    /// once. Each page whose last edge went reaches `pending_deletes` through the
    /// same trigger every other artifact uses, and `PendingDeleteReaper` unlinks it.
    public func releaseTree(rootID: UUID) {
        migrateLegacyOwnersIfNeeded()
        ownershipStore().releasePreloadPages(ownedBy: Self.owner(for: rootID))
        pruneReleasedPages()
    }

    /// Drops every index entry the database no longer holds a page for, and
    /// releases what those pages held.
    ///
    /// A sweep rather than the answer from one release, because the release that
    /// matters most never comes through `releaseTree` at all: deleting a save
    /// takes its edges with the row, so the pages it emptied are already gone by
    /// the time this store is told. The live set is read INSIDE the index write,
    /// so a page another process records mid-sweep is either wholly present or
    /// wholly absent, never pruned out from under its own row.
    private func pruneReleasedPages() {
        let orphanedKeys: [String] = mutate { index in
            let live = self.ownershipStore().preloadPageKeys()
            let gone = index.keys.filter { !live.contains($0) }
            for key in gone { index[key] = nil }
            return gone
        }
        guard !orphanedKeys.isEmpty else { return }
        // Release the orphaned pages' images (each deleted only if no other page or
        // save owns it) and drop their decoded copies from the in-memory cache.
        ownershipStore().releasePreloadedPages(pageKeys: orphanedKeys)
        for key in orphanedKeys {
            memoryCache.removeObject(forKey: key as NSString)
        }
    }

    // MARK: - Migration

    /// Moves the owner sets of an index written before the database counted them.
    ///
    /// Runs once per process, and only does work while an entry still carries the
    /// old set. The database is written FIRST: a run interrupted between the two
    /// finds the sets still in the index and registers them again, which is
    /// idempotent, where the other order would lose an owner and strand its files.
    private func migrateLegacyOwnersIfNeeded() {
        migrationLock.lock()
        defer { migrationLock.unlock() }
        guard !migratedLegacyOwners else { return }
        migratedLegacyOwners = true

        let legacy = legacyOwnedPages()
        guard !legacy.isEmpty else { return }

        var adopted: [String: String] = [:]
        for page in legacy {
            let owners = page.owners
                .compactMap(UUID.init(uuidString:))
                .map(Self.owner(for:))
            adopted[page.key] = ownershipStore().claimPreloadPage(
                urlKey: page.key, existingFileName: page.fileName, owners: owners)
        }
        mutate { index in
            for (key, var entry) in index where entry.legacyOwners != nil {
                entry.legacyOwners = nil
                // A page nothing could adopt — every owner gone — leaves the index
                // with it. Its file is not the database's to free, so unlink it here.
                guard let file = adopted[key] else {
                    if let stale = entry.contentFile {
                        try? fileManager.removeItem(at: contentURL(fileName: stale))
                    }
                    index[key] = nil
                    continue
                }
                if entry.contentFile != nil { entry.contentFile = file }
                index[key] = entry
            }
        }
    }

    /// The pages an old index still counts owners for. A read, not a mutation, so
    /// it takes the index lock without the writing coordination.
    private func legacyOwnedPages() -> [(key: String, fileName: String?, owners: Set<String>)] {
        lock.lock(); defer { lock.unlock() }
        return loadIndex().compactMap { key, entry in
            guard let owners = entry.legacyOwners, !owners.isEmpty else { return nil }
            return (key, entry.contentFile, owners)
        }
    }
}
