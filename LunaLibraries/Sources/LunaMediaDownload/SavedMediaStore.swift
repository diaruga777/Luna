//
//  SavedMediaStore.swift
//  Luna
//

import AVFoundation
import ImageIO
import LunaAppConfig
import LunaModels
import LunaStorage
import LunaURLClassification
import Foundation
import UIKit
import UniformTypeIdentifiers

private enum SavedMediaStoreMutationError: Error {
    case itemRemoved
}

public struct SavedMediaItem: Codable, Identifiable, Equatable {
    public enum StorageState: Codable, Equatable {
        case undownloaded
        case localFile(fileName: String)
        /// `pendingLocal*` make the destructive half of local -> Photos recoverable:
        /// the Photos identifier is committed first, then these files are removed and
        /// the pending names are cleared in a second atomic manifest write.
        case photosReference(
            localIdentifier: String,
            pendingLocalFileName: String?,
            pendingThumbnailFileName: String?)

        private enum CodingKeys: String, CodingKey {
            case type, fileName, localIdentifier, pendingLocalFileName, pendingThumbnailFileName
        }
        private enum Kind: String, Codable { case undownloaded, localFile, photosReference }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            switch try container.decode(Kind.self, forKey: .type) {
            case .undownloaded:
                self = .undownloaded
            case .localFile:
                self = .localFile(fileName: try container.decode(String.self, forKey: .fileName))
            case .photosReference:
                self = .photosReference(
                    localIdentifier: try container.decode(String.self, forKey: .localIdentifier),
                    pendingLocalFileName: try container.decodeIfPresent(
                        String.self, forKey: .pendingLocalFileName),
                    pendingThumbnailFileName: try container.decodeIfPresent(
                        String.self, forKey: .pendingThumbnailFileName))
            }
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .undownloaded:
                try container.encode(Kind.undownloaded, forKey: .type)
            case .localFile(let fileName):
                try container.encode(Kind.localFile, forKey: .type)
                try container.encode(fileName, forKey: .fileName)
            case .photosReference(let identifier, let pendingFile, let pendingThumbnail):
                try container.encode(Kind.photosReference, forKey: .type)
                try container.encode(identifier, forKey: .localIdentifier)
                try container.encodeIfPresent(pendingFile, forKey: .pendingLocalFileName)
                try container.encodeIfPresent(pendingThumbnail, forKey: .pendingThumbnailFileName)
            }
        }
    }

    public let id: UUID
    public var sourceURLString: String
    public var title: String?
    public var dateSaved: Date
    /// When non-nil, this row lives in the archive tray. Re-downloads preserve
    /// the value so playback availability never implicitly unarchives it.
    public var archivedAt: Date?
    /// Nil until resolution/download establishes the actual resource type.
    public var kind: MediaAsset.Kind?
    public var storageState: StorageState
    public var thumbnailFileName: String?
    /// The content platform this save belongs to, recognized from
    /// `sourceURLString` (nil for a platform `PlatformRecognizer` doesn't know).
    public var platform: ContentPlatform?
    /// A durable per-platform item id (tweet id, post shortcode, video id, …)
    /// extracted from the URL by `PlatformRecognizer` — used, together with
    /// `platform`, to dedupe saves whose URLs aren't byte-identical (a share
    /// link vs. its resolved permalink, tracking params, etc.).
    public var platformItemID: String?

    /// Title if fetched, else the raw URL as a last resort — the single
    /// fallback rule every UI surface should use instead of reaching for
    /// `sourceURLString` directly.
    public var displayTitle: String { title ?? sourceURLString }

    public var isArchived: Bool { archivedAt != nil }

    public var fileName: String? {
        guard case .localFile(let fileName) = storageState else { return nil }
        return fileName
    }

    public var photosLocalIdentifier: String? {
        guard case .photosReference(let identifier, _, _) = storageState else { return nil }
        return identifier
    }

    public var fileURL: URL? {
        fileName.map { SavedMediaStore.shared.mediaDirectory.appendingPathComponent($0) }
    }

    public var thumbnailURL: URL? {
        thumbnailFileName.map { SavedMediaStore.shared.thumbnailDirectory.appendingPathComponent($0) }
    }

    private enum CodingKeys: String, CodingKey {
        case id, sourceURLString, title, dateSaved, archivedAt, kind, storageState, fileName, thumbnailFileName
        case platform, platformItemID
    }

    public init(
        id: UUID, sourceURLString: String, title: String?, dateSaved: Date,
        kind: MediaAsset.Kind?, storageState: StorageState,
        thumbnailFileName: String?,
        platform: ContentPlatform? = nil, platformItemID: String? = nil
    ) {
        self.id = id
        self.sourceURLString = sourceURLString
        self.title = title
        self.dateSaved = dateSaved
        self.archivedAt = nil
        self.kind = kind
        self.storageState = storageState
        self.thumbnailFileName = thumbnailFileName
        self.platform = platform
        self.platformItemID = platformItemID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        sourceURLString = try container.decode(String.self, forKey: .sourceURLString)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        dateSaved = try container.decode(Date.self, forKey: .dateSaved)
        archivedAt = try container.decodeIfPresent(Date.self, forKey: .archivedAt)
        kind = try container.decodeIfPresent(MediaAsset.Kind.self, forKey: .kind)
        thumbnailFileName = try container.decodeIfPresent(String.self, forKey: .thumbnailFileName)
        platform = try? container.decodeIfPresent(ContentPlatform.self, forKey: .platform)
        platformItemID = try container.decodeIfPresent(String.self, forKey: .platformItemID)
        if let state = try container.decodeIfPresent(StorageState.self, forKey: .storageState) {
            storageState = state
        } else if let legacyFileName = try container.decodeIfPresent(String.self, forKey: .fileName),
                  !legacyFileName.isEmpty {
            storageState = .localFile(fileName: legacyFileName)
        } else {
            storageState = .undownloaded
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(sourceURLString, forKey: .sourceURLString)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encode(dateSaved, forKey: .dateSaved)
        try container.encodeIfPresent(archivedAt, forKey: .archivedAt)
        try container.encodeIfPresent(kind, forKey: .kind)
        try container.encode(storageState, forKey: .storageState)
        try container.encodeIfPresent(thumbnailFileName, forKey: .thumbnailFileName)
        try container.encodeIfPresent(platform, forKey: .platform)
        try container.encodeIfPresent(platformItemID, forKey: .platformItemID)
        // Continue writing the legacy key for local rows during the rollout.
        try container.encodeIfPresent(fileName, forKey: .fileName)
    }
}

public final class SavedMediaStore {
    public static let shared = SavedMediaStore()

    /// Darwin notification name mutations are echoed on, in addition to the in-process
    /// `.savedMediaChanged` — the only channel that reaches a DIFFERENT process (e.g. the
    /// action/share extension, which downloads media via `LiveMediaDownloadManager` and
    /// writes the shared manifest from its own process; `NotificationCenter.default` posts
    /// never cross the process boundary).
    private static var darwinNotificationName: String {
        "\(AppConfig.appGroupID).savedMediaChanged"
    }

    private static var didRegisterDarwinObserver = false

    /// Registers a cross-process observer that re-posts the in-process `.savedMediaChanged`
    /// on the main queue whenever ANY process (including this one) posts the Darwin
    /// notification. Idempotent — safe to call from every surface that wants the bridge
    /// (e.g. the Downloader grid's `viewDidLoad`). Receiving our own process's echo just
    /// causes one harmless extra reload.
    ///
    /// Darwin's C callback can't capture context, so this uses the classic pattern: a
    /// plain top-level function pointer that only knows how to post the in-process
    /// notification — it doesn't need `self`, since there's nothing instance-specific to
    /// recover (the shared manifest is the same for every SavedMediaStore instance).
    public static func startObservingCrossProcessChanges() {
        guard !didRegisterDarwinObserver else { return }
        didRegisterDarwinObserver = true
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            nil,
            { _, _, _, _, _ in
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .savedMediaChanged, object: nil)
                }
            },
            darwinNotificationName as CFString,
            nil,
            .deliverImmediately)
    }

    private func postCrossProcessChange() {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(Self.darwinNotificationName as CFString),
            nil, nil, true)
    }

    private let lock = NSLock()
    private let fm = FileManager.default
    private let overrideContainerURL: URL?

    /// Consulted before a `.photosReference` row is allowed to answer "already
    /// downloaded" (`existingDownloadedItem`, `ensureUndownloaded`). The real
    /// PhotoKit probe in every process; tests substitute a verdict.
    public var photosBackingProbe: PhotosBackingProbing = PhotoKitBackingProbe()

    /// In-memory cache of the decoded manifest, valid only while `cacheToken` matches the
    /// file's current (modification date, size). Filled by `loadUnlocked()` on a cache miss
    /// and refreshed by `saveUnlocked()` from the array it just wrote — guarded entirely by
    /// `lock`, mirroring `SavesStore`'s stat-token cache.
    private var cachedItems: [SavedMediaItem]?
    private var cacheToken: FileStatToken?

    /// A cheap proxy for "has the manifest changed since we last read it" — the manifest IS
    /// written by other flows (download completion on the URLSession delegate queue, the
    /// share/action extension in its own process), so every read re-stats the file and only
    /// trusts the cache when the stat still matches.
    private struct FileStatToken: Equatable {
        let modificationDate: Date
        let size: Int
    }

    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    public init(containerURL: URL? = nil) {
        self.overrideContainerURL = containerURL
    }

    public var directory: URL {
        let fallback = fm.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? fm.temporaryDirectory
        let base = overrideContainerURL ?? AppConfig.sharedContainerURL(fm) ?? fallback
        let dir = base.appendingPathComponent("SavedMedia", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        BackupPolicy.excludeFromBackups(dir)
        return dir
    }

    public var mediaDirectory: URL {
        let dir = directory.appendingPathComponent("Files", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    public var thumbnailDirectory: URL {
        let dir = directory.appendingPathComponent("Thumbnails", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private var manifestURL: URL {
        directory.appendingPathComponent("savedMedia.json")
    }

    public func items() -> [SavedMediaItem] {
        lock.lock()
        defer { lock.unlock() }
        var items = loadUnlocked()
        if recoverInterruptedTransitionsUnlocked(&items) {
            try? saveUnlocked(items)
        }
        return items.sorted { $0.dateSaved < $1.dateSaved }
    }

    public func item(forURLString urlString: String) -> SavedMediaItem? {
        items().first { $0.sourceURLString == urlString }
    }

    /// Finds the row for `urlString` by exact URL or, failing that, by
    /// platform + durable item id — so a share-link token and its resolved
    /// permalink (or any other differently-shaped URL for the same post) both
    /// resolve to the same row regardless of which URL text it was originally
    /// created under. Used by callers that need the row's stable identity
    /// (e.g. to transition it to a Photos reference) even when the incoming
    /// URL doesn't textually match the one already on file.
    public func matchingItem(forURLString urlString: String) -> SavedMediaItem? {
        let items = items()
        guard let index = Self.matchIndex(in: items, id: nil, sourceURLString: urlString)
        else { return nil }
        return items[index]
    }

    /// The existing item for `urlString` if it's ALREADY downloaded (`.localFile`
    /// or `.photosReference`). Used by callers that must not re-fetch from the
    /// network when a duplicate link comes in.
    ///
    /// A `.photosReference` whose asset the user deleted out of Photos is NOT a
    /// download: it is a dangling identifier that would hand the caller nothing.
    /// Discarding that save here — in the one place every surface asks this
    /// question — is what lets a process with no card deck (an App Intent, a
    /// share/action extension) download again instead of reporting a duplicate,
    /// without waiting for the main app to run its foreground reconcile sweep.
    public func existingDownloadedItem(forURLString urlString: String) -> SavedMediaItem? {
        guard let item = matchingItem(forURLString: urlString) else { return nil }
        switch item.storageState {
        case .localFile:
            return item
        case .photosReference:
            return discardSaveWithDeletedPhotosBacking(item.id) ? nil : item
        case .undownloaded:
            return nil
        }
    }

    /// Finds the row for a save, preferring exact identity (id or URL) but
    /// falling back to platform + durable item id — so a URL that differs only
    /// in shape (a share-link token vs. its resolved permalink, tracking
    /// params, a short link vs. its resolution, …) still dedupes onto the same
    /// row instead of creating a duplicate.
    private static func matchIndex(
        in items: [SavedMediaItem], id: UUID?, sourceURLString: String
    ) -> Int? {
        if let index = items.firstIndex(where: { $0.id == id || $0.sourceURLString == sourceURLString }) {
            return index
        }
        guard let recognized = PlatformRecognizer.recognize(sourceURLString),
              let itemID = recognized.itemID
        else { return nil }
        return items.firstIndex {
            $0.platform == recognized.platform && $0.platformItemID == itemID
        }
    }

    /// Ensures every Downloader save has a durable manifest row before download
    /// begins. Existing local/Photos state wins — unless a Photos reference's
    /// asset is gone, in which case that save is discarded and this call makes a
    /// NEW one, so the caller's start gate
    /// (`LiveMediaDownloadStartPolicy.downloaderShouldStart`) sees work to do
    /// instead of rejecting the save as `.alreadyDownloaded`. Metadata is filled
    /// in without replacing the stable identity supplied by the saved item.
    @discardableResult
    public func ensureUndownloaded(
        id: UUID,
        sourceURLString: String,
        title: String? = nil,
        kind: MediaAsset.Kind? = nil,
        dateSaved: Date = Date()
    ) throws -> SavedMediaItem {
        let recognized = PlatformRecognizer.recognize(sourceURLString)
        if let matched = matchedItem(id: id, sourceURLString: sourceURLString) {
            discardSaveWithDeletedPhotosBacking(matched.id)
        }
        lock.lock()
        var items = loadUnlocked()
        if let index = Self.matchIndex(in: items, id: id, sourceURLString: sourceURLString) {
            if items[index].title == nil { items[index].title = title }
            if items[index].kind == nil { items[index].kind = kind }
            if items[index].platform == nil { items[index].platform = recognized?.platform }
            if items[index].platformItemID == nil { items[index].platformItemID = recognized?.itemID }
            do {
                try saveUnlocked(items)
            } catch {
                lock.unlock()
                throw error
            }
            let result = items[index]
            lock.unlock()
            return result
        }
        let item = SavedMediaItem(
            id: id,
            sourceURLString: sourceURLString,
            title: title,
            dateSaved: dateSaved,
            kind: kind,
            storageState: .undownloaded,
            thumbnailFileName: nil,
            platform: recognized?.platform,
            platformItemID: recognized?.itemID)
        items.append(item)
        do {
            try saveUnlocked(items)
        } catch {
            lock.unlock()
            throw error
        }
        lock.unlock()
        notifyChanged()
        return item
    }

    /// `async` because the video thumbnail's first-frame read is: iOS 18
    /// deprecated the synchronous `copyCGImage` in favour of `image(at:)`.
    /// Every caller was already in an async context.
    @discardableResult
    public func addDownloadedFile(
        _ fileURL: URL,
        kind: MediaAsset.Kind,
        sourceURLString: String,
        title: String?,
        fileExtension ext: String? = nil,
        dateSaved: Date = Date(),
        requiringItemID: UUID? = nil
    ) async throws -> SavedMediaItem {
        let recognized = PlatformRecognizer.recognize(sourceURLString)
        let (existing, protectedItemID, id) = try lock.withLock {
            () -> (SavedMediaItem?, UUID?, UUID) in
            let items = loadUnlocked()
            let existingIndex = Self.matchIndex(
                in: items, id: requiringItemID, sourceURLString: sourceURLString)
            let existing = existingIndex.map { items[$0] }
            guard requiringItemID == nil || existing?.id == requiringItemID else {
                throw SavedMediaStoreMutationError.itemRemoved
            }
            let protectedItemID = requiringItemID ?? existing?.id
            return (existing, protectedItemID, protectedItemID ?? UUID())
        }
        let cleanExt = Self.cleanExtension(ext ?? fileURL.pathExtension, kind: kind)
        // A fresh name keeps an existing durable local backing intact until the
        // replacement manifest has committed successfully.
        let fileName = "\(id.uuidString)-\(UUID().uuidString).\(cleanExt)"
        let destination = mediaDirectory.appendingPathComponent(fileName)
        try? fm.removeItem(at: destination)
        try fm.moveItem(at: fileURL, to: destination)

        let thumbnailName = await makeThumbnail(for: destination, kind: kind, id: id)
        let item = SavedMediaItem(
            id: id,
            sourceURLString: sourceURLString,
            title: title ?? existing?.title,
            dateSaved: dateSaved,
            kind: kind,
            storageState: .localFile(fileName: fileName),
            thumbnailFileName: thumbnailName,
            platform: recognized?.platform ?? existing?.platform,
            platformItemID: recognized?.itemID ?? existing?.platformItemID)
        func removeNewFiles() {
            try? fm.removeItem(at: destination)
            if let thumbnailName {
                try? fm.removeItem(at: thumbnailDirectory.appendingPathComponent(thumbnailName))
            }
        }
        // The commit runs under one `withLock`; a failure inside it rethrows and
        // the file cleanup happens outside, so the lock is never held across it.
        let replaced: [SavedMediaItem]
        let persistedItem: SavedMediaItem
        do {
            (replaced, persistedItem) = try lock.withLock {
                () -> ([SavedMediaItem], SavedMediaItem) in
                var items = loadUnlocked()
                let latestIndex = Self.matchIndex(
                    in: items, id: id, sourceURLString: sourceURLString)
                let latest = latestIndex.map { items[$0] }
                guard protectedItemID == nil || latest?.id == protectedItemID else {
                    throw SavedMediaStoreMutationError.itemRemoved
                }
                // Metadata and archive status may have changed while the file move
                // and thumbnail generation were in flight. Merge from the latest
                // manifest, never from the stale pre-I/O snapshot.
                var merged = item
                merged.title = title ?? latest?.title ?? existing?.title
                merged.platform = recognized?.platform ?? latest?.platform ?? existing?.platform
                merged.platformItemID = recognized?.itemID
                    ?? latest?.platformItemID ?? existing?.platformItemID
                // A row that exists but is NOT archived clears the flag; only
                // the absence of a latest row falls back to the pre-I/O one.
                if let latest {
                    merged.archivedAt = latest.archivedAt
                } else {
                    merged.archivedAt = existing?.archivedAt
                }
                let replaced = items.filter { $0.id == id }
                items.removeAll { $0.id == id }
                items.append(merged)
                try saveUnlocked(items)
                return (replaced, merged)
            }
        } catch {
            removeNewFiles()
            throw error
        }
        for old in replaced where old.id != persistedItem.id || old.fileName != persistedItem.fileName {
            removePendingFiles(fileName: old.fileName,
                               thumbnailFileName: old.thumbnailFileName == persistedItem.thumbnailFileName
                                   ? nil : old.thumbnailFileName)
        }
        notifyChanged()
        return persistedItem
    }

    /// Commits a PhotoKit durable identifier before deleting the app-owned file.
    /// If the process stops between those operations, `items()` resumes cleanup
    /// from the pending names stored in the Photos state.
    @discardableResult
    public func transitionToPhotosReference(
        _ itemID: UUID, localIdentifier: String, kind: MediaAsset.Kind? = nil
    ) throws -> SavedMediaItem? {
        lock.lock()
        var items = loadUnlocked()
        guard let index = items.firstIndex(where: { $0.id == itemID }) else {
            lock.unlock()
            return nil
        }
        let pendingFile = items[index].fileName
        // The small poster is the archive's durable visual identity. Keep it
        // even after the full app-owned media moves into Photos.
        let pendingThumbnail: String? = nil
        if items[index].kind == nil { items[index].kind = kind }
        items[index].storageState = .photosReference(
            localIdentifier: localIdentifier,
            pendingLocalFileName: pendingFile,
            pendingThumbnailFileName: pendingThumbnail)
        do {
            try saveUnlocked(items)
        } catch {
            lock.unlock()
            throw error
        }
        lock.unlock()

        let cleanupFinished = removePendingFiles(
            fileName: pendingFile, thumbnailFileName: pendingThumbnail)

        lock.lock()
        items = loadUnlocked()
        if cleanupFinished,
           let refreshed = items.firstIndex(where: { $0.id == itemID }),
           case .photosReference(let identifier, _, _) = items[refreshed].storageState,
           identifier == localIdentifier {
            items[refreshed].storageState = .photosReference(
                localIdentifier: identifier,
                pendingLocalFileName: nil,
                pendingThumbnailFileName: nil)
            try? saveUnlocked(items)
        }
        let result = items.first(where: { $0.id == itemID })
        lock.unlock()
        notifyChanged()
        return result
    }

    #if DEBUG
    /// Deterministic seeding, the twin of `SavesStore.seedForTesting`.
    /// Replaces the whole manifest with `items`, so a staged (or test) run gets
    /// a media library it fully controls rather than whatever the device had.
    ///
    /// Deliberately does NOT touch `Files/` or `Thumbnails/`: an item that
    /// names a local file expects that file to exist, and the caller is the one
    /// that put it there (`mediaDirectory` is public for exactly this).
    /// DEBUG-only — never compiled into a release build.
    public func seedForTesting(items: [SavedMediaItem]) {
        lock.lock()
        try? saveUnlocked(items)
        lock.unlock()
        NotificationCenter.default.post(name: .savedMediaChanged, object: nil)
    }

    /// Empties the manifest and the media/thumbnail directories. DEBUG-only.
    public func wipeForTesting() {
        lock.lock()
        try? saveUnlocked([])
        lock.unlock()
        for directory in [mediaDirectory, thumbnailDirectory] {
            let contents = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
            for file in contents { try? fm.removeItem(at: file) }
        }
        NotificationCenter.default.post(name: .savedMediaChanged, object: nil)
    }
    #endif

    public func delete(_ item: SavedMediaItem) {
        lock.lock()
        var items = loadUnlocked()
        items.removeAll { $0.id == item.id }
        try? saveUnlocked(items)
        lock.unlock()
        removeLocalFiles(for: item)
        notifyChanged()
    }

    /// Archives/unarchives a saved media row. App-owned full media is removed
    /// immediately on archive while its small thumbnail survives. A PhotoKit
    /// reference is already external storage, so it remains playable in place.
    public func setArchived(_ archived: Bool, for itemID: UUID, at date: Date = Date()) {
        lock.lock()
        var items = loadUnlocked()
        guard let index = items.firstIndex(where: { $0.id == itemID }) else {
            lock.unlock()
            return
        }
        let old = items[index]
        if archived {
            guard items[index].archivedAt == nil else { lock.unlock(); return }
            items[index].archivedAt = date
            if case .localFile = items[index].storageState {
                items[index].storageState = .undownloaded
            }
        } else {
            guard items[index].archivedAt != nil else { lock.unlock(); return }
            items[index].archivedAt = nil
        }
        guard (try? saveUnlocked(items)) != nil else { lock.unlock(); return }
        lock.unlock()
        if archived, case .localFile = old.storageState {
            removePendingFiles(fileName: old.fileName, thumbnailFileName: nil)
        }
        notifyChanged()
    }

    /// Discards a save whose Photos asset the user deleted, so the save arriving
    /// right now starts over: the row is REMOVED and the next
    /// `ensureUndownloaded` creates a fresh one. An ARCHIVED row instead reverts
    /// to `.undownloaded` and keeps its poster — the archive tray's own rule
    /// (`markArchivedPhotosAssetMissing`). Both are exactly what the card deck's
    /// foreground reconcile does, so the two paths can't drift; the deck's
    /// save deletion is deliberately NOT mirrored, because the save being
    /// processed still owns that row. Returns whether a stale save was discarded.
    ///
    /// A no-op unless the probe CONFIRMS the asset is gone: without full read
    /// authorization an empty fetch proves nothing (see `PhotosBackingPresence`),
    /// and a row still backed by Photos must stay a Photos row. The probe runs
    /// outside the lock and the state is re-verified after it, so a concurrent
    /// transition (a download completing into a fresh Photos identifier) can't be
    /// clobbered by a verdict about the previous one.
    ///
    /// The legacy URL marker goes too: it is the other "already downloaded" gate
    /// (`AutoDownloadSettings.wasDownloaded`, read by the ingest fallback and the
    /// non-Downloader start path), and a discarded save must not keep suppressing
    /// its own replacement.
    @discardableResult
    func discardSaveWithDeletedPhotosBacking(_ itemID: UUID) -> Bool {
        lock.lock()
        let items = loadUnlocked()
        guard let index = items.firstIndex(where: { $0.id == itemID }),
              case .photosReference(let identifier, _, _) = items[index].storageState
        else {
            lock.unlock()
            return false
        }
        let sourceURLString = items[index].sourceURLString
        lock.unlock()

        guard photosBackingProbe.presence(ofAssetWithLocalIdentifier: identifier) == .deleted
        else { return false }

        lock.lock()
        var updated = loadUnlocked()
        guard let index = updated.firstIndex(where: { $0.id == itemID }),
              case .photosReference(let current, _, _) = updated[index].storageState,
              current == identifier
        else {
            lock.unlock()
            return false
        }
        let stale = updated[index]
        if stale.isArchived {
            updated[index].storageState = .undownloaded
        } else {
            updated.remove(at: index)
        }
        guard (try? saveUnlocked(updated)) != nil else {
            lock.unlock()
            return false
        }
        lock.unlock()
        // An archived row keeps its poster — that IS the archive's visual
        // identity, and `items()`'s recovery pass already clears any leftover
        // pending files.
        if !stale.isArchived {
            removeLocalFiles(for: stale)
            // `delete` leaves a Photos-backed row's poster on disk (it clears
            // only the transition's pending names). Nothing can reference it
            // once the row is gone, and unlike a one-off delete this path runs
            // again on every re-save.
            removePendingFiles(fileName: nil, thumbnailFileName: stale.thumbnailFileName)
        }
        AutoDownloadSettings.unmarkDownloaded(sourceURLString)
        notifyChanged()
        return true
    }

    /// The row `ensureUndownloaded`/`addDownloadedFile` would act on, under the
    /// same id-or-URL-or-platform-item matching, without the `items()` recovery
    /// pass. Read-only, so callers can consult a row before mutating it.
    private func matchedItem(id: UUID?, sourceURLString: String) -> SavedMediaItem? {
        lock.lock()
        defer { lock.unlock() }
        let items = loadUnlocked()
        return Self.matchIndex(in: items, id: id, sourceURLString: sourceURLString)
            .map { items[$0] }
    }

    /// A deleted/unavailable Photos asset leaves an archived row downloadable;
    /// its retained thumbnail remains. Active rows keep their legacy delete flow.
    public func markArchivedPhotosAssetMissing(_ itemID: UUID) {
        lock.lock()
        var items = loadUnlocked()
        guard let index = items.firstIndex(where: { $0.id == itemID }),
              items[index].isArchived,
              case .photosReference = items[index].storageState
        else { lock.unlock(); return }
        items[index].storageState = .undownloaded
        guard (try? saveUnlocked(items)) != nil else { lock.unlock(); return }
        lock.unlock()
        notifyChanged()
    }

    /// Applies the age-based retention policy. Saved media is app-owned: it is the
    /// Downloader grid's primary content, deleted explicitly from the grid (`delete`)
    /// or aged out here — NOT tied to saves membership. (An earlier version
    /// also purged any item whose `sourceURLString` wasn't in the saves list; that
    /// silently deleted freshly-saved media whenever the app's ingest unwrapped/
    /// normalized a URL, since the stored copy keeps the pre-unwrap source URL.)
    public func purgeExpired(now: Date = Date()) {
        lock.lock()
        let items = loadUnlocked()
        let ageExpired: [SavedMediaItem]
        if let days = MediaRetentionSettings.retentionDays {
            let cutoff = now.addingTimeInterval(-TimeInterval(days) * 24 * 60 * 60)
            ageExpired = items.filter { item in
                guard item.dateSaved < cutoff else { return false }
                if case .localFile = item.storageState { return true }
                return false
            }
        } else {
            ageExpired = []
        }
        guard !ageExpired.isEmpty else {
            lock.unlock()
            return
        }
        let expiredIDs = Set(ageExpired.map(\.id))
        var updated = items
        for index in updated.indices where expiredIDs.contains(updated[index].id) {
            updated[index].storageState = .undownloaded
            if !updated[index].isArchived { updated[index].thumbnailFileName = nil }
        }
        do {
            try saveUnlocked(updated)
        } catch {
            lock.unlock()
            return
        }
        lock.unlock()
        for item in ageExpired {
            if item.isArchived {
                removePendingFiles(fileName: item.fileName, thumbnailFileName: nil)
            } else {
                removeLocalFiles(for: item)
            }
        }
        notifyChanged()
    }

    /// nil when the manifest doesn't exist (or its attributes can't be read) — such a
    /// token never matches a previously cached one, so the next read decodes fresh.
    private func currentFileStatTokenUnlocked() -> FileStatToken? {
        guard let attributes = try? fm.attributesOfItem(atPath: manifestURL.path),
              let modificationDate = attributes[.modificationDate] as? Date,
              let size = attributes[.size] as? Int
        else { return nil }
        return FileStatToken(modificationDate: modificationDate, size: size)
    }

    private func loadUnlocked() -> [SavedMediaItem] {
        let token = currentFileStatTokenUnlocked()
        if let cachedItems, token != nil, token == cacheToken {
            return cachedItems
        }
        guard let data = try? Data(contentsOf: manifestURL),
              let items = try? decoder.decode([SavedMediaItem].self, from: data)
        else {
            cachedItems = []
            cacheToken = token
            return []
        }
        cachedItems = items
        cacheToken = token
        return items
    }

    private func saveUnlocked(_ items: [SavedMediaItem]) throws {
        let data = try encoder.encode(items)
        try data.write(to: manifestURL, options: [.atomic])
        cachedItems = items
        cacheToken = currentFileStatTokenUnlocked()
    }

    /// Repairs interrupted Photos cleanup and local rows whose backing file was
    /// externally removed. Returns whether the manifest needs a follow-up write.
    private func recoverInterruptedTransitionsUnlocked(_ items: inout [SavedMediaItem]) -> Bool {
        var changed = false
        for index in items.indices {
            switch items[index].storageState {
            case .undownloaded:
                break
            case .localFile(let fileName):
                guard !fm.fileExists(atPath: mediaDirectory.appendingPathComponent(fileName).path)
                else { continue }
                if let thumbnail = items[index].thumbnailFileName {
                    try? fm.removeItem(at: thumbnailDirectory.appendingPathComponent(thumbnail))
                }
                items[index].storageState = .undownloaded
                items[index].thumbnailFileName = nil
                changed = true
            case .photosReference(let identifier, let pendingFile, let pendingThumbnail):
                guard pendingFile != nil || pendingThumbnail != nil else { continue }
                guard removePendingFiles(
                    fileName: pendingFile, thumbnailFileName: pendingThumbnail)
                else { continue }
                items[index].storageState = .photosReference(
                    localIdentifier: identifier,
                    pendingLocalFileName: nil,
                    pendingThumbnailFileName: nil)
                changed = true
            }
        }
        return changed
    }

    @discardableResult
    private func removePendingFiles(fileName: String?, thumbnailFileName: String?) -> Bool {
        if let fileName {
            try? fm.removeItem(at: mediaDirectory.appendingPathComponent(fileName))
        }
        if let thumbnailFileName {
            try? fm.removeItem(at: thumbnailDirectory.appendingPathComponent(thumbnailFileName))
        }
        let fileGone = fileName.map {
            !fm.fileExists(atPath: mediaDirectory.appendingPathComponent($0).path)
        } ?? true
        let thumbnailGone = thumbnailFileName.map {
            !fm.fileExists(atPath: thumbnailDirectory.appendingPathComponent($0).path)
        } ?? true
        return fileGone && thumbnailGone
    }

    private func removeLocalFiles(for item: SavedMediaItem) {
        switch item.storageState {
        case .localFile(let fileName):
            removePendingFiles(fileName: fileName, thumbnailFileName: item.thumbnailFileName)
        case .photosReference(_, let pendingFile, let pendingThumbnail):
            removePendingFiles(fileName: pendingFile, thumbnailFileName: pendingThumbnail)
        case .undownloaded:
            if let thumbnail = item.thumbnailFileName {
                removePendingFiles(fileName: nil, thumbnailFileName: thumbnail)
            }
        }
    }

    private func notifyChanged() {
        // Store mutations complete on whichever executor performed the download.
        // NotificationCenter invokes selector observers synchronously on that same
        // thread, and Downloader observers immediately update UICollectionView.
        // Preserve synchronous delivery for main-thread UI actions (delete relies
        // on it), but marshal background download notifications onto the main queue.
        let postInProcess = {
            NotificationCenter.default.post(name: .savedMediaChanged, object: nil)
        }
        if Thread.isMainThread {
            postInProcess()
        } else {
            DispatchQueue.main.async(execute: postInProcess)
        }
        postCrossProcessChange()
    }

    private func makeThumbnail(for fileURL: URL, kind: MediaAsset.Kind, id: UUID) async -> String? {
        let name = "\(id.uuidString).jpg"
        let destination = thumbnailDirectory.appendingPathComponent(name)
        let image: UIImage?
        switch kind {
        case .video, .audio:
            let asset = AVURLAsset(url: fileURL)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            image = kind == .video
                ? (try? await generator.image(at: .zero).image).map(UIImage.init(cgImage:))
                : nil
        case .gif, .image:
            guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil),
                  let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 600,
                  ] as CFDictionary)
            else { image = nil; break }
            image = UIImage(cgImage: cgImage)
        }
        guard let data = image?.jpegData(compressionQuality: 0.82) else { return nil }
        try? data.write(to: destination, options: [.atomic])
        return name
    }

    private static func cleanExtension(_ ext: String, kind: MediaAsset.Kind) -> String {
        let cleaned = ext.lowercased().filter { $0.isLetter || $0.isNumber }
        if !cleaned.isEmpty { return String(cleaned.prefix(8)) }
        switch kind {
        case .video: return "mp4"
        case .audio: return "m4a"
        case .gif: return "gif"
        case .image: return "jpg"
        }
    }
}

/// The supported ages for automatically removing locally downloaded media.
///
/// `.never` is not offered as a user choice — it is what retention reads as while
/// the user stores downloads in Photos instead (see `MediaStorageOption`).
public enum MediaRetentionOption: Int, CaseIterable, Sendable {
    case never = 0
    case oneDay = 1
    case threeDays = 3
    case twoWeeks = 14
    case oneMonth = 30

    public var days: Int? {
        self == .never ? nil : rawValue
    }

    /// The deletion ages the Storage picker offers, in display order.
    public static var deletionOptions: [MediaRetentionOption] {
        allCases.filter { $0 != .never }
    }

    /// The age alone ("1 day"), composed into a full row title by
    /// `MediaStorageOption.displayName`.
    public var displayName: String {
        switch self {
        case .never: return L10n.string("Common_never")
        case .oneDay: return L10n.string("Downloader_media_retention_oneDay")
        case .threeDays: return L10n.string("Downloader_media_retention_threeDays")
        case .twoWeeks: return L10n.string("Downloader_media_retention_twoWeeks")
        case .oneMonth: return L10n.string("Downloader_media_retention_oneMonth")
        }
    }

    /// Maps a free-form (or since-removed) day count to the closest supported
    /// choice, so an existing installation keeps roughly its previous retention.
    public static func closest(to days: Int) -> MediaRetentionOption {
        allCases.min {
            abs($0.rawValue - days) < abs($1.rawValue - days)
        } ?? .never
    }
}

public enum MediaRetentionSettings {
    private static var defaults: UserDefaults {
        UserDefaults(suiteName: AppConfig.appGroupID) ?? .standard
    }
    private static let disabledKey = "savedMediaRetention.disabled"
    private static let daysKey = "savedMediaRetention.days"

    /// The single retention choice shown by Downloader Settings.
    ///
    /// An absent setting now means `.never`. The old disabled flag is still
    /// understood so existing installations keep their previous choice.
    public static var option: MediaRetentionOption {
        get {
            if defaults.bool(forKey: disabledKey) { return .never }
            guard let stored = defaults.object(forKey: daysKey) as? Int else {
                return .never
            }
            return MediaRetentionOption(rawValue: stored)
                ?? MediaRetentionOption.closest(to: stored)
        }
        set {
            if newValue == .never {
                defaults.set(true, forKey: disabledKey)
                defaults.removeObject(forKey: daysKey)
            } else {
                defaults.set(false, forKey: disabledKey)
                defaults.set(newValue.rawValue, forKey: daysKey)
            }
        }
    }

    /// Day-based compatibility API used by the purge path and older callers.
    public static var retentionDays: Int? {
        get { option.days }
        set { option = newValue.map(MediaRetentionOption.closest) ?? .never }
    }
}

public extension Notification.Name {
    static let savedMediaChanged = Notification.Name("LunaSavedMediaChanged")
}
