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

/// Persists the reading list in `saves.sqlite` in the shared App Group container
/// so every Luna process — the four apps, their share/action/Safari extensions,
/// the App Intents, the mail-fetch background task — sees the same data.
///
/// SQLite owns cross-process consistency: a mutation is one `BEGIN IMMEDIATE`
/// transaction, so two processes that read-modify-write at the same moment take
/// turns instead of losing one side's update, and a reader always sees a whole
/// committed state. `items()` serves an in-memory list validated against `PRAGMA
/// data_version` — which changes only when ANOTHER connection commits — so a
/// repeated read costs one pragma, and a sibling process's write is picked up on
/// the next call without waiting for a notification.
///
/// Payload FILES (parsed article JSON, web archives, imported documents,
/// thumbnails, downloaded images) stay on disk beside the database, named from
/// the save's id — but WHO OWNS THEM is in the database, as ownership edges
/// written in the same transaction as the row that made them (see
/// `SavedFileOwnership`). Deleting a save is therefore just the row delete: the
/// edges cascade, the schema's triggers queue every file whose last owner is
/// gone, and `PendingDeleteReaper` unlinks it.
public final class ReadingListStore {
    public static let shared = ReadingListStore()

    public static let appGroupID = AppConfig.appGroupID

    private let fileManager = FileManager.default
    private let overrideContainerURL: URL?

    /// Off-main home for fire-and-forget position writes (`asyncUpdate` below) —
    /// a serial queue so those writes still apply in submission order relative to
    /// each other. The database's own serial queue still serializes the actual
    /// read-modify-write against synchronous callers on other threads; this queue
    /// only decides which thread performs it.
    private let asyncUpdateQueue = DispatchQueue(label: "com.hsanabria.luna.readingListStore.asyncUpdate")

    private let preloads: PreloadStore

    /// Guards the lazy open of `openedDatabase` only. Everything the connection
    /// itself touches — including `cachedItems` — is serialized by the database's
    /// own queue.
    private let openLock = NSLock()
    private var openedDatabase: SavesDatabase?
    private var loggedOpenFailure = false

    /// The whole list as last read, valid while `cachedDataVersion` still matches
    /// the file's. Only ever read or written from inside a database transaction.
    private var cachedItems: [ReadingListItem]?
    private var cachedDataVersion: Int64?

    /// The shared store uses the App Group container; tests pass a scratch
    /// directory so they never touch (or wipe) real user data.
    public init(containerURL: URL? = nil, preloadStore: PreloadStore? = nil) {
        self.overrideContainerURL = containerURL
        self.preloads = preloadStore ?? .shared
    }

    private var containerURL: URL {
        if let overrideContainerURL { return overrideContainerURL }
        // The App Group container is provisioned for this app; if it's missing the
        // build is misconfigured and nothing works anyway, so fall back to temp.
        return AppConfig.sharedContainerURL(fileManager) ?? fileManager.temporaryDirectory
    }

    /// The database file. Its `-wal`/`-shm` siblings sit beside it.
    var databaseFileURL: URL {
        containerURL.appendingPathComponent("saves.sqlite")
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

    // MARK: - The connection

    /// This process's connection, opened on first use. A failure to open leaves
    /// every read empty and every mutation a no-op — the same floor an unreadable
    /// file had — and is logged once.
    private func database() -> SavesDatabase? {
        openLock.lock()
        defer { openLock.unlock() }
        // Compared by path, not just held: staged mode repoints the whole
        // container (`StageContainer`), and a connection to where the container
        // used to be would keep writing there.
        if let openedDatabase, openedDatabase.fileURL == databaseFileURL {
            return openedDatabase
        }
        do {
            let database = try SavesDatabase(fileURL: databaseFileURL)
            BackupPolicy.includeInBackups(database.fileURL)
            openedDatabase = database
            return database
        } catch {
            if !loggedOpenFailure {
                loggedOpenFailure = true
                SharedDiagnosticLog.record(
                    "saves database unavailable: \(error)", category: "store")
            }
            return nil
        }
    }

    /// Logs an unexpected SQL failure. Every caller then behaves as if the
    /// mutation had been a no-op, which is what a failed write is.
    private func record(_ error: Error, _ operation: String) {
        SharedDiagnosticLog.record("saves \(operation) failed: \(error)", category: "store")
    }

    // MARK: - List operations

    /// All items in saved order — newest first (new items prepend), reorderable
    /// by the user.
    public func items() -> [ReadingListItem] {
        guard let database = database() else { return [] }
        do {
            return try database.perform { db in
                try db.readTransaction {
                    let version = db.dataVersion
                    if let cachedItems, version == cachedDataVersion { return cachedItems }
                    let items = try SavesReader.allItems(in: db)
                    cachedItems = items
                    cachedDataVersion = version
                    return items
                }
            }
        } catch {
            record(error, "read")
            return []
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
        // The duplicate's row goes inside the transaction, which releases its
        // files; the unlink and its preload subtree follow the commit.
        var removedDuplicate = false
        let result: ReadingListItem? = write { db -> ReadingListItem? in
            guard var stored = try SavesReader.item(id: itemID, in: db) else { return nil }
            if try SavesReader.urlIsTaken(urlString, excluding: itemID, in: db) {
                removedDuplicate = true
                try self.deleteRow(itemID, in: db)
                return nil
            }
            let previous = stored.item
            stored.item.urlString = urlString
            if stored.item != previous {
                try self.writeSave(stored, previous: previous, in: db)
            }
            return stored.item
        } ?? nil
        if removedDuplicate { releaseSidecars(for: itemID) }
        return result
    }

    @discardableResult
    public func add(urlString: String, source: CaptureSource = .manual) -> ReadingListItem {
        var item = ReadingListItem(urlString: urlString)
        item.captureSource = source
        let inserted: ReadingListItem? = write { db in
            if let existing = try SavesReader.item(forURLString: urlString, in: db) {
                return existing.item
            }
            try self.insertAtFront([item], in: db)
            return item
        }
        // A database that cannot be opened returns the unsaved item, which is what
        // a failed write always did.
        return inserted ?? item
    }

    /// The atomic first step of a save-button run. It either reserves a new URL
    /// in the list or records the press time on the existing item, returning the
    /// prior press time used by `SavePressPolicy`.
    ///
    /// Keeping lookup, insertion, and timestamp mutation inside ONE transaction
    /// closes the overlapping-App-Intent race where two runs could both observe
    /// "not saved" before either inserted the item. `at` is captured when the
    /// intent starts, not after extraction/ingest finishes.
    public struct SaveAttemptReservation {
        public let item: ReadingListItem
        public let wasAdded: Bool
        public let previousPressDate: Date?

        public init(item: ReadingListItem, wasAdded: Bool, previousPressDate: Date?) {
            self.item = item
            self.wasAdded = wasAdded
            self.previousPressDate = previousPressDate
        }
    }

    public func reserveSaveAttempt(
        urlString: String, source: CaptureSource = .manual, at date: Date
    ) -> SaveAttemptReservation {
        var fresh = ReadingListItem(urlString: urlString)
        fresh.dateAdded = date
        // Persist the exact policy timestamp too; dateAdded remains a fallback,
        // not the only durable record for a first save attempt.
        fresh.lastSaveAttemptDate = date
        fresh.captureSource = source

        let reservation: SaveAttemptReservation? = write { db in
            if var stored = try SavesReader.item(forURLString: urlString, in: db) {
                let previousItem = stored.item
                let previous = stored.item.lastSaveAttemptDate ?? stored.item.dateAdded
                // Overlapping intents can reach this store in the opposite order
                // from when they started. Never move the durable marker backward.
                stored.item.lastSaveAttemptDate = max(previous, date)
                if stored.item != previousItem {
                    try self.writeSave(stored, previous: previousItem, in: db)
                }
                return SaveAttemptReservation(
                    item: stored.item, wasAdded: false, previousPressDate: previous)
            }
            try self.insertAtFront([fresh], in: db)
            return SaveAttemptReservation(item: fresh, wasAdded: true, previousPressDate: nil)
        }
        return reservation
            ?? SaveAttemptReservation(item: fresh, wasAdded: true, previousPressDate: nil)
    }

    /// Extends an attempt's seven-second marker to its actual completion time.
    /// The start timestamp is already durable from `reserveSaveAttempt`; this
    /// second commit makes the window effectively run from start while work is
    /// active, then from completion once it finishes.
    public func finishSaveAttempt(for itemID: UUID, at date: Date = Date()) {
        updateItem(itemID) { item in
            let previous = item.lastSaveAttemptDate ?? item.dateAdded
            guard date > previous else { return false }
            item.lastSaveAttemptDate = date
            return true
        }
    }

    /// Adds a URL only when it isn't already saved, returning the new item, or nil
    /// when an item with that exact URL already exists. THE single URL-existence
    /// dedup authority for "drop a duplicate incoming item" (the recipient-side
    /// friend-share guard, and the share/action extensions' own save): callers
    /// that must NOT re-attribute / re-notify a duplicate route through here
    /// rather than pre-checking `item(forURLString:)` then calling `add`. (The
    /// ingestor's separate tracker-merge guard is an orthogonal condition — same
    /// URL inside a different item's price tracker.)
    @discardableResult
    public func addIfAbsent(urlString: String, source: CaptureSource = .manual) -> ReadingListItem? {
        var item = ReadingListItem(urlString: urlString)
        item.captureSource = source
        return write { db -> ReadingListItem? in
            guard try SavesReader.item(forURLString: urlString, in: db) == nil else { return nil }
            try self.insertAtFront([item], in: db)
            return item
        } ?? nil
    }

    /// Copies an imported document into the Articles directory and saves a pending
    /// item pointing at it (`Articles/<id>-source.<ext>`, the layout
    /// `originalDocumentURL(for:)` reads). Returns nil when the copy fails —
    /// nothing is saved in that case, so there is no item promising a file that
    /// isn't there.
    ///
    /// The copy is SYNCHRONOUS on purpose: the share extension's provider deletes
    /// `sourceURL` the moment its callback returns.
    @discardableResult
    public func addImportedDocument(
        sourceURL: URL, source: CaptureSource = .shareSheet
    ) -> ReadingListItem? {
        let id = UUID()
        // Restrict the extension to alphanumerics so it can't smuggle path
        // separators into the `<id>-source.<ext>` filename.
        let rawExtension = sourceURL.pathExtension.lowercased().filter { $0.isLetter || $0.isNumber }
        let fileExtension = rawExtension.isEmpty ? "txt" : String(rawExtension.prefix(8))
        let name = sourceURL.deletingPathExtension().lastPathComponent
        let destination = articlesDirectory
            .appendingPathComponent("\(id.uuidString)-source.\(fileExtension)")
        do {
            try fileManager.copyItem(at: sourceURL, to: destination)
        } catch {
            SharedDiagnosticLog.record(
                "failed to copy imported document: \(error.localizedDescription)", category: "store")
            return nil
        }
        BackupPolicy.includeInBackups(destination)

        var item = ReadingListItem(urlString: "lunadoc://\(id.uuidString)", id: id)
        item.title = name.isEmpty ? L10n.string("Common_document") : name
        item.documentType = fileExtension
        item.captureSource = source
        return write { db -> ReadingListItem in
            try self.insertAtFront([item], in: db)
            return item
        }
    }

    // MARK: - Bulk import

    /// One link from a file import, with the list it belongs in.
    public struct ImportedLink: Equatable, Sendable {
        public let urlString: String
        public let isArchived: Bool

        public init(urlString: String, isArchived: Bool) {
            self.urlString = urlString
            self.isArchived = isArchived
        }
    }

    /// What `insertImported` did with one requested link.
    /// Not `Sendable`: it carries a `ReadingListItem`, which isn't.
    public struct ImportedLinkPlacement: Equatable {
        /// The stored item: the one just inserted, or the save this URL already had.
        public let item: ReadingListItem
        /// False when the URL was already in the list, so nothing was inserted.
        public let wasInserted: Bool

        public init(item: ReadingListItem, wasInserted: Bool) {
            self.item = item
            self.wasInserted = wasInserted
        }
    }

    /// Places a whole imported batch in ONE transaction, preserving the caller's
    /// order (see `claudedocs/import-export.md`).
    ///
    /// Three things this does that a loop over `addIfAbsent` cannot:
    ///
    /// - **Order survives.** Every deck sorts by `bumpDate ?? dateAdded`
    ///   descending, not by list position, so N items stamped with the same
    ///   `Date()` come out ordered by UUID — i.e. shuffled. Each item's
    ///   `dateAdded` is therefore stepped `spacing` further back than the one
    ///   before it, which reproduces the file's order exactly. `spacing` is
    ///   deliberately small: the whole batch should still read as "just now".
    /// - **One transaction** instead of N read-modify-write cycles over the
    ///   whole list, which for a few hundred links is the difference between a
    ///   blink and a visible stall.
    /// - **The archive arrives archived**, in the same commit, so a batch
    ///   interrupted by a crash or a background can't leave archived saves
    ///   sitting in the deck.
    ///
    /// `lastSaveAttemptDate` is pinned to `.distantPast` rather than left nil:
    /// the save-press window falls back to `dateAdded` when it's absent, and a
    /// just-imported URL shared from Safari seconds later would otherwise read as
    /// the SECOND press on that item and route to Kindle. An import is not a
    /// save press.
    ///
    /// Returns one placement per requested link, in request order. Duplicates —
    /// already in the list, or repeated inside the batch — return the existing
    /// item with `wasInserted == false`.
    @discardableResult
    public func insertImported(
        _ links: [ImportedLink], source: CaptureSource = .manual,
        startingAt date: Date = Date(), spacing: TimeInterval = 0.01
    ) -> [ImportedLinkPlacement] {
        guard !links.isEmpty else { return [] }
        let placements: [ImportedLinkPlacement]? = write { db in
            var existingByURL = Dictionary(
                try SavesReader.allItems(in: db).map { ($0.urlString, $0) },
                uniquingKeysWith: { first, _ in first })
            var placements: [ImportedLinkPlacement] = []
            var inserted: [ReadingListItem] = []
            placements.reserveCapacity(links.count)

            for link in links {
                if let existing = existingByURL[link.urlString] {
                    placements.append(
                        ImportedLinkPlacement(item: existing, wasInserted: false))
                    continue
                }
                var item = ReadingListItem(urlString: link.urlString)
                item.captureSource = source
                item.dateAdded = date.addingTimeInterval(-Double(inserted.count) * spacing)
                item.lastSaveAttemptDate = .distantPast
                if link.isArchived { item.archivedAt = item.dateAdded }
                inserted.append(item)
                existingByURL[link.urlString] = item
                placements.append(ImportedLinkPlacement(item: item, wasInserted: true))
            }
            // `inserted` is already newest-first (index 0 carries the latest
            // `dateAdded`), which is the list's own convention.
            try self.insertAtFront(inserted, in: db)
            return placements
        }
        return placements ?? []
    }

    // Mutations are targeted (fetch-fresh, set one field, save) rather than
    // whole-item writes: callers hold stale copies, and overwriting the whole
    // item silently reverts fields written by other screens in the meantime.

    /// Marks a download/extraction failure.
    public func markFailed(_ itemID: UUID) {
        updateItem(itemID) { item in
            item.state = .failed
            return true
        }
    }

    /// What `saveReaderExitPosition` should do with `lastScrollOffset` — the old
    /// `scrollOffset: Double?` + `clearScrollOffset: Bool` pair let a caller pass
    /// both a value AND clear at the same time (meaningless, and one caller had
    /// to derive the bool from the same optional it was already passing).
    public enum ScrollOffsetEdit: Equatable {
        case unchanged
        case clear
        case set(Double)
    }

    /// Persists a reader's resume position on exit.
    /// One transaction for everything a reader persists on close — scroll
    /// offset, reading progress (monotonic), spoken word, RSVP word index —
    /// instead of several back-to-back read-modify-write cycles on the main
    /// thread. nil parameters leave their field untouched; `lastWordIndex`
    /// lets the RSVP reader batch its exit save the same way the scroll reader does.
    /// - Parameter scrollOffset: what to do with `lastScrollOffset` — leave it
    ///   alone, clear it (the RSVP reader moves the shared position in word space
    ///   with no pixels, so the stored exact offset no longer corresponds to
    ///   `lastWordIndex` and must be invalidated), or set it to a new value.
    /// - Parameter lastOriginalScrollOffset: the archive reader's own disjoint offset.
    ///
    /// Fire-and-forget (see `asyncUpdate`) — called from reader teardown paths
    /// (often mid pop-transition), and these fields are resume positions consumed
    /// on the NEXT open, not read back immediately after being set.
    public func saveReaderExitPosition(
        scrollOffset: ScrollOffsetEdit = .unchanged,
        readingProgress: Double? = nil,
        lastSpokenWordIndex: Int? = nil, lastWordIndex: Int? = nil,
        lastOriginalScrollOffset: Double? = nil,
        for itemID: UUID
    ) {
        asyncUpdate(itemID) { item in
            var changed = false
            switch scrollOffset {
            case .unchanged:
                break
            case .clear:
                if item.lastScrollOffset != nil {
                    item.lastScrollOffset = nil
                    changed = true
                }
            case .set(let value):
                if item.lastScrollOffset != value {
                    item.lastScrollOffset = value
                    changed = true
                }
            }
            if let lastOriginalScrollOffset, item.lastOriginalScrollOffset != lastOriginalScrollOffset {
                item.lastOriginalScrollOffset = lastOriginalScrollOffset
                changed = true
            }
            if let readingProgress {
                let clamped = min(max(readingProgress, 0), 1)
                if clamped > (item.readingProgress ?? 0) {
                    item.readingProgress = clamped
                    changed = true
                }
            }
            if let lastSpokenWordIndex, item.lastSpokenWordIndex != lastSpokenWordIndex {
                item.lastSpokenWordIndex = lastSpokenWordIndex
                changed = true
            }
            if let lastWordIndex, item.lastWordIndex != lastWordIndex {
                item.lastWordIndex = lastWordIndex
                changed = true
            }
            return changed
        }
    }

    /// Persists the read-aloud resume position (marks audio as having played).
    /// Fire-and-forget (see `asyncUpdate`) — a resume position consumed on the
    /// NEXT open, not read back immediately after being set.
    public func setLastSpokenWordIndex(_ wordIndex: Int, for itemID: UUID) {
        asyncUpdate(itemID) { item in
            guard item.lastSpokenWordIndex != wordIndex else { return false }
            item.lastSpokenWordIndex = wordIndex
            return true
        }
    }

    public func delete(_ item: ReadingListItem) {
        // The row is the whole delete: its ownership edges cascade with it, and
        // every file left with no owner is queued for the reaper (below) inside
        // the same commit.
        write { db in
            try self.deleteRow(item.id, in: db)
        }
        releaseSidecars(for: item.id)
        SaveDiagnosticsStore.shared.delete(for: item.id)
    }

    /// Moves an item into or out of its surface's archive tray. Archiving keeps
    /// the saved article/document bytes intact, but releases this root's entire
    /// recursive preload tree so it owns no speculative descendants (depth 0).
    public func setArchived(_ archived: Bool, for itemID: UUID, at date: Date = Date()) {
        let changed = updateItem(itemID) { item in
            if archived {
                guard item.archivedAt == nil || item.pendingArchiveAt != nil else { return false }
                if item.archivedAt == nil { item.archivedAt = date }
            } else {
                guard item.archivedAt != nil || item.pendingArchiveAt != nil else { return false }
                item.archivedAt = nil
            }
            item.pendingArchiveAt = nil
            return true
        }
        if changed, archived {
            preloads.releaseTree(rootID: itemID)
        }
    }

    /// Remembers which reader the user last used for an article.
    public func setReaderMode(_ mode: ReadingListItem.ReaderMode, for itemID: UUID) {
        updateItem(itemID) { item in
            guard item.lastReaderMode != mode else { return false }
            item.lastReaderMode = mode
            return true
        }
    }

    /// Updates a destination's delivery status; `.sent` also stamps the
    /// destination's `datesSent` (the once-per-day resend guard).
    public func setSendState(
        _ sendState: ReadingListItem.SendState, for itemID: UUID, destination: String
    ) {
        updateItem(itemID) { item in
            item.sendStates[destination] = sendState
            if sendState == .sent {
                item.datesSent[destination] = Date()
                item.sendFailureCounts[destination] = nil
                item.sendNextAttemptDates[destination] = nil
                item.sendLastErrors[destination] = nil
            }
            return true
        }
    }

    /// Marks a send as actively queued/in-flight without clearing accumulated
    /// retry metadata. If the app is killed mid-send, the queued state is retried
    /// on a later sweep.
    public func markSendAttemptStarted(for itemID: UUID, destination: String) {
        updateItem(itemID) { item in
            item.sendStates[destination] = .queued
            return true
        }
    }

    /// Persists a soft delivery failure and its next backoff window.
    public func scheduleSendRetry(
        for itemID: UUID, destination: String, failureCount: Int,
        nextAttemptDate: Date, errorMessage: String
    ) {
        updateItem(itemID) { item in
            item.sendStates[destination] = .queued
            item.sendFailureCounts[destination] = failureCount
            item.sendNextAttemptDates[destination] = nextAttemptDate
            item.sendLastErrors[destination] = errorMessage
            return true
        }
    }

    /// Persists a terminal send failure and records that the UI should surface it
    /// once on the next launch/foreground presentation.
    public func markSendTerminalFailure(
        for itemID: UUID, destination: String, errorMessage: String,
        failureCount: Int? = nil
    ) {
        updateItem(itemID) { item in
            item.sendStates[destination] = .failed
            if let failureCount {
                item.sendFailureCounts[destination] = failureCount
            }
            item.sendNextAttemptDates[destination] = nil
            item.sendLastErrors[destination] = errorMessage
            return true
        }
    }

    /// Records the stable sender identity for an incoming-email item while
    /// retaining the parsed name as a fallback when no contact exists. The only
    /// writer of `senderName`.
    public func setIncomingSender(email: String, displayName: String, for itemID: UUID) {
        updateItem(itemID) { item in
            let changed = item.incomingSenderEmail != email || item.senderName != displayName
            item.incomingSenderEmail = email
            item.senderName = displayName
            return changed
        }
    }

    /// Writes downloaded art bytes to the Articles dir and points the item at it.
    public func setThumbnail(_ data: Data, for itemID: UUID) {
        let fileName = "\(itemID.uuidString)-thumb.jpg"
        updateItem(itemID) { item in
            do {
                let url = self.articlesDirectory.appendingPathComponent(fileName)
                try data.write(to: url, options: .atomic)
                BackupPolicy.includeInBackups(url)
            } catch {
                SharedDiagnosticLog.record(
                    "failed to write thumbnail: \(error.localizedDescription)", category: "store")
                return false
            }
            item.thumbnailFileName = fileName
            return true
        }
    }

    /// Fills in metadata for a recognized platform item and marks it ready
    /// (platform items have no `ArticleContent`). Best-effort: any field may be
    /// nil and the item still renders (logo + deep link).
    public func savePlatformMetadata(
        platform: ContentPlatform, platformItemID: String?, title: String?,
        thumbnailFileName: String?, for itemID: UUID
    ) -> ReadingListItem? {
        let result = mutateItem(itemID) { item -> ReadingListItem in
            item.platform = platform
            item.platformItemID = platformItemID
            if let title, !title.isEmpty { item.title = title }
            if let thumbnailFileName { item.thumbnailFileName = thumbnailFileName }
            item.state = .ready
            return item
        }
        // No longer failed: drop the sidecar's failure detail so a LATER failure
        // starts from a clean count and reason.
        if result != nil { Self.clearFailureRecords(itemID) }
        return result
    }

    /// Raises the item's read state; never downgrades (read stays read).
    public func markReadState(_ newState: ReadingListItem.ReadState, for itemID: UUID) {
        updateItem(itemID) { item in
            let order: [ReadingListItem.ReadState] = [.unopened, .opened, .read]
            guard let current = order.firstIndex(of: item.readState),
                  let proposed = order.firstIndex(of: newState),
                  proposed > current
            else { return false }
            item.readState = newState
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
        updateItem(itemID) { item in
            var changed = false
            if item.readState != .read {
                item.readState = .read
                changed = true
            }
            if (item.readingProgress ?? 0) < 1 {
                item.readingProgress = 1
                changed = true
            }
            if item.archivedAt == nil, item.pendingArchiveAt == nil {
                item.pendingArchiveAt = date
                changed = true
            }
            return changed
        }
    }

    /// Moves every reader-completed item into Archive in one transaction.
    /// Called by the Reader app on background and once during cold launch.
    public func archivePendingFinishedItems() {
        var archivedIDs: [UUID] = []
        write { db in
            let pending = try SavesReader.itemsWithPendingArchive(in: db)
            guard !pending.isEmpty else { return }
            for var stored in pending {
                let previous = stored.item
                guard let pendingAt = stored.item.pendingArchiveAt else { continue }
                if stored.item.archivedAt == nil {
                    stored.item.archivedAt = pendingAt
                    archivedIDs.append(stored.item.id)
                }
                stored.item.pendingArchiveAt = nil
                try self.writeSave(stored, previous: previous, in: db)
            }
        }
        for id in archivedIDs { preloads.releaseTree(rootID: id) }
    }

    /// Forces an item back to unread, clears every archive marker, and bumps it
    /// to the front of the active carousel (the Archive-tray "Unarchive"
    /// action). This is a deliberate downgrade that `markReadState`'s
    /// forward-only guard disallows.
    public func markUnread(_ itemID: UUID, at date: Date = Date()) {
        updateItem(itemID) { item in
            guard item.readState != .unopened
                    || item.archivedAt != nil
                    || item.pendingArchiveAt != nil
            else { return false }
            item.readState = .unopened
            item.archivedAt = nil
            item.pendingArchiveAt = nil
            item.bumpDate = date
            return true
        }
    }

    // MARK: - Price tracking

    /// Attaches a price-tracker payload to an item and marks it ready (a tracker
    /// has no article content to download). Returns the refreshed item.
    @discardableResult
    public func savePriceTracker(_ tracker: PriceTracker, for itemID: UUID) -> ReadingListItem? {
        let result = mutateItem(itemID) { item -> ReadingListItem in
            item.priceTracker = tracker
            item.title = tracker.productName
            item.state = .ready
            return item
        }
        if result != nil { Self.clearFailureRecords(itemID) }
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
        mutateItem(itemID) { item -> ReadingListItem? in
            guard item.priceTracker != nil else { return nil }
            item.priceTracker = tracker
            item.title = tracker.productName
            return item
        } ?? nil
    }

    /// The existing price tracker (and its item id) whose stores already include
    /// `urlString`, if any. Lets a re-save of an already-tracked URL short-circuit
    /// to the existing tracker instead of re-detecting (and re-merging into a
    /// duplicate). Candidates are scanned in stable id order so the result is
    /// deterministic when (defensively) more than one tracker holds the URL.
    public func priceTracker(containingStoreURL urlString: String) -> (itemID: UUID, tracker: PriceTracker)? {
        guard let database = database() else { return nil }
        do {
            let candidates: [UUID] = try database.perform { db in
                try db.readTransaction { try SavesReader.saveIDs(trackingStoreURL: urlString, in: db) }
            }
            let byID = Dictionary(items().map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            return candidates
                .sorted { $0.uuidString < $1.uuidString }
                .compactMap { id -> (itemID: UUID, tracker: PriceTracker)? in
                    guard let tracker = byID[id]?.priceTracker,
                          tracker.hasStore(urlString: urlString) else { return nil }
                    return (id, tracker)
                }
                .first
        } catch {
            record(error, "tracker lookup")
            return nil
        }
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
        write { db in
            guard var stored = try SavesReader.item(id: itemID, in: db) else { return }
            let previous = stored.item
            stored.item.bumpDate = Date()
            stored.seq = try SavesReader.nextSeq(in: db)
            try self.writeSave(stored, previous: previous, in: db)
        }
    }

    // MARK: - Article content

    public func saveContent(_ content: ArticleContent, for item: ReadingListItem) -> ReadingListItem {
        let fileName = "\(item.id.uuidString).json"
        let saved: ReadingListItem = write { db -> ReadingListItem in
            guard var stored = try SavesReader.item(id: item.id, in: db) else { return item }
            let previous = stored.item
            // The images this content references, claimed in the same transaction
            // as the row: nil while the content write has not succeeded, because a
            // save that failed to write claims nothing.
            var ownedImages: [String]?
            // Both encode AND write must succeed before the item flips `.ready` —
            // a ready item whose content file doesn't exist is a blank reader.
            if let data = try? JSONEncoder().encode(content),
               (try? data.write(to: self.articlesDirectory.appendingPathComponent(fileName),
                                options: .atomic)) != nil {
                BackupPolicy.includeInBackups(self.articlesDirectory.appendingPathComponent(fileName))
                stored.item.contentFileName = fileName
                stored.item.title = content.title
                ownedImages = ArticleImageFiles.referencedNames(in: content)
                // Real content now exists (possibly after the user solved an archive
                // CAPTCHA), so this is the terminal ready state regardless of how it got here.
                stored.item.state = .ready
                stored.item.wordCount = content.blocks.reduce(0) {
                    $0 + $1.text.split(whereSeparator: { $0.isWhitespace }).count
                }
            } else {
                stored.item.state = .failed
            }
            if stored.item != previous {
                try self.writeSave(stored, previous: previous, in: db)
            }
            if let ownedImages {
                // The images are reconciled even when no column changed — the same
                // content re-saved still has to hold its pictures.
                try SavedFileOwnership.reconcile(
                    saveID: item.id, kinds: [.image],
                    artifacts: ownedImages.compactMap { name in
                        SavedFileOwnership.imagePath(name).map { (OwnedFileKind.image, $0) }
                    },
                    in: db)
            }
            return stored.item
        } ?? item
        // An image this content dropped may have lost its last owner above.
        reapPendingDeletes()
        // Keep the failure sidecar in step with the state this write landed on.
        if saved.state == .ready {
            Self.clearFailureRecords(item.id)
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
        updateItem(itemID) { item in
            // Never downgrade a readable item (a concurrent app/extension extract,
            // or a reused cf_clearance, may have already filled it in).
            guard item.state != .ready else { return false }
            item.state = .needsCaptcha
            if let title, !title.isEmpty { item.title = title }
            return true
        }
        // A locked-but-titled item is not a failed save; it has its own UX.
        Self.clearFailureRecords(itemID)
    }

    /// Everything a FAILED item accumulates outside the saves database: the
    /// reason/count sidecar and the diagnostic trace. They are dropped together,
    /// because an item that is no longer failed carrying last week's trace is
    /// worse than carrying none — the failed card would offer to share a story
    /// about a save that has since worked.
    static func clearFailureRecords(_ itemID: UUID) {
        SaveFailureStore.shared.clear(itemID)
        SaveDiagnosticsStore.shared.delete(for: itemID)
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
        write { db in
            // Remove every prior article content/source file so leftover state from
            // an earlier seed can't leak into this one.
            for directory in [articlesDir, originalsDir] {
                if let existing = try? self.fileManager.contentsOfDirectory(
                    at: directory, includingPropertiesForKeys: nil) {
                    for file in existing { try? self.fileManager.removeItem(at: file) }
                }
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
            try self.replaceAll(with: seeded, in: db)
        }
        reapPendingDeletes()
    }

    /// Empties the reading list and removes all article files. DEBUG-only.
    public func wipeForTesting() {
        let articlesDir = articlesDirectory
        let originalsDir = originalArchivesDirectory
        write { db in
            for directory in [articlesDir, originalsDir] {
                if let existing = try? self.fileManager.contentsOfDirectory(
                    at: directory, includingPropertiesForKeys: nil) {
                    for file in existing { try? self.fileManager.removeItem(at: file) }
                }
            }
            try self.replaceAll(with: [], in: db)
        }
        reapPendingDeletes()
    }

    /// Rows this connection has written since it opened. Lets a test prove a
    /// no-op mutation wrote nothing at all rather than identical values.
    public var writtenRowCountForTesting: Int {
        database()?.totalChanges ?? 0
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
        updateItem(item.id) { stored in
            guard stored.originalArchiveFileName != fileName else { return false }
            stored.originalArchiveFileName = fileName
            return true
        }
    }

    // MARK: - Reader-source HTML (the archive's capture input)

    /// The HTML that produced the item's reader content, held only until a
    /// `.webarchive` has been captured from it. The name is derived from the item id
    /// (like an imported document's source file), so it needs no field on the model.
    private func readerSourceHTMLURL(for itemID: UUID) -> URL {
        originalArchivesDirectory
            .appendingPathComponent("\(itemID.uuidString)-reader-source.html")
    }

    /// Records the exact HTML the resolver read the article out of, so the archive
    /// can be captured from THAT document rather than from a fresh live navigation.
    ///
    /// This matters whenever the two differ, which is every paywall bypass: the Paris
    /// Review's Steinbeck interview resolves through a pre-paywall Wayback snapshot
    /// holding the whole 49k-character interview, while the live page serves a 12k
    /// teaser under a subscribe card. Capturing live archived the teaser — a
    /// "original page" that was neither the original the user read nor dismissible.
    ///
    /// Written by whichever surface ingested the article, INCLUDING the share
    /// extension, whose own capture attempt races its process death; the file is what
    /// lets the app's backfill finish that work from the right document.
    public func saveReaderSourceHTML(_ html: String, for itemID: UUID) {
        guard !html.isEmpty else { return }
        let url = readerSourceHTMLURL(for: itemID)
        try? Data(html.utf8).write(to: url, options: .atomic)
        BackupPolicy.excludeFromBackups(url)
        // Named from the id rather than from a column, so this file takes its own
        // ownership edge — that is what makes deleting the save delete it too.
        guard let path = SavedFileOwnership.readerSourcePath(for: itemID) else { return }
        writeFileOwnership { db in
            try SavedFileOwnership.attach(path: path, kind: .readerSource, to: itemID, in: db)
        }
    }

    /// The saved reader-source HTML, when an archive still has to be captured from it.
    public func readerSourceHTML(for itemID: UUID) -> String? {
        guard let data = try? Data(contentsOf: readerSourceHTMLURL(for: itemID))
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Drops the capture input once the archive exists (or capture is known to be
    /// hopeless), so a transient artifact doesn't accumulate in the App Group.
    ///
    /// This one file is unlinked here rather than left to the reaper: its path is
    /// derived from the id, so the store knows exactly what it is deleting, and the
    /// caller's next act is often to hand the archive on.
    public func removeReaderSourceHTML(for itemID: UUID) {
        try? fileManager.removeItem(at: readerSourceHTMLURL(for: itemID))
        guard let path = SavedFileOwnership.readerSourcePath(for: itemID) else { return }
        writeFileOwnership { db in
            try SavedFileOwnership.detach(path: path, from: itemID, in: db)
        }
        reapPendingDeletes()
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

    // MARK: - Mutation primitives

    /// One write transaction. Returns nil when the database is unavailable or the
    /// transaction failed — every caller then behaves as it did when a write
    /// couldn't land. Posts `.readingListChanged` once, after the commit, if
    /// anything was written.
    @discardableResult
    private func write<T>(_ body: (SavesDatabase) throws -> T) -> T? {
        guard let database = database() else { return nil }
        var wrote = false
        do {
            let result = try database.transaction { db in
                let changesBefore = db.totalChanges
                let value = try body(db)
                wrote = db.totalChanges != changesBefore
                if wrote {
                    // Another connection's commits are picked up by data_version;
                    // our own are not, so drop the list and re-read it on the
                    // next call.
                    cachedItems = nil
                    cachedDataVersion = nil
                }
                return value
            }
            if wrote { postChanged() }
            return result
        } catch {
            record(error, "write")
            return nil
        }
    }

    /// A transaction that touches only the file-ownership tables. It posts NO
    /// change notification and leaves the item cache alone: which files a save
    /// holds is not part of the list any deck shows.
    private func writeFileOwnership(_ body: (SavesDatabase) throws -> Void) {
        guard let database = database() else { return }
        do {
            try database.transaction { db in try body(db) }
        } catch {
            record(error, "file ownership write")
        }
    }

    /// Unlinks the files whose last owner is gone.
    ///
    /// Called right after every mutation that can release one, at launch, and when
    /// an app backgrounds. It is idempotent and safe from any process, so an extra
    /// call costs one query against a table that is almost always empty — see
    /// `PendingDeleteReaper`.
    public func reapPendingDeletes() {
        guard let database = database() else { return }
        PendingDeleteReaper.reap(
            in: database, containerURL: containerURL, fileManager: fileManager)
    }

    /// The artifact kinds a save's own columns decide, reconciled at every row
    /// write. Images are NOT here: their names live inside the content, so
    /// `saveContent` is the only writer that knows them.
    private static let columnDerivedFileKinds: Set<OwnedFileKind> = [
        .content, .archive, .document, .thumbnail, .productImage,
    ]

    // MARK: - Files a preloaded page holds

    /// Records that the preloaded page `pageKey` holds exactly `fileNames` of the
    /// shared downloaded images in `Articles/`.
    ///
    /// A preloaded page is not a save — it lives in `PreloadStore`'s own cache — but
    /// it reads the same image files a save does, so both kinds of holder are
    /// counted in the one place. A page released while a save still shows the same
    /// picture leaves the file alone.
    public func setPreloadedPageImages(pageKey: String, fileNames: [String]) {
        writeFileOwnership { db in
            try SavedFileOwnership.reconcileHolder(
                holderKey: pageKey,
                paths: fileNames.compactMap { SavedFileOwnership.imagePath($0) }, in: db)
        }
        reapPendingDeletes()
    }

    /// Drops these preloaded pages' claims on their images. A whole released
    /// subtree arrives in one call, so it is one transaction and one unlink pass.
    public func releasePreloadedPages(pageKeys: [String]) {
        guard !pageKeys.isEmpty else { return }
        writeFileOwnership { db in
            for pageKey in pageKeys {
                try SavedFileOwnership.releaseHolder(holderKey: pageKey, in: db)
            }
        }
        reapPendingDeletes()
    }

    /// Reads the save `itemID` names, hands it to `body`, and writes it back only
    /// when `body` says it changed something. A missing id is a no-op, which is
    /// what every targeted setter wants.
    @discardableResult
    private func updateItem(_ itemID: UUID, _ body: (inout ReadingListItem) -> Bool) -> Bool {
        write { db in
            guard var stored = try SavesReader.item(id: itemID, in: db) else { return false }
            let previous = stored.item
            guard body(&stored.item) else { return false }
            try self.writeSave(stored, previous: previous, in: db)
            return true
        } ?? false
    }

    /// Like `updateItem` but for the setters that return something: `body`'s
    /// result is handed back, and the row is written when the item actually
    /// changed by value (so a setter that lands on the values already stored
    /// neither writes nor notifies).
    private func mutateItem<T>(_ itemID: UUID, _ body: (inout ReadingListItem) -> T) -> T? {
        write { db in
            guard var stored = try SavesReader.item(id: itemID, in: db) else { return nil }
            let previous = stored.item
            let result = body(&stored.item)
            if stored.item != previous {
                try self.writeSave(stored, previous: previous, in: db)
            }
            return result
        } ?? nil
    }

    /// Runs `updateItem` on `asyncUpdateQueue` instead of the caller's own
    /// thread. Reserved for setters whose callers don't need to observe the
    /// write's completion or read the field back immediately (resume positions,
    /// consumed on the NEXT open) — anything with a return value or a read-back
    /// expectation must stay on the synchronous primitives.
    /// A queued write targeting an item deleted before it runs is already a safe
    /// no-op (`updateItem`'s own missing-row guard).
    private func asyncUpdate(_ itemID: UUID, _ body: @escaping (inout ReadingListItem) -> Bool) {
        asyncUpdateQueue.async { [weak self] in
            self?.updateItem(itemID, body)
        }
    }

    /// Test seam: blocks until every `asyncUpdate` queued before this call has
    /// finished, so tests that write a position field then immediately assert on
    /// it can do so deterministically instead of racing the background write.
    public func flushPendingUpdates() {
        asyncUpdateQueue.sync {}
    }

    private func postChanged() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .readingListChanged, object: nil)
        }
    }

    // MARK: - Row writes

    /// Writes one save's row, and its child rows when the part they hold changed.
    ///
    /// `previous` is the row as it was read (nil for an insert). The send
    /// bookkeeping and the price tracker are each rewritten wholesale when they
    /// differ, which is what keeps an ordinary field update — a resume position,
    /// a read state — down to the one row it touches.
    private func writeSave(
        _ stored: StoredSave, previous: ReadingListItem?, in db: SavesDatabase
    ) throws {
        try db.run(SaveRow.upsertSQL) { try SaveRow.bind(stored.item, seq: stored.seq, to: $0) }
        // Every artifact this save's own columns name, claimed in the same
        // transaction as the columns. A file a column stopped pointing at loses
        // this owner here, which is how a replaced thumbnail is freed. Skipped when
        // no column that names a file moved — a resume position is written far more
        // often than a save gains an artifact.
        let artifactsChanged = previous.map { Self.ownedFilesDiffer($0, stored.item) } ?? true
        if artifactsChanged {
            try SavedFileOwnership.reconcile(
                saveID: stored.item.id, kinds: Self.columnDerivedFileKinds,
                artifacts: SavedFileOwnership.columnDerivedPaths(of: stored.item), in: db)
        }
        let sendStatesChanged = previous.map { Self.sendBookkeepingDiffers($0, stored.item) }
            ?? !SaveRow.sendDestinations(of: stored.item).isEmpty
        if sendStatesChanged {
            try db.run("DELETE FROM send_states WHERE save_id = ?") {
                try $0.bind(1, uuid: stored.item.id)
            }
            for destination in SaveRow.sendDestinations(of: stored.item) {
                try db.run(SaveRow.insertSendStateSQL) {
                    try SaveRow.bindSendState(stored.item, destination: destination, to: $0)
                }
            }
        }
        if previous?.priceTracker != stored.item.priceTracker {
            try db.run("DELETE FROM price_trackers WHERE save_id = ?") {
                try $0.bind(1, uuid: stored.item.id)
            }
            try db.run("DELETE FROM tracker_stores WHERE save_id = ?") {
                try $0.bind(1, uuid: stored.item.id)
            }
            try db.run("DELETE FROM tracker_rejected_sellers WHERE save_id = ?") {
                try $0.bind(1, uuid: stored.item.id)
            }
            if let tracker = stored.item.priceTracker {
                try writeTracker(tracker, saveID: stored.item.id, in: db)
            }
        }
    }

    /// Whether the two versions of a save name different files.
    private static func ownedFilesDiffer(
        _ lhs: ReadingListItem, _ rhs: ReadingListItem
    ) -> Bool {
        lhs.contentFileName != rhs.contentFileName
            || lhs.originalArchiveFileName != rhs.originalArchiveFileName
            || lhs.sanitizedDocumentType != rhs.sanitizedDocumentType
            || lhs.thumbnailFileName != rhs.thumbnailFileName
            || lhs.priceTracker?.imageFileName != rhs.priceTracker?.imageFileName
    }

    private static func sendBookkeepingDiffers(
        _ lhs: ReadingListItem, _ rhs: ReadingListItem
    ) -> Bool {
        lhs.sendStates != rhs.sendStates
            || lhs.datesSent != rhs.datesSent
            || lhs.sendFailureCounts != rhs.sendFailureCounts
            || lhs.sendNextAttemptDates != rhs.sendNextAttemptDates
            || lhs.sendLastErrors != rhs.sendLastErrors
    }

    private func writeTracker(
        _ tracker: PriceTracker, saveID: UUID, in db: SavesDatabase
    ) throws {
        try db.run(SaveRow.insertTrackerSQL) {
            try SaveRow.bindTracker(tracker, saveID: saveID, to: $0)
        }
        for host in tracker.rejectedSellerHosts {
            try db.run(
                "INSERT OR IGNORE INTO tracker_rejected_sellers (save_id, host) VALUES (?, ?)"
            ) {
                try $0.bind(1, uuid: saveID)
                try $0.bind(2, host)
            }
        }
        for (position, store) in tracker.stores.enumerated() {
            try db.run(SaveRow.insertStoreSQL) {
                try SaveRow.bindStore(store, saveID: saveID, position: position, to: $0)
            }
            let storeID = try SavesReader.storeID(saveID: saveID, urlString: store.urlString, in: db)
            guard let storeID else { continue }
            for point in store.priceHistory {
                try db.run(SaveRow.insertPricePointSQL) {
                    try SaveRow.bindPricePoint(point, storeID: storeID, to: $0)
                }
            }
        }
    }

    /// Inserts new saves at the FRONT of the list, keeping their own order
    /// (`items[0]` ends up first). Nothing already stored is touched.
    private func insertAtFront(_ items: [ReadingListItem], in db: SavesDatabase) throws {
        guard !items.isEmpty else { return }
        let base = try SavesReader.maxSeq(in: db)
        for (offset, item) in items.enumerated() {
            let seq = base + Int64(items.count - offset)
            try writeSave(StoredSave(item: item, seq: seq), previous: nil, in: db)
        }
    }

    /// Replaces the whole list with `items`, in the order given. The child rows
    /// go with the saves through `ON DELETE CASCADE`.
    private func replaceAll(with items: [ReadingListItem], in db: SavesDatabase) throws {
        try db.execute("DELETE FROM saves")
        for (offset, item) in items.enumerated() {
            let seq = Int64(items.count - offset)
            try writeSave(StoredSave(item: item, seq: seq), previous: nil, in: db)
        }
    }

    private func deleteRow(_ itemID: UUID, in db: SavesDatabase) throws {
        try db.run("DELETE FROM saves WHERE id = ?") { try $0.bind(1, uuid: itemID) }
    }

    // MARK: - Private

    /// Everything a deleted save owned that the database's own cascade does not
    /// reach: the reaper's unlink of the files the cascade just released, and the
    /// preload subtree (its own cache, keyed by URL rather than by save, with its
    /// own index — only ever deletes files under `Preloads/`).
    private func releaseSidecars(for itemID: UUID) {
        reapPendingDeletes()
        preloads.releaseTree(rootID: itemID)
    }
}

/// A save as stored: the item plus the list-position column, which is the list's
/// own order rather than anything the model carries.
struct StoredSave {
    var item: ReadingListItem
    var seq: Int64
}
