//
//  ImageReferenceStore.swift
//  LunaStorage
//

import LunaModels
import Foundation

/// Reference counting for downloaded article images.
///
/// Article images live in the shared `Articles/` directory keyed by a hash of the
/// image URL (`img-<hash>.<ext>`), so the SAME image is one on-disk file no matter
/// how many saved articles or preloaded link pages reference it. Without ownership
/// tracking those files could never be safely deleted — they leaked forever. This
/// store records, per image file, the set of *content* that references it (a saved
/// item or a preloaded page), and deletes an image file ONLY when its last owner is
/// released. It is the image-level analogue of `PreloadStore`'s page-level refcount.
///
/// Owners are opaque "content keys": `item:<uuid>` for a real save, or the preload
/// page's sha256 key for a preloaded page. Index lives in `Articles/imageRefs.json`.
/// Pure index logic is unit-tested; file I/O is best-effort.
public final class ImageReferenceStore {
    public static let shared = ImageReferenceStore()

    private let fileManager = FileManager.default
    private let overrideContainerURL: URL?
    private let lock = NSLock()
    private let fileCoordinator = NSFileCoordinator(filePresenter: nil)

    public init(containerURL: URL? = nil) {
        self.overrideContainerURL = containerURL
    }

    private var containerURL: URL {
        if let overrideContainerURL { return overrideContainerURL }
        return fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: ReadingListStore.appGroupID)
            ?? fileManager.temporaryDirectory
    }

    /// Images live alongside parsed article JSON in `Articles/` (shared, URL-hash-keyed).
    private var articlesDirectory: URL {
        let dir = containerURL.appendingPathComponent("Articles", isDirectory: true)
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private var indexURL: URL { articlesDirectory.appendingPathComponent("imageRefs.json") }

    // MARK: - Content keys

    /// Owner key for a real saved item.
    public static func itemKey(_ id: UUID) -> String { "item:\(id.uuidString)" }

    /// The downloaded image file names referenced by a piece of article content.
    public static func imageFiles(in content: ArticleContent) -> [String] {
        content.blocks.compactMap { $0.imageFileName }
    }

    // MARK: - Index access

    private func loadIndex(at url: URL) -> [String: Set<String>] {
        guard let data = try? Data(contentsOf: url),
              let index = try? JSONDecoder().decode([String: Set<String>].self, from: data)
        else { return [:] }
        return index
    }

    private func saveIndex(_ index: [String: Set<String>], to url: URL) {
        guard let data = try? JSONEncoder().encode(index) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// Read-modify-write under the in-process lock AND an `NSFileCoordinator`
    /// writing coordination: the app, share/action extensions, and intents all
    /// mutate this shared index, and an uncoordinated load→save would let the
    /// last writer clobber the others' refcounts (deleting images still owned
    /// by a live save, or leaking orphans forever).
    @discardableResult
    private func mutate<T>(_ body: (inout [String: Set<String>]) -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        func perform(_ url: URL) -> T {
            var index = loadIndex(at: url)
            let result = body(&index)
            saveIndex(index, to: url)
            return result
        }
        var coordResult: T?
        var coordError: NSError?
        fileCoordinator.coordinate(writingItemAt: indexURL, options: [], error: &coordError) { url in
            coordResult = perform(url)
        }
        return coordResult ?? perform(indexURL)
    }

    // MARK: - Ownership

    /// Declares that `contentKey` references exactly `files`. Files it previously
    /// referenced but no longer does lose this owner (and are deleted if no owner
    /// remains); newly referenced files gain it. Idempotent.
    public func setReferences(contentKey: String, files: [String]) {
        let wanted = Set(files)
        let orphaned: [String] = mutate { index in
            var toDelete: [String] = []
            for (file, var owners) in index where owners.contains(contentKey) && !wanted.contains(file) {
                owners.remove(contentKey)
                if owners.isEmpty { index[file] = nil; toDelete.append(file) }
                else { index[file] = owners }
            }
            for file in wanted {
                var owners = index[file] ?? []
                owners.insert(contentKey)
                index[file] = owners
            }
            return toDelete
        }
        deleteFiles(orphaned)
    }

    /// Releases every image owned by `contentKey`; any image left with no owners is
    /// deleted from disk. Called when a save or preloaded page is removed.
    public func removeReferences(contentKey: String) {
        let orphaned: [String] = mutate { index in
            var toDelete: [String] = []
            for (file, var owners) in index where owners.contains(contentKey) {
                owners.remove(contentKey)
                if owners.isEmpty { index[file] = nil; toDelete.append(file) }
                else { index[file] = owners }
            }
            return toDelete
        }
        deleteFiles(orphaned)
    }

    /// Only ever deletes `img-` files directly inside `Articles/` (never an item's
    /// content JSON, thumbnail, or anything outside the directory).
    private func deleteFiles(_ files: [String]) {
        let dir = articlesDirectory
        for file in files
        where file.hasPrefix("img-") && file == URL(fileURLWithPath: file).lastPathComponent {
            try? fileManager.removeItem(at: dir.appendingPathComponent(file))
        }
    }

    // MARK: - Migration

    /// One-time backfill so images shared with pre-existing saves/preloads (downloaded
    /// before ownership tracking existed) aren't deleted out from under a still-present
    /// owner. Registers every current save's and preloaded page's images, then marks
    /// the migration done. Safe to call every launch — the flag makes it a no-op after
    /// the first run.
    public func backfillIfNeeded(readingList: ReadingListStore, preloads: PreloadStore) {
        let defaults = UserDefaults(suiteName: ReadingListStore.appGroupID)
        let flag = "imageRefsBackfilled.v1"
        guard defaults?.bool(forKey: flag) != true else { return }
        for item in readingList.items() {
            guard let content = readingList.content(for: item) else { continue }
            setReferences(contentKey: Self.itemKey(item.id), files: Self.imageFiles(in: content))
        }
        preloads.backfillImageOwnership(into: self)
        defaults?.set(true, forKey: flag)
    }
}
