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

public final class SavedMediaStore {
    public static let shared = SavedMediaStore()

    /// Darwin notification name mutations are echoed on, in addition to the in-process
    /// `.savedMediaChanged` — the only channel that reaches a DIFFERENT process (e.g. the
    /// action/share extension, which downloads media via `LiveMediaDownloadManager` and
    /// writes the shared media rows from its own process; `NotificationCenter.default`
    /// posts never cross the process boundary).
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
    /// recover (the shared library is the same for every SavedMediaStore instance).
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
    /// Guards the lazy resolution of `ownershipStore` only.
    private let ownershipLock = NSLock()
    private var resolvedOwnershipStore: SavesStore?

    /// Consulted before a `.photosReference` row is allowed to answer "already
    /// downloaded" (`existingDownloadedItem`, `ensureUndownloaded`). The real
    /// PhotoKit probe in every process; tests substitute a verdict.
    public var photosBackingProbe: PhotosBackingProbing = PhotoKitBackingProbe()

    public init(containerURL: URL? = nil) {
        self.overrideContainerURL = containerURL
    }

    /// The store that counts who holds this library's files. Resolved lazily, and
    /// to the shared store whenever this store is the shared one, so the process
    /// ends up with one connection to the database rather than two.
    private func ownershipStore() -> SavesStore {
        guard let overrideContainerURL else { return .shared }
        ownershipLock.lock()
        defer { ownershipLock.unlock() }
        if let resolvedOwnershipStore { return resolvedOwnershipStore }
        let store = SavesStore(containerURL: overrideContainerURL)
        resolvedOwnershipStore = store
        return store
    }

    /// Empties the library once, on the first run of the build that moved file
    /// ownership into the database.
    ///
    /// Nothing adopts what an older build left behind: its library was a JSON
    /// manifest this build no longer reads, and its posters are named from their
    /// item id, which the ownership tables cannot take (see
    /// `OwnedFileKind.mediaThumbnail`). Rather than leave files no owner will ever
    /// free, the retired manifest and both directories go. Idempotent and
    /// cross-process — the flag lives in the shared App Group defaults, so
    /// whichever process runs first does the work.
    public func resetLibraryForSQLOwnershipOnce() {
        let defaults = UserDefaults(suiteName: AppConfig.appGroupID) ?? .standard
        let key = "savedMedia.sqlOwnershipReset.v1"
        guard !defaults.bool(forKey: key) else { return }
        lock.lock()
        do {
            try saveUnlocked([])
        } catch {
            lock.unlock()
            return
        }
        lock.unlock()
        try? fm.removeItem(at: directory.appendingPathComponent("savedMedia.json"))
        for directory in [mediaDirectory, thumbnailDirectory] {
            let contents = (try? fm.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil)) ?? []
            for file in contents { try? fm.removeItem(at: file) }
        }
        defaults.set(true, forKey: key)
        notifyChanged()
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

    /// The whole library, oldest save first. The table has no insertion order of
    /// its own — every deck sorts by the save's dates anyway — so this fixes one.
    public func items() -> [SavedMediaItem] {
        lock.lock()
        defer { lock.unlock() }
        var items = loadUnlocked()
        if recoverInterruptedTransitionsUnlocked(&items) {
            if let repaired = try? mutateUnlocked({ current in
                _ = recoverInterruptedTransitionsUnlocked(&current)
                return current
            }) {
                items = repaired
            }
        }
        return items.sorted { $0.dateSaved < $1.dateSaved }
    }

    public func item(forURLString urlString: String) -> SavedMediaItem? {
        ownershipStore().mediaItem(forURLString: urlString)
    }

    /// Finds media by its owning save — the stable join used by the card deck.
    public func item(withID itemID: UUID) -> SavedMediaItem? {
        ownershipStore().mediaItem(saveID: itemID)
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

    /// Ensures every Downloader save has a durable media row before download
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
        do {
            let result = try mutateUnlocked { items -> (item: SavedMediaItem, added: Bool) in
                if let index = Self.matchIndex(
                    in: items, id: id, sourceURLString: sourceURLString
                ) {
                    if items[index].title == nil { items[index].title = title }
                    if items[index].kind == nil { items[index].kind = kind }
                    if items[index].platform == nil { items[index].platform = recognized?.platform }
                    if items[index].platformItemID == nil {
                        items[index].platformItemID = recognized?.itemID
                    }
                    return (items[index], false)
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
                return (item, true)
            }
            lock.unlock()
            if result.added { notifyChanged() }
            return result.item
        } catch {
            lock.unlock()
            throw error
        }
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
            // A brand-new row takes the id of the save that will own its files.
            // Minting a bare UUID here would produce a row whose downloads no
            // `file_refs` edge could ever point at.
            return (existing, protectedItemID, protectedItemID
                ?? MediaSaveBacking.saveID(
                    for: sourceURLString, title: title, dateSaved: dateSaved,
                    store: ownershipStore()))
        }
        let cleanExt = Self.cleanExtension(ext ?? fileURL.pathExtension, kind: kind)
        // A fresh name keeps an existing durable local backing intact until the
        // replacement row has committed successfully.
        let fileName = "\(id.uuidString)-\(UUID().uuidString).\(cleanExt)"
        let destination = mediaDirectory.appendingPathComponent(fileName)
        try? fm.removeItem(at: destination)
        try fm.moveItem(at: fileURL, to: destination)

        let thumbnailName = await makeThumbnail(for: destination, kind: kind)
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
        // Claim the new files BEFORE the row commit, alongside whatever the
        // row already holds. A process killed between the move and the commit then
        // leaves files the database owns rather than files nobody does, and the
        // reconcile that follows either commit or failure frees the losing set.
        do {
            try ownershipStore().claimMediaFiles(
                saveID: id, fileName: fileName, thumbnailFileName: thumbnailName)
        } catch {
            try? fm.removeItem(at: destination)
            if let thumbnailName {
                try? fm.removeItem(at: thumbnailDirectory.appendingPathComponent(thumbnailName))
            }
            throw error
        }
        // The commit runs under one `withLock`; a failure inside it rethrows and
        // the file cleanup happens outside, so the lock is never held across it.
        let persistedItem: SavedMediaItem
        do {
            persistedItem = try lock.withLock { () -> SavedMediaItem in
                try mutateUnlocked { items in
                    let latestIndex = Self.matchIndex(
                        in: items, id: id, sourceURLString: sourceURLString)
                    let latest = latestIndex.map { items[$0] }
                    guard protectedItemID == nil || latest?.id == protectedItemID else {
                        throw SavedMediaStoreMutationError.itemRemoved
                    }
                    // Metadata and archive status may have changed while the file move
                    // and thumbnail generation were in flight. Merge from the latest
                    // row, never from the stale pre-I/O snapshot.
                    var merged = item
                    merged.title = title ?? latest?.title ?? existing?.title
                    merged.platform = recognized?.platform
                        ?? latest?.platform ?? existing?.platform
                    merged.platformItemID = recognized?.itemID
                        ?? latest?.platformItemID ?? existing?.platformItemID
                    // A row that exists but is NOT archived clears the flag; only
                    // the absence of a latest row falls back to the pre-I/O one.
                    if let latest {
                        merged.archivedAt = latest.archivedAt
                    } else {
                        merged.archivedAt = existing?.archivedAt
                    }
                    items.removeAll { $0.id == id }
                    items.append(merged)
                    return merged
                }
            }
        } catch {
            // The row still names whatever it named before, so reconciling to
            // the row as it stands drops the files this call just claimed.
            try? reconcileOwnership(of: existing ?? SavedMediaItem(
                id: id, sourceURLString: sourceURLString, title: nil, dateSaved: dateSaved,
                kind: kind, storageState: .undownloaded, thumbnailFileName: nil))
            throw error
        }
        notifyChanged()
        return persistedItem
    }

    /// Commits a PhotoKit durable identifier before releasing the app-owned file
    /// through SQL's durable delete queue.
    @discardableResult
    public func transitionToPhotosReference(
        _ itemID: UUID, localIdentifier: String, kind: MediaAsset.Kind? = nil
    ) throws -> SavedMediaItem? {
        lock.lock()
        do {
            let result = try mutateUnlocked { items -> SavedMediaItem? in
                guard let index = items.firstIndex(where: { $0.id == itemID }) else {
                    return nil
                }
                if items[index].kind == nil { items[index].kind = kind }
                items[index].storageState = .photosReference(localIdentifier: localIdentifier)
                return items[index]
            }
            lock.unlock()
            guard let result else { return nil }
            notifyChanged()
            return result
        } catch {
            lock.unlock()
            throw error
        }
    }

    #if DEBUG
    /// Deterministic seeding, the twin of `SavesStore.seedForTesting`.
    /// Replaces every media row, so a staged (or test) run gets a media library
    /// it fully controls rather than whatever the device had.
    ///
    /// Each item's id must be a SEEDED SAVE's id: the row is keyed by its save, so
    /// one that names no save is not written at all. Seed the saves first.
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

    /// Empties the media table and the media/thumbnail directories. DEBUG-only.
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
        let deleted = (try? mutateUnlocked { items -> Bool in
            let oldCount = items.count
            items.removeAll { $0.id == item.id }
            return items.count != oldCount
        }) ?? false
        lock.unlock()
        guard deleted else { return }
        notifyChanged()
    }

    /// Archives/unarchives a saved media row. App-owned full media is removed
    /// immediately on archive while its small thumbnail survives. A PhotoKit
    /// reference is already external storage, so it remains playable in place.
    public func setArchived(_ archived: Bool, for itemID: UUID, at date: Date = Date()) {
        lock.lock()
        let result = try? mutateUnlocked { items -> (old: SavedMediaItem, new: SavedMediaItem)? in
            guard let index = items.firstIndex(where: { $0.id == itemID }) else { return nil }
            let old = items[index]
            if archived {
                guard items[index].archivedAt == nil else { return nil }
                items[index].archivedAt = date
                if case .localFile = items[index].storageState {
                    items[index].storageState = .undownloaded
                }
            } else {
                guard items[index].archivedAt != nil else { return nil }
                items[index].archivedAt = nil
            }
            return (old, items[index])
        }
        lock.unlock()
        guard let result else { return }
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
              case .photosReference(let identifier) = items[index].storageState
        else {
            lock.unlock()
            return false
        }
        let sourceURLString = items[index].sourceURLString
        lock.unlock()

        guard photosBackingProbe.presence(ofAssetWithLocalIdentifier: identifier) == .deleted
        else { return false }

        lock.lock()
        let mutation = try? mutateUnlocked {
            updated -> (stale: SavedMediaItem, replacement: SavedMediaItem?)? in
            guard let index = updated.firstIndex(where: { $0.id == itemID }),
                  case .photosReference(let current) = updated[index].storageState,
                  current == identifier
            else { return nil }
            let stale = updated[index]
            if stale.isArchived {
                updated[index].storageState = .undownloaded
                return (stale, updated[index])
            }
            updated.remove(at: index)
            return (stale, nil)
        }
        lock.unlock()
        guard let mutation else { return false }
        // An archived row keeps its poster — that IS the archive's visual
        // identity, and `items()`'s recovery pass already clears any leftover
        // pending files.
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
        let changed = (try? mutateUnlocked { items -> Bool in
            guard let index = items.firstIndex(where: { $0.id == itemID }),
                  items[index].isArchived,
                  case .photosReference = items[index].storageState
            else { return false }
            items[index].storageState = .undownloaded
            return true
        }) ?? false
        lock.unlock()
        guard changed else { return }
        notifyChanged()
    }

    /// Applies the age-based retention policy. Saved media is app-owned: it is the
    /// Downloader grid's primary content, deleted explicitly from the grid (`delete`)
    /// or aged out here — NOT tied to saves membership. Do NOT also purge any item
    /// whose `sourceURLString` isn't in the saves list: the stored copy keeps the
    /// pre-unwrap source URL, so that check would silently delete freshly-saved
    /// media whenever the app's ingest unwraps or normalizes a URL.
    public func purgeExpired(now: Date = Date()) {
        lock.lock()
        let updatedRows = try? mutateUnlocked { items -> [SavedMediaItem] in
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
            guard !ageExpired.isEmpty else { return [] }
            let expiredIDs = Set(ageExpired.map(\.id))
            for index in items.indices where expiredIDs.contains(items[index].id) {
                items[index].storageState = .undownloaded
                if !items[index].isArchived { items[index].thumbnailFileName = nil }
            }
            return items.filter { expiredIDs.contains($0.id) }
        }
        lock.unlock()
        guard let updatedRows, !updatedRows.isEmpty else { return }
        notifyChanged()
    }

    /// The library, read from the `media_saves` table.
    ///
    /// No decode cache in front of it: the table is indexed, one connection per
    /// process serialises it, and a stat-token cache existed only because the
    /// alternative was re-decoding a whole JSON array.
    private func loadUnlocked() -> [SavedMediaItem] {
        ownershipStore().mediaItems()
    }

    /// Writes the library back. One transaction, so another process sees the whole
    /// edit or none of it.
    private func saveUnlocked(_ items: [SavedMediaItem]) throws {
        try ownershipStore().replaceMediaItems(items)
    }

    /// Runs an ordinary library edit under the database's cross-process write
    /// lock. Call while holding this instance's `lock`; the database transaction
    /// is what serialises this edit against every other process.
    private func mutateUnlocked<Result>(
        _ body: (inout [SavedMediaItem]) throws -> Result
    ) throws -> Result {
        try ownershipStore().mutateMediaItems(body)
    }

    /// Repairs local rows whose backing file was removed from under them.
    /// Returns whether the table needs a follow-up write.
    ///
    /// The interrupted-Photos-cleanup half of this is gone: a row that stops
    /// naming its file leaves the unlink to the delete queue, so there is no
    /// half-finished state left to find.
    private func recoverInterruptedTransitionsUnlocked(_ items: inout [SavedMediaItem]) -> Bool {
        var changed = false
        for index in items.indices {
            guard case .localFile(let fileName) = items[index].storageState,
                  !fm.fileExists(atPath: mediaDirectory.appendingPathComponent(fileName).path)
            else { continue }
            items[index].storageState = .undownloaded
            items[index].thumbnailFileName = nil
            changed = true
        }
        return changed
    }

    /// Cleans up a download's provisional file claim after its row commit fails.
    /// Successful row edits reconcile ownership inside that same SQL transaction.
    private func reconcileOwnership(of item: SavedMediaItem) throws {
        try ownershipStore().reconcileMediaFiles(
            saveID: item.id,
            fileName: item.fileName,
            thumbnailFileName: item.thumbnailFileName)
    }

    private func notifyChanged() {
        // Store mutations complete on whichever executor performed the download.
        // NotificationCenter invokes selector observers synchronously on that same
        // thread, and Downloader observers immediately update UICollectionView.
        // Preserve synchronous delivery for main-thread UI actions (delete relies
        // on it), but marshal background download notifications onto the main queue.
        let postInProcess = {
            NotificationCenter.default.post(name: .savedMediaChanged, object: self)
        }
        if Thread.isMainThread {
            postInProcess()
        } else {
            DispatchQueue.main.async(execute: postInProcess)
        }
        postCrossProcessChange()
    }

    private func makeThumbnail(for fileURL: URL, kind: MediaAsset.Kind) async -> String? {
        // Generated, not named from the item: a released path is retired forever,
        // so a name reused across downloads could never be written a second time.
        let name = "thumb-\(UUID().uuidString).jpg"
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
