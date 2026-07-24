//
//  ReadingListStore.swift
//  Luna
//

import LunaAppConfig
import LunaModels
import Foundation

public extension Notification.Name {
    /// Posted whenever the reading list changes (add/update/delete).
    static let readingListChanged = Notification.Name("readingListChanged")
}

/// Persists the reading list as JSON in the shared App Group container so both
/// the app and the SaveLink intent (which may run while the app is backgrounded)
/// see the same data. `items()` serves a validated in-memory cache instead of
/// decoding the file on every call (see `cachedItems`/`cacheToken` below); every
/// mutation refreshes the cache from the array it just wrote (or read, if the
/// write was skipped as a no-op), so this process never has to re-read its own
/// writes.
public final class ReadingListStore {
    public static let shared = ReadingListStore()

    public static let appGroupID = AppConfig.appGroupID

    private let fileManager = FileManager.default
    private let overrideContainerURL: URL?

    /// Serializes read-modify-write mutations WITHIN this process. Also guards
    /// `cachedItems`/`cacheToken` — cache reads/writes never happen outside this lock.
    private let mutationLock = NSLock()
    /// Off-main home for fire-and-forget position writes (`asyncUpdate` below) —
    /// a serial queue so those writes still apply in submission order relative to
    /// each other. `mutationLock` still serializes the actual read-modify-write
    /// against synchronous callers on other threads; this queue only decides
    /// which thread performs it.
    private let asyncUpdateQueue = DispatchQueue(label: "com.hsanabria.luna.readingListStore.asyncUpdate")
    /// Serializes read-modify-write mutations ACROSS processes (app, SaveLink
    /// intent, share/action extensions all write `readingList.json`): without it,
    /// two processes that load → modify → save concurrently silently lose one
    /// side's update. Every mutation runs its read+modify+write inside one writing
    /// coordination via `coordinatedMutate`/`coordinatedUpdate`.
    private let fileCoordinator = NSFileCoordinator()

    /// Refcount for downloaded article images (shared `Articles/img-<hash>` files):
    /// a saved item owns the images its content references, so deleting the item frees
    /// them — unless another save or preloaded page still references the same image.
    private let imageReferences: ImageReferenceStore
    private let preloads: PreloadStore

    /// In-memory cache of the decoded list, valid only while `cacheToken` matches the
    /// file's current (modification date, size). Filled by `items()` on a cache miss
    /// and refreshed by every mutation from the array it just confirmed on disk —
    /// guarded entirely by `mutationLock`.
    private var cachedItems: [ReadingListItem]?
    private var cacheToken: FileStatToken?

    /// A cheap proxy for "has the file changed since we last read it" — cross-process
    /// writers (the app's other processes: SaveLink intent, share/action extensions)
    /// don't share this in-process cache, so every `items()` call re-stats the file and
    /// only trusts the cache when the stat still matches. A same-mtime, same-size write
    /// from another process within the filesystem's timestamp granularity is the
    /// accepted trade-off — rare, harmless, and covered by that write's own
    /// `.readingListChanged` notification driving a reload through the normal path.
    private struct FileStatToken: Equatable {
        let modificationDate: Date
        let size: Int
    }

    /// The shared store uses the App Group container; tests pass a scratch
    /// directory so they never touch (or wipe) real user data.
    public init(containerURL: URL? = nil, preloadStore: PreloadStore? = nil) {
        self.overrideContainerURL = containerURL
        self.imageReferences = ImageReferenceStore(containerURL: containerURL)
        self.preloads = preloadStore ?? .shared
    }

    private var containerURL: URL {
        if let overrideContainerURL { return overrideContainerURL }
        // The App Group container is provisioned for this app; if it's missing the
        // build is misconfigured and nothing works anyway, so fall back to temp.
        return fileManager.containerURL(forSecurityApplicationGroupIdentifier: Self.appGroupID)
            ?? fileManager.temporaryDirectory
    }

    private var listFileURL: URL {
        let url = containerURL.appendingPathComponent("readingList.json")
        BackupPolicy.includeInBackups(url)
        return url
    }

    public var articlesDirectory: URL {
        let dir = containerURL.appendingPathComponent("Articles", isDirectory: true)
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        BackupPolicy.includeInBackups(dir)
        return dir
    }

    /// Original page artifacts are deliberately separate from parsed article JSON
    /// and downloaded reader images. A `.webarchive` is immutable source material;
    /// the reader must never regenerate it from `ArticleContent`.
    public var originalArchivesDirectory: URL {
        let dir = containerURL.appendingPathComponent("OriginalArchives", isDirectory: true)
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        BackupPolicy.includeInBackups(dir)
        return dir
    }

    // MARK: - List operations

    /// All items in saved order — newest first (new items prepend), reorderable
    /// by the user.
    public func items() -> [ReadingListItem] {
        mutationLock.lock()
        defer { mutationLock.unlock() }
        let token = currentFileStatToken()
        if let cachedItems, token != nil, token == cacheToken {
            return cachedItems
        }
        var result: [ReadingListItem] = []
        var coordError: NSError?
        var ran = false
        fileCoordinator.coordinate(readingItemAt: listFileURL, options: [], error: &coordError) { url in
            ran = true
            result = Self.decodeItems(at: url)
        }
        if !ran { result = Self.decodeItems(at: listFileURL) }
        cachedItems = result
        cacheToken = token
        return result
    }

    /// Reorders the stored list to match `orderedIDs` (items not listed keep
    /// their relative order at the end). Backs manual drag-to-reorder.
    public func setOrder(_ orderedIDs: [UUID]) {
        coordinatedMutate { all in
            let byID = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            var reordered = orderedIDs.compactMap { byID[$0] }
            let placed = Set(orderedIDs)
            reordered.append(contentsOf: all.filter { !placed.contains($0.id) })
            all = reordered
        }
    }

    /// The existing item for a URL, if it's already in the list.
    public func item(forURLString urlString: String) -> ReadingListItem? {
        items().first { $0.urlString == urlString }
    }

    /// A fresh copy of an item by ID (callers' copies go stale across mutations).
    public func item(withID itemID: UUID) -> ReadingListItem? {
        items().first { $0.id == itemID }
    }

    /// Repoints an item at an unwrapped URL (e.g. an `apple.news` / Google News
    /// wrapper resolved to the real publisher article). Returns the refreshed item.
    /// If another item already holds that URL, the wrapper is a duplicate — it's
    /// removed (with its files) and nil is returned so the caller stops ingesting it.
    @discardableResult
    public func updateURL(_ urlString: String, for itemID: UUID) -> ReadingListItem? {
        coordinatedMutate { all in
            guard let index = all.firstIndex(where: { $0.id == itemID }) else { return nil }
            if all.contains(where: { $0.id != itemID && $0.urlString == urlString }) {
                let removed = all.remove(at: index)
                self.removeFiles(for: removed)
                return nil
            }
            all[index].urlString = urlString
            return all[index]
        }
    }

    @discardableResult
    public func add(urlString: String, source: CaptureSource = .manual) -> ReadingListItem {
        coordinatedMutate { all in
            if let existing = all.first(where: { $0.urlString == urlString }) {
                return existing
            }
            var item = ReadingListItem(urlString: urlString)
            item.captureSource = source
            all.insert(item, at: 0) // newest first
            return item
        }
    }

    /// Adds a URL only when it isn't already saved, returning the new item, or nil
    /// when an item with that exact URL already exists. THE single URL-existence
    /// dedup authority for "drop a duplicate incoming item" (the recipient-side
    /// friend-share guard): callers that must NOT re-attribute / re-notify a
    /// duplicate route through here rather than pre-checking `item(forURLString:)`
    /// then calling `add`. (The ingestor's separate tracker-merge guard is an
    /// orthogonal condition — same URL inside a different item's price tracker.)
    public func addIfAbsent(urlString: String, source: CaptureSource = .manual) -> ReadingListItem? {
        coordinatedMutate { all in
            guard !all.contains(where: { $0.urlString == urlString }) else { return nil }
            var item = ReadingListItem(urlString: urlString)
            item.captureSource = source
            all.insert(item, at: 0) // newest first
            return item
        }
    }

    // Mutations are targeted (fetch-fresh, set one field, save) rather than
    // whole-item writes: callers hold stale copies, and overwriting the whole
    // item silently reverts fields written by other screens in the meantime.

    /// Marks a download/extraction failure.
    public func markFailed(_ itemID: UUID) {
        coordinatedUpdate { all in
            guard let index = all.firstIndex(where: { $0.id == itemID }) else { return false }
            all[index].state = .failed
            return true
        }
    }

    /// Persists a reader's resume position on exit.
    /// One coordinated write for everything a reader persists on close — scroll
    /// offset, reading progress (monotonic), spoken word, RSVP word index —
    /// instead of several back-to-back whole-list read-modify-write cycles on the
    /// main thread. nil parameters leave their field untouched; `lastWordIndex`
    /// lets the RSVP reader batch its exit save the same way the scroll reader does.
    /// - Parameter clearScrollOffset: when true, sets `lastScrollOffset` to nil (the
    ///   RSVP reader moves the shared position in word space with no pixels, so the
    ///   stored exact offset no longer corresponds to `lastWordIndex` and must be
    ///   invalidated). Distinct from a nil `scrollOffset`, which leaves it untouched.
    /// - Parameter lastOriginalScrollOffset: the archive reader's own disjoint offset.
    ///
    /// Fire-and-forget (see `asyncUpdate`) — called from reader teardown paths
    /// (often mid pop-transition), and these fields are resume positions consumed
    /// on the NEXT open, not read back immediately after being set.
    public func saveReaderExitPosition(
        scrollOffset: Double? = nil, clearScrollOffset: Bool = false,
        readingProgress: Double? = nil,
        lastSpokenWordIndex: Int? = nil, lastWordIndex: Int? = nil,
        lastOriginalScrollOffset: Double? = nil,
        for itemID: UUID
    ) {
        asyncUpdate { all in
            guard let index = all.firstIndex(where: { $0.id == itemID }) else { return false }
            var changed = false
            if clearScrollOffset {
                if all[index].lastScrollOffset != nil {
                    all[index].lastScrollOffset = nil
                    changed = true
                }
            } else if let scrollOffset, all[index].lastScrollOffset != scrollOffset {
                all[index].lastScrollOffset = scrollOffset
                changed = true
            }
            if let lastOriginalScrollOffset, all[index].lastOriginalScrollOffset != lastOriginalScrollOffset {
                all[index].lastOriginalScrollOffset = lastOriginalScrollOffset
                changed = true
            }
            if let readingProgress {
                let clamped = min(max(readingProgress, 0), 1)
                if clamped > (all[index].readingProgress ?? 0) {
                    all[index].readingProgress = clamped
                    changed = true
                }
            }
            if let lastSpokenWordIndex, all[index].lastSpokenWordIndex != lastSpokenWordIndex {
                all[index].lastSpokenWordIndex = lastSpokenWordIndex
                changed = true
            }
            if let lastWordIndex, all[index].lastWordIndex != lastWordIndex {
                all[index].lastWordIndex = lastWordIndex
                changed = true
            }
            return changed
        }
    }

    /// Fire-and-forget (see `asyncUpdate`) — a resume position consumed on the
    /// NEXT open, not read back immediately after being set.
    public func setLastScrollOffset(_ offset: Double, for itemID: UUID) {
        asyncUpdate { all in
            guard let index = all.firstIndex(where: { $0.id == itemID }),
                  all[index].lastScrollOffset != offset else { return false }
            all[index].lastScrollOffset = offset
            return true
        }
    }

    /// Persists the read-aloud resume position (marks audio as having played).
    /// Fire-and-forget (see `asyncUpdate`) — a resume position consumed on the
    /// NEXT open, not read back immediately after being set.
    public func setLastSpokenWordIndex(_ wordIndex: Int, for itemID: UUID) {
        asyncUpdate { all in
            guard let index = all.firstIndex(where: { $0.id == itemID }),
                  all[index].lastSpokenWordIndex != wordIndex else { return false }
            all[index].lastSpokenWordIndex = wordIndex
            return true
        }
    }

    /// Persists how far through the article the user has gotten (0…1, only
    /// ever increases). Fire-and-forget (see `asyncUpdate`) — a resume position
    /// consumed on the NEXT open, not read back immediately after being set.
    public func setReadingProgress(_ progress: Double, for itemID: UUID) {
        asyncUpdate { all in
            guard let index = all.firstIndex(where: { $0.id == itemID }) else { return false }
            let clamped = min(max(progress, 0), 1)
            guard clamped > (all[index].readingProgress ?? 0) else { return false }
            all[index].readingProgress = clamped
            return true
        }
    }


    public func delete(_ item: ReadingListItem) {
        coordinatedMutate { all in
            if let found = all.first(where: { $0.id == item.id }) { self.removeFiles(for: found) }
            all.removeAll { $0.id == item.id }
        }
    }

    /// Moves an item into or out of its surface's archive tray. Archiving keeps
    /// the saved article/document bytes intact, but releases this root's entire
    /// recursive preload tree so it owns no speculative descendants (depth 0).
    public func setArchived(_ archived: Bool, for itemID: UUID, at date: Date = Date()) {
        let changed = coordinatedMutate { all -> Bool in
            guard let index = all.firstIndex(where: { $0.id == itemID }) else { return false }
            if archived {
                guard all[index].archivedAt == nil || all[index].pendingArchiveAt != nil else {
                    return false
                }
                if all[index].archivedAt == nil { all[index].archivedAt = date }
            } else {
                guard all[index].archivedAt != nil || all[index].pendingArchiveAt != nil else {
                    return false
                }
                all[index].archivedAt = nil
            }
            all[index].pendingArchiveAt = nil
            return true
        }
        if changed, archived {
            preloads.releaseTree(rootID: itemID)
        }
    }

    /// Removes a set of items (and their cached content) in one pass — used to clear
    /// the whole Archive section at once.
    public func deleteItems(ids: Set<UUID>) {
        coordinatedMutate { all in
            for item in all where ids.contains(item.id) { self.removeFiles(for: item) }
            all.removeAll { ids.contains($0.id) }
        }
    }

    /// Remembers which reader the user last used for an article.
    public func setReaderMode(_ mode: ReadingListItem.ReaderMode, for itemID: UUID) {
        coordinatedUpdate { all in
            guard let index = all.firstIndex(where: { $0.id == itemID }),
                  all[index].lastReaderMode != mode else { return false }
            all[index].lastReaderMode = mode
            return true
        }
    }

    /// Updates a destination's delivery status; `.sent` also stamps the
    /// destination's `datesSent` (the once-per-day resend guard).
    public func setSendState(
        _ sendState: ReadingListItem.SendState, for itemID: UUID, destination: String
    ) {
        coordinatedUpdate { all in
            guard let index = all.firstIndex(where: { $0.id == itemID }) else { return false }
            all[index].sendStates[destination] = sendState
            if sendState == .sent {
                all[index].datesSent[destination] = Date()
                all[index].sendFailureCounts[destination] = nil
                all[index].sendNextAttemptDates[destination] = nil
                all[index].sendLastErrors[destination] = nil
                all[index].pendingSendFailureNotices[destination] = nil
            }
            return true
        }
    }

    /// Marks a send as actively queued/in-flight without clearing accumulated
    /// retry metadata. If the app is killed mid-send, the queued state is retried
    /// on a later sweep.
    public func markSendAttemptStarted(for itemID: UUID, destination: String) {
        coordinatedUpdate { all in
            guard let index = all.firstIndex(where: { $0.id == itemID }) else { return false }
            all[index].sendStates[destination] = .queued
            return true
        }
    }

    /// Persists a soft delivery failure and its next backoff window.
    public func scheduleSendRetry(
        for itemID: UUID, destination: String, failureCount: Int,
        nextAttemptDate: Date, errorMessage: String
    ) {
        coordinatedUpdate { all in
            guard let index = all.firstIndex(where: { $0.id == itemID }) else { return false }
            all[index].sendStates[destination] = .queued
            all[index].sendFailureCounts[destination] = failureCount
            all[index].sendNextAttemptDates[destination] = nextAttemptDate
            all[index].sendLastErrors[destination] = errorMessage
            all[index].pendingSendFailureNotices[destination] = nil
            return true
        }
    }

    /// Persists a terminal send failure and records that the UI should surface it
    /// once on the next launch/foreground presentation.
    public func markSendTerminalFailure(
        for itemID: UUID, destination: String, errorMessage: String,
        failureCount: Int? = nil
    ) {
        coordinatedUpdate { all in
            guard let index = all.firstIndex(where: { $0.id == itemID }) else { return false }
            all[index].sendStates[destination] = .failed
            if let failureCount {
                all[index].sendFailureCounts[destination] = failureCount
            }
            all[index].sendNextAttemptDates[destination] = nil
            all[index].sendLastErrors[destination] = errorMessage
            all[index].pendingSendFailureNotices[destination] = true
            return true
        }
    }

    public struct SendFailureNotice: Equatable {
        public let itemID: UUID
        public let destinationID: String
        public let title: String
        public let errorMessage: String
    }

    /// Returns and clears terminal send-failure notices so each hard/give-up error
    /// is shown once, even if it happened during a background wakeup.
    public func consumePendingSendFailureNotices() -> [SendFailureNotice] {
        coordinatedMutate { all in
            var notices: [SendFailureNotice] = []
            for index in all.indices {
                let destinations = all[index].pendingSendFailureNotices
                    .filter { $0.value }
                    .map(\.key)
                    .sorted()
                guard !destinations.isEmpty else { continue }
                for destination in destinations {
                    notices.append(SendFailureNotice(
                        itemID: all[index].id,
                        destinationID: destination,
                        title: all[index].title ?? all[index].urlString,
                        errorMessage: all[index].sendLastErrors[destination] ?? "Unknown error"))
                    all[index].pendingSendFailureNotices[destination] = nil
                }
            }
            return notices
        }
    }

    /// Records a save press on an already-listed URL and returns the previous
    /// press time (the item's save time, if this is the first repeat press) —
    /// the primitive behind double-save-to-send detection.
    @discardableResult
    public func recordSaveAttempt(for itemID: UUID) -> Date? {
        coordinatedMutate { all in
            guard let index = all.firstIndex(where: { $0.id == itemID }) else { return nil }
            let previous = all[index].lastSaveAttemptDate ?? all[index].dateAdded
            all[index].lastSaveAttemptDate = Date()
            return previous
        }
    }

    /// Sets the leading-label source (e.g. the email sender for imported mail,
    /// shown where the host would be).
    public func setChannelName(_ name: String, for itemID: UUID) {
        coordinatedUpdate { all in
            guard let index = all.firstIndex(where: { $0.id == itemID }),
                  all[index].channelName != name else { return false }
            all[index].channelName = name
            return true
        }
    }

    /// Records the stable sender identity for an incoming-email item while
    /// retaining the parsed name as a fallback when no contact exists.
    public func setIncomingSender(email: String, displayName: String, for itemID: UUID) {
        coordinatedUpdate { all in
            guard let index = all.firstIndex(where: { $0.id == itemID }) else { return false }
            let changed = all[index].incomingSenderEmail != email
                || all[index].channelName != displayName
            all[index].incomingSenderEmail = email
            all[index].channelName = displayName
            return changed
        }
    }

    /// Writes downloaded art bytes to the Articles dir and points the item at it.
    public func setThumbnail(_ data: Data, for itemID: UUID) {
        let fileName = "\(itemID.uuidString)-thumb.jpg"
        coordinatedUpdate { all in
            guard let index = all.firstIndex(where: { $0.id == itemID }) else { return false }
            do {
                let url = self.articlesDirectory.appendingPathComponent(fileName)
                try data.write(to: url, options: .atomic)
                BackupPolicy.includeInBackups(url)
            } catch {
                SharedDiagnosticLog.record(
                    "failed to write thumbnail: \(error.localizedDescription)", category: "store")
                return false
            }
            all[index].thumbnailFileName = fileName
            return true
        }
    }

    /// Fills in metadata for a recognized platform item and marks it ready
    /// (platform items have no `ArticleContent`). Best-effort: any field may be
    /// nil and the item still renders (logo + deep link).
    public func savePlatformMetadata(
        platform: ContentPlatform, platformItemID: String?, title: String?,
        creator: String?, thumbnailFileName: String?, for itemID: UUID
    ) -> ReadingListItem? {
        let result = coordinatedMutate { all in
            guard let index = all.firstIndex(where: { $0.id == itemID }) else { return nil }
            all[index].platform = platform
            all[index].platformItemID = platformItemID
            if let title, !title.isEmpty { all[index].title = title }
            if let creator, !creator.isEmpty { all[index].channelName = creator }
            if let thumbnailFileName { all[index].thumbnailFileName = thumbnailFileName }
            all[index].state = .ready
            return all[index]
        }
        // No longer failed: drop the sidecar's failure detail so a LATER failure
        // starts from a clean count and reason.
        if result != nil { SaveFailureStore.shared.clear(itemID) }
        return result
    }

    /// Raises the item's read state; never downgrades (read stays read).
    public func markReadState(_ newState: ReadingListItem.ReadState, for itemID: UUID) {
        coordinatedUpdate { all in
            guard let index = all.firstIndex(where: { $0.id == itemID }) else { return false }
            let order: [ReadingListItem.ReadState] = [.unopened, .opened, .read]
            guard let current = order.firstIndex(of: all[index].readState),
                  let proposed = order.firstIndex(of: newState),
                  proposed > current
            else { return false }
            all[index].readState = newState
            return true
        }
    }

    /// Marks an article finished and queues it for archive at the next app
    /// lifecycle boundary. Keeping `archivedAt` nil preserves the current card
    /// for the remainder of this foreground session.
    ///
    /// Keep the read transition, terminal progress, and durable pending marker
    /// together for end-of-reader paths.
    public func markFinishedReading(_ itemID: UUID) {
        markFinishedReading(itemID, at: Date())
    }

    public func markFinishedReading(_ itemID: UUID, at date: Date) {
        coordinatedUpdate { all in
            guard let index = all.firstIndex(where: { $0.id == itemID }) else { return false }
            var changed = false
            if all[index].readState != .read {
                all[index].readState = .read
                changed = true
            }
            if (all[index].readingProgress ?? 0) < 1 {
                all[index].readingProgress = 1
                changed = true
            }
            if all[index].archivedAt == nil, all[index].pendingArchiveAt == nil {
                all[index].pendingArchiveAt = date
                changed = true
            }
            return changed
        }
    }

    /// Moves every reader-completed item into Archive in one coordinated write.
    /// Called by the Reader app on background and once during cold launch.
    public func archivePendingFinishedItems() {
        let archivedIDs: [UUID] = coordinatedMutate { all in
            var ids: [UUID] = []
            for index in all.indices {
                guard let pending = all[index].pendingArchiveAt else { continue }
                if all[index].archivedAt == nil {
                    all[index].archivedAt = pending
                    ids.append(all[index].id)
                }
                all[index].pendingArchiveAt = nil
            }
            return ids
        }
        for id in archivedIDs { preloads.releaseTree(rootID: id) }
    }

    /// Forces an item back to unread, clears every archive marker, and bumps it
    /// to the front of the active carousel (the Archive-tray "Unarchive"
    /// action). This is a deliberate downgrade that `markReadState`'s
    /// forward-only guard disallows.
    public func markUnread(_ itemID: UUID, at date: Date = Date()) {
        coordinatedUpdate { all in
            guard let index = all.firstIndex(where: { $0.id == itemID }),
                  all[index].readState != .unopened
                    || all[index].archivedAt != nil
                    || all[index].pendingArchiveAt != nil
            else { return false }
            all[index].readState = .unopened
            all[index].archivedAt = nil
            all[index].pendingArchiveAt = nil
            all[index].bumpDate = date
            return true
        }
    }

    // MARK: - Price tracking

    /// Attaches a price-tracker payload to an item and marks it ready (a tracker
    /// has no article content to download). Returns the refreshed item.
    @discardableResult
    public func savePriceTracker(_ tracker: PriceTracker, for itemID: UUID) -> ReadingListItem? {
        let result = coordinatedMutate { all in
            guard let index = all.firstIndex(where: { $0.id == itemID }) else { return nil }
            all[index].priceTracker = tracker
            all[index].title = tracker.productName
            all[index].state = .ready
            return all[index]
        }
        if result != nil { SaveFailureStore.shared.clear(itemID) }
        return result
    }

    /// Attaches a price-tracker payload to the item saved for `urlString` (the
    /// classified product page's row), returning its id — or nil when no row
    /// exists. The shared store write for a product save from ANY surface: the
    /// extension driver's product presenter and the extension reader's
    /// defensive `.product` path both land here, so a product save is shaped
    /// identically everywhere.
    @discardableResult
    public func savePriceTracker(_ tracker: PriceTracker, forURLString urlString: String) -> UUID? {
        guard let saved = item(forURLString: urlString) else { return nil }
        savePriceTracker(tracker, for: saved.id)
        return saved.id
    }

    /// Replaces the price-tracker payload of an existing tracker (add/remove store,
    /// change threshold, archive). Returns the refreshed item.
    @discardableResult
    public func updatePriceTracker(_ tracker: PriceTracker, for itemID: UUID) -> ReadingListItem? {
        coordinatedMutate { all in
            guard let index = all.firstIndex(where: { $0.id == itemID }),
                  all[index].priceTracker != nil else { return nil }
            all[index].priceTracker = tracker
            all[index].title = tracker.productName
            return all[index]
        }
    }

    /// The existing price tracker (and its item id) whose stores already include
    /// `urlString`, if any. Lets a re-save of an already-tracked URL short-circuit
    /// to the existing tracker instead of re-detecting (and re-merging into a
    /// duplicate). Items are scanned in stable id order so the result is
    /// deterministic when (defensively) more than one tracker holds the URL.
    public func priceTracker(containingStoreURL urlString: String) -> (itemID: UUID, tracker: PriceTracker)? {
        let candidates = items()
            .compactMap { item -> (itemID: UUID, tracker: PriceTracker)? in
                guard let tracker = item.priceTracker,
                      tracker.hasStore(urlString: urlString) else { return nil }
                return (item.id, tracker)
            }
            .sorted { $0.itemID.uuidString < $1.itemID.uuidString }
        return candidates.first
    }

    /// All non-archived price trackers, ordered stalest-first (oldest minimum
    /// `lastRefreshed` across their stores) so a killed background refresh makes
    /// progress on the longest-unrefreshed trackers each run.
    public func priceTrackersStalestFirst() -> [ReadingListItem] {
        items()
            .filter { ($0.priceTracker?.isArchived == false) }
            .sorted { lhs, rhs in
                Self.stalestRefresh(lhs.priceTracker) < Self.stalestRefresh(rhs.priceTracker)
            }
    }

    /// The oldest `lastRefreshed` across a tracker's stores (a never-refreshed
    /// store sorts first, as `.distantPast`).
    public static func stalestRefresh(_ tracker: PriceTracker?) -> Date {
        guard let tracker else { return .distantPast }
        return tracker.stores.map { $0.lastRefreshed ?? .distantPast }.min() ?? .distantPast
    }

    // MARK: - Bump / undo

    /// Stamps a new bump date on an item and moves it to the top of the list (the
    /// row's own "Bump to Top" action re-sorts it up in the reading list).
    public func bump(_ itemID: UUID) {
        coordinatedUpdate { all in
            guard let index = all.firstIndex(where: { $0.id == itemID }) else { return false }
            var item = all.remove(at: index)
            item.bumpDate = Date()
            all.insert(item, at: 0)
            return true
        }
    }

    // MARK: - Article content

    public func saveContent(_ content: ArticleContent, for item: ReadingListItem) -> ReadingListItem {
        let fileName = "\(item.id.uuidString).json"
        let saved: ReadingListItem = coordinatedMutate { all in
            guard let index = all.firstIndex(where: { $0.id == item.id }) else { return item }
            // Both encode AND write must succeed before the item flips `.ready` —
            // a ready item whose content file doesn't exist is a blank reader.
            if let data = try? JSONEncoder().encode(content),
               (try? data.write(to: self.articlesDirectory.appendingPathComponent(fileName),
                                options: .atomic)) != nil {
                BackupPolicy.includeInBackups(self.articlesDirectory.appendingPathComponent(fileName))
                all[index].contentFileName = fileName
                all[index].title = content.title
                // This save now owns the images its content references (so they survive
                // until the item is deleted, and aren't deleted while it still needs them).
                self.imageReferences.setReferences(
                    contentKey: ImageReferenceStore.itemKey(item.id),
                    files: ImageReferenceStore.imageFiles(in: content))
                // Real content now exists (possibly after the user solved an archive
                // CAPTCHA), so this is the terminal ready state regardless of how it got here.
                all[index].state = .ready
                all[index].wordCount = content.blocks.reduce(0) {
                    $0 + $1.text.split(whereSeparator: { $0.isWhitespace }).count
                }
            } else {
                all[index].state = .failed
            }
            return all[index]
        }
        // Keep the failure sidecar in step with the state this write landed on.
        if saved.state == .ready {
            SaveFailureStore.shared.clear(item.id)
        } else if saved.state == .failed {
            SaveFailureStore.shared.recordFailure(item.id, reason: .couldNotSave)
        }
        return saved
    }

    /// Marks a hard-paywalled article as needing a user-solved archive CAPTCHA: it
    /// lands in the list (with its real title) in the `.needsCaptcha` state, shown
    /// with a "tap to unlock" affordance. Tapping opens the archive.today snapshot in
    /// a web view; once the user solves the CAPTCHA the article is extracted and
    /// `saveContent` moves it to `.ready`.
    public func markNeedsCaptcha(_ itemID: UUID, title: String?) {
        coordinatedUpdate { all in
            guard let index = all.firstIndex(where: { $0.id == itemID }) else { return false }
            // Never downgrade a readable item (a concurrent app/extension extract,
            // or a reused cf_clearance, may have already filled it in).
            guard all[index].state != .ready else { return false }
            all[index].state = .needsCaptcha
            if let title, !title.isEmpty { all[index].title = title }
            return true
        }
        // A locked-but-titled item is not a failed save; it has its own UX.
        SaveFailureStore.shared.clear(itemID)
    }

    #if DEBUG
    /// Deterministic test/UI-test seeding: replaces the entire reading list with
    /// `items` and writes each provided `ArticleContent` to its item's content file
    /// (keyed by item id). Wipes any existing Articles content files first so the
    /// container is a clean, reproducible fixture. DEBUG-only — never compiled into
    /// a release build, so production code paths can't reach it.
    ///
    /// Used by both the in-app `UITestSeeder` (launch-argument seeding for the
    /// screenshot harness) and unit tests that render real view controllers against
    /// a fixed fixture set.
    public func seedForTesting(items: [ReadingListItem], contents: [UUID: ArticleContent]) {
        let articlesDir = articlesDirectory
        let originalsDir = originalArchivesDirectory
        coordinatedMutate { all in
            // Remove every prior article content/source file so leftover state from
            // an earlier seed can't leak into this one.
            if let existing = try? self.fileManager.contentsOfDirectory(
                at: articlesDir, includingPropertiesForKeys: nil) {
                for file in existing { try? self.fileManager.removeItem(at: file) }
            }
            if let existing = try? self.fileManager.contentsOfDirectory(
                at: originalsDir, includingPropertiesForKeys: nil) {
                for file in existing { try? self.fileManager.removeItem(at: file) }
            }
            var seeded = items
            for index in seeded.indices {
                guard let content = contents[seeded[index].id] else { continue }
                let fileName = "\(seeded[index].id.uuidString).json"
                if let data = try? JSONEncoder().encode(content) {
                    let fileURL = articlesDir.appendingPathComponent(fileName)
                    try? data.write(to: fileURL, options: .atomic)
                    BackupPolicy.includeInBackups(fileURL)
                    seeded[index].contentFileName = fileName
                }
            }
            all = seeded
        }
    }

    /// Empties the reading list and removes all article files. DEBUG-only.
    public func wipeForTesting() {
        let articlesDir = articlesDirectory
        let originalsDir = originalArchivesDirectory
        coordinatedMutate { all in
            if let existing = try? self.fileManager.contentsOfDirectory(
                at: articlesDir, includingPropertiesForKeys: nil) {
                for file in existing { try? self.fileManager.removeItem(at: file) }
            }
            if let existing = try? self.fileManager.contentsOfDirectory(
                at: originalsDir, includingPropertiesForKeys: nil) {
                for file in existing { try? self.fileManager.removeItem(at: file) }
            }
            all = []
        }
    }
    #endif

    public func content(for item: ReadingListItem) -> ArticleContent? {
        guard let fileName = item.contentFileName else { return nil }
        guard let data = try? Data(contentsOf: articlesDirectory.appendingPathComponent(fileName))
        else { return nil }
        return try? JSONDecoder().decode(ArticleContent.self, from: data)
    }

    /// Saves an immutable WebKit web archive. The archive is written before its
    /// file name is committed to the list, so the Original mode can never point at
    /// a half-written artifact.
    public func saveWebArchive(_ data: Data, for item: ReadingListItem) {
        let fileName = "\(item.id.uuidString).webarchive"
        let url = originalArchivesDirectory.appendingPathComponent(fileName)
        do {
            try data.write(to: url, options: .atomic)
            BackupPolicy.includeInBackups(url)
        } catch {
            return
        }
        coordinatedUpdate { all in
            guard let index = all.firstIndex(where: { $0.id == item.id }),
                  all[index].originalArchiveFileName != fileName else { return false }
            all[index].originalArchiveFileName = fileName
            return true
        }
    }

    /// The saved web archive, when one was successfully captured for a web page.
    public func webArchiveURL(for item: ReadingListItem) -> URL? {
        guard let fileName = item.originalArchiveFileName,
              fileName.hasSuffix(".webarchive"),
              fileName == URL(fileURLWithPath: fileName).lastPathComponent
        else { return nil }
        let url = originalArchivesDirectory.appendingPathComponent(fileName)
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    /// An imported document is already its own original artifact. Mail imports have
    /// neither a web archive nor a source file, so they intentionally return nil.
    public func originalDocumentURL(for item: ReadingListItem) -> URL? {
        guard let ext = item.sanitizedDocumentType else { return nil }
        let url = articlesDirectory.appendingPathComponent("\(item.id.uuidString)-source.\(ext)")
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    /// Whether the reader should offer the Original/archive view mode for this save.
    ///
    /// Keyed off the save's *source* (`ReadingListItem.canHaveOriginalArchive`), NOT
    /// off whether the archive file is on disk yet: every web page and imported
    /// document owns an original artifact and gets the mode (a web page whose
    /// `.webarchive` capture is missing gets a styled, offline snapshot of its saved
    /// article content in `OriginalPageViewController`), while email-text imports —
    /// the only saves with no original artifact — never get it.
    public func hasOriginalSource(for item: ReadingListItem) -> Bool {
        item.canHaveOriginalArchive
    }

    // MARK: - Private

    /// One row of the shared list file, decoded failably: a structurally corrupt
    /// row becomes nil instead of failing the whole array (enum version skew is
    /// already absorbed inside `ReadingListItem.init(from:)`).
    private struct FailableItem: Decodable {
        let item: ReadingListItem?
        init(from decoder: Decoder) throws { self.item = try? ReadingListItem(from: decoder) }
    }

    private static func decodeItems(at url: URL) -> [ReadingListItem] {
        decodeList(at: url).items
    }

    /// nil when the file doesn't exist (or its attributes can't be read) — such a
    /// token never matches a previously cached one, so the next read decodes fresh.
    private func currentFileStatToken() -> FileStatToken? {
        guard let attributes = try? fileManager.attributesOfItem(atPath: listFileURL.path),
              let modificationDate = attributes[.modificationDate] as? Date,
              let size = attributes[.size] as? Int
        else { return nil }
        return FileStatToken(modificationDate: modificationDate, size: size)
    }

    /// Decodes the shared file. `safeToRewrite` is false only when a NON-EMPTY
    /// file is entirely unreadable — a mutation must then refuse to write, because
    /// re-encoding the fallback empty array would destroy every saved item.
    private static func decodeList(at url: URL) -> (items: [ReadingListItem], safeToRewrite: Bool) {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return ([], true) }
        guard let rows = try? JSONDecoder().decode([FailableItem].self, from: data) else {
            SharedDiagnosticLog.record(
                "readingList.json unreadable — refusing writes to avoid wiping the list",
                category: "store")
            return ([], false)
        }
        let items = rows.compactMap(\.item)
        if items.count < rows.count {
            SharedDiagnosticLog.record(
                "skipped \(rows.count - items.count) undecodable reading-list row(s)",
                category: "store")
        }
        return (items, true)
    }

    private static func encodeItems(_ items: [ReadingListItem], to url: URL) {
        do {
            let data = try JSONEncoder().encode(items)
            try data.write(to: url, options: .atomic)
            BackupPolicy.includeInBackups(url)
        } catch {
            SharedDiagnosticLog.record(
                "failed to write readingList.json: \(error.localizedDescription)",
                category: "store")
        }
    }

    /// Coordinated read-modify-write of the whole list, returning `body`'s value.
    /// Holds the in-process `mutationLock` AND an `NSFileCoordinator` writing
    /// coordination across the entire read+modify+write so other processes can't
    /// lose this update (or vice versa). Writes + posts `.readingListChanged` only
    /// when `body` actually changed the array (e.g. `add` returning an existing
    /// item, or `savePriceTracker` on a missing id are no-ops) — comparing against
    /// `ReadingListItem: Equatable` — and never when the file is unreadable (see
    /// `decodeList` — never wipe the list).
    @discardableResult
    private func coordinatedMutate<T>(_ body: (inout [ReadingListItem]) -> T) -> T {
        mutationLock.lock()
        defer { mutationLock.unlock() }
        var wrote = false
        func perform(_ url: URL) -> T {
            let (decoded, safeToRewrite) = Self.decodeList(at: url)
            var all = decoded
            let result = body(&all)
            guard safeToRewrite else { return result }
            if all != decoded {
                Self.encodeItems(all, to: url)
                wrote = true
            }
            // Either way, disk truth is now known (the just-written `all`, or the
            // unchanged `decoded` we just read) — refresh the cache from it.
            cachedItems = all
            cacheToken = currentFileStatToken()
            return result
        }
        var coordResult: T?
        var coordError: NSError?
        fileCoordinator.coordinate(writingItemAt: listFileURL, options: [], error: &coordError) { url in
            coordResult = perform(url)
        }
        let result = coordResult ?? perform(listFileURL)
        if wrote { postChanged() }
        return result
    }

    /// Runs `coordinatedUpdate` on `asyncUpdateQueue` instead of the caller's own
    /// thread. Reserved for setters whose callers don't need to observe the
    /// write's completion or read the field back immediately (resume positions,
    /// consumed on the NEXT open) — anything with a return value or a read-back
    /// expectation must stay on synchronous `coordinatedUpdate`/`coordinatedMutate`.
    /// A queued write targeting an item deleted before it runs is already a safe
    /// no-op (`coordinatedUpdate`'s own `firstIndex` guard).
    private func asyncUpdate(_ body: @escaping (inout [ReadingListItem]) -> Bool) {
        asyncUpdateQueue.async { [weak self] in
            self?.coordinatedUpdate(body)
        }
    }

    /// Test seam: blocks until every `asyncUpdate` queued before this call has
    /// finished, so tests that write a position field then immediately assert on
    /// it can do so deterministically instead of racing the background write.
    public func flushPendingUpdates() {
        asyncUpdateQueue.sync {}
    }

    /// Like `coordinatedMutate` but only writes + notifies when `body` reports a
    /// change — preserves the "skip the write if nothing changed" behavior of the
    /// targeted setters (no spurious reloads).
    private func coordinatedUpdate(_ body: (inout [ReadingListItem]) -> Bool) {
        mutationLock.lock()
        defer { mutationLock.unlock() }
        var changed = false
        func perform(_ url: URL) {
            let (decoded, safeToRewrite) = Self.decodeList(at: url)
            var all = decoded
            if body(&all), safeToRewrite {
                Self.encodeItems(all, to: url)
                BackupPolicy.includeInBackups(url)
                changed = true
                cachedItems = all
                cacheToken = currentFileStatToken()
            }
        }
        var coordError: NSError?
        var ran = false
        fileCoordinator.coordinate(writingItemAt: listFileURL, options: [], error: &coordError) { url in
            ran = true
            perform(url)
        }
        if !ran { perform(listFileURL) }
        if changed { postChanged() }
    }

    private func postChanged() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .readingListChanged, object: nil)
        }
    }

    /// Removes an item's on-disk artifacts (content JSON, imported source file,
    /// thumbnail). The source extension is the SANITIZED document type so a crafted
    /// `documentType` can't point the delete outside the Articles directory.
    private func removeFiles(for item: ReadingListItem) {
        if let fileName = item.contentFileName {
            try? fileManager.removeItem(at: articlesDirectory.appendingPathComponent(fileName))
        }
        if let fileName = item.originalArchiveFileName,
           fileName == URL(fileURLWithPath: fileName).lastPathComponent {
            let directory = fileName.hasSuffix(".webarchive") ? originalArchivesDirectory : articlesDirectory
            try? fileManager.removeItem(at: directory.appendingPathComponent(fileName))
        }
        if let ext = item.sanitizedDocumentType {
            try? fileManager.removeItem(at: articlesDirectory
                .appendingPathComponent("\(item.id.uuidString)-source.\(ext)"))
        }
        if let thumb = item.thumbnailFileName {
            try? fileManager.removeItem(at: articlesDirectory.appendingPathComponent(thumb))
        }
        // Release this save's downloaded images (deleted only if no other save/preloaded
        // page still references the same shared `img-<hash>` file).
        imageReferences.removeReferences(contentKey: ImageReferenceStore.itemKey(item.id))
        // Release this save's preload subtree (refcount decrement; only ever deletes
        // files under Preloads/, never a user save).
        preloads.releaseTree(rootID: item.id)
    }
}
