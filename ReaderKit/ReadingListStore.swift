//
//  ReadingListStore.swift
//  Clip
//

import Foundation

extension Notification.Name {
    /// Posted whenever the reading list changes (add/update/delete).
    static let readingListChanged = Notification.Name("readingListChanged")
}

/// Persists the reading list as JSON in the shared App Group container so both
/// the app and the SaveLink intent (which may run while the app is backgrounded)
/// see the same data. Reads fresh from disk on every operation — simple over fast.
final class ReadingListStore {
    static let shared = ReadingListStore()

    static let appGroupID = "group.com.hpiddy.clip"

    private let fileManager = FileManager.default
    private let overrideContainerURL: URL?

    /// Serializes read-modify-write mutations: concurrent ingest/send tasks
    /// would otherwise interleave loads and saves and silently lose updates.
    private let mutationLock = NSLock()

    /// The shared store uses the App Group container; tests pass a scratch
    /// directory so they never touch (or wipe) real user data.
    init(containerURL: URL? = nil) {
        self.overrideContainerURL = containerURL
    }

    private var containerURL: URL {
        if let overrideContainerURL { return overrideContainerURL }
        // The App Group container is provisioned for this app; if it's missing the
        // build is misconfigured and nothing works anyway, so fall back to temp.
        return fileManager.containerURL(forSecurityApplicationGroupIdentifier: Self.appGroupID)
            ?? fileManager.temporaryDirectory
    }

    private var listFileURL: URL {
        containerURL.appendingPathComponent("readingList.json")
    }

    var articlesDirectory: URL {
        let dir = containerURL.appendingPathComponent("Articles", isDirectory: true)
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - List operations

    /// All items in saved order — newest first (new items prepend), reorderable
    /// by the user.
    func items() -> [ReadingListItem] {
        guard let data = try? Data(contentsOf: listFileURL),
              let items = try? JSONDecoder().decode([ReadingListItem].self, from: data)
        else { return [] }
        return items
    }

    /// Reorders the stored list to match `orderedIDs` (items not listed keep
    /// their relative order at the end). Backs manual drag-to-reorder.
    func setOrder(_ orderedIDs: [UUID]) {
        mutationLock.lock()
        defer { mutationLock.unlock() }
        let all = items()
        let byID = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var reordered = orderedIDs.compactMap { byID[$0] }
        let placed = Set(orderedIDs)
        reordered.append(contentsOf: all.filter { !placed.contains($0.id) })
        save(reordered)
    }

    /// The existing item for a URL, if it's already in the list.
    func item(forURLString urlString: String) -> ReadingListItem? {
        items().first { $0.urlString == urlString }
    }

    /// A fresh copy of an item by ID (callers' copies go stale across mutations).
    func item(withID itemID: UUID) -> ReadingListItem? {
        items().first { $0.id == itemID }
    }

    @discardableResult
    func add(urlString: String) -> ReadingListItem {
        mutationLock.lock()
        defer { mutationLock.unlock() }
        var all = items()
        if let existing = all.first(where: { $0.urlString == urlString }) {
            return existing
        }
        let item = ReadingListItem(urlString: urlString)
        all.insert(item, at: 0) // newest first
        save(all)
        return item
    }

    // Mutations are targeted (fetch-fresh, set one field, save) rather than
    // whole-item writes: callers hold stale copies, and overwriting the whole
    // item silently reverts fields written by other screens in the meantime.

    /// Persists the RSVP resume position.
    func setLastWordIndex(_ wordIndex: Int, for itemID: UUID) {
        mutationLock.lock()
        defer { mutationLock.unlock() }
        var all = items()
        guard let index = all.firstIndex(where: { $0.id == itemID }),
              all[index].lastWordIndex != wordIndex else { return }
        all[index].lastWordIndex = wordIndex
        save(all)
    }

    /// Marks a download/extraction failure.
    func markFailed(_ itemID: UUID) {
        mutationLock.lock()
        defer { mutationLock.unlock() }
        var all = items()
        guard let index = all.firstIndex(where: { $0.id == itemID }) else { return }
        all[index].state = .failed
        save(all)
    }

    /// Persists the scroll reader's resume position.
    func setLastScrollOffset(_ offset: Double, for itemID: UUID) {
        mutationLock.lock()
        defer { mutationLock.unlock() }
        var all = items()
        guard let index = all.firstIndex(where: { $0.id == itemID }),
              all[index].lastScrollOffset != offset else { return }
        all[index].lastScrollOffset = offset
        save(all)
    }

    /// Persists the read-aloud resume position (marks audio as having played).
    func setLastSpokenWordIndex(_ wordIndex: Int, for itemID: UUID) {
        mutationLock.lock()
        defer { mutationLock.unlock() }
        var all = items()
        guard let index = all.firstIndex(where: { $0.id == itemID }),
              all[index].lastSpokenWordIndex != wordIndex else { return }
        all[index].lastSpokenWordIndex = wordIndex
        save(all)
    }

    /// Persists how far through the article the user has gotten (0…1, only
    /// ever increases).
    func setReadingProgress(_ progress: Double, for itemID: UUID) {
        mutationLock.lock()
        defer { mutationLock.unlock() }
        var all = items()
        guard let index = all.firstIndex(where: { $0.id == itemID }) else { return }
        let clamped = min(max(progress, 0), 1)
        guard clamped > (all[index].readingProgress ?? 0) else { return }
        all[index].readingProgress = clamped
        save(all)
    }

    /// Persists the eye-tracking estimate (nil clears it).
    func setEyeTrackedWordIndex(_ wordIndex: Int?, for itemID: UUID) {
        mutationLock.lock()
        defer { mutationLock.unlock() }
        var all = items()
        guard let index = all.firstIndex(where: { $0.id == itemID }),
              all[index].eyeTrackedWordIndex != wordIndex else { return }
        all[index].eyeTrackedWordIndex = wordIndex
        save(all)
    }

    /// Disabling eye tracking wipes every stored gaze estimate.
    func clearAllEyeTracking() {
        mutationLock.lock()
        defer { mutationLock.unlock() }
        var all = items()
        var changed = false
        for index in all.indices where all[index].eyeTrackedWordIndex != nil {
            all[index].eyeTrackedWordIndex = nil
            changed = true
        }
        if changed { save(all) }
    }

    func delete(_ item: ReadingListItem) {
        mutationLock.lock()
        defer { mutationLock.unlock() }
        var all = items()
        all.removeAll { $0.id == item.id }
        if let fileName = item.contentFileName {
            try? fileManager.removeItem(at: articlesDirectory.appendingPathComponent(fileName))
        }
        if let type = item.documentType {
            try? fileManager.removeItem(at: articlesDirectory
                .appendingPathComponent("\(item.id.uuidString)-source.\(type)"))
        }
        save(all)
    }

    /// Removes every finished article (and its cached content) in one pass.
    func deleteAllRead() {
        mutationLock.lock()
        defer { mutationLock.unlock() }
        var all = items()
        let read = all.filter { $0.readState == .read }
        guard !read.isEmpty else { return }
        for item in read {
            if let fileName = item.contentFileName {
                try? fileManager.removeItem(at: articlesDirectory.appendingPathComponent(fileName))
            }
        }
        all.removeAll { $0.readState == .read }
        save(all)
    }

    /// Remembers which reader the user last used for an article.
    func setReaderMode(_ mode: ReadingListItem.ReaderMode, for itemID: UUID) {
        mutationLock.lock()
        defer { mutationLock.unlock() }
        var all = items()
        guard let index = all.firstIndex(where: { $0.id == itemID }),
              all[index].lastReaderMode != mode else { return }
        all[index].lastReaderMode = mode
        save(all)
    }

    /// Updates the Kindle delivery status; `.sent` also stamps `dateSent`.
    func setSendState(_ sendState: ReadingListItem.SendState, for itemID: UUID) {
        mutationLock.lock()
        defer { mutationLock.unlock() }
        var all = items()
        guard let index = all.firstIndex(where: { $0.id == itemID }) else { return }
        all[index].sendState = sendState
        if sendState == .sent {
            all[index].dateSent = Date()
        }
        save(all)
    }

    /// Records a save press on an already-listed URL and returns the previous
    /// press time (the item's save time, if this is the first repeat press) —
    /// the primitive behind double-save-to-send detection.
    @discardableResult
    func recordSaveAttempt(for itemID: UUID) -> Date? {
        mutationLock.lock()
        defer { mutationLock.unlock() }
        var all = items()
        guard let index = all.firstIndex(where: { $0.id == itemID }) else { return nil }
        let previous = all[index].lastSaveAttemptDate ?? all[index].dateAdded
        all[index].lastSaveAttemptDate = Date()
        save(all)
        return previous
    }

    /// Records which friend shared this item to us (set once, on acceptance).
    func setSharedBy(_ username: String, for itemID: UUID) {
        mutationLock.lock()
        defer { mutationLock.unlock() }
        var all = items()
        guard let index = all.firstIndex(where: { $0.id == itemID }),
              all[index].sharedByUsername != username else { return }
        all[index].sharedByUsername = username
        save(all)
    }

    /// Fills in the YouTube metadata produced by ingestion and marks the item
    /// ready (videos have no article content).
    func saveYouTubeMetadata(
        videoID: String, title: String, channelName: String?,
        thumbnailFileName: String?, for itemID: UUID
    ) -> ReadingListItem? {
        mutationLock.lock()
        defer { mutationLock.unlock() }
        var all = items()
        guard let index = all.firstIndex(where: { $0.id == itemID }) else { return nil }
        all[index].youtubeVideoID = videoID
        all[index].title = title
        all[index].channelName = channelName
        all[index].thumbnailFileName = thumbnailFileName
        all[index].state = .ready
        save(all)
        return all[index]
    }

    /// Raises the item's read state; never downgrades (read stays read).
    func markReadState(_ newState: ReadingListItem.ReadState, for itemID: UUID) {
        mutationLock.lock()
        defer { mutationLock.unlock() }
        var all = items()
        guard let index = all.firstIndex(where: { $0.id == itemID }) else { return }
        let order: [ReadingListItem.ReadState] = [.unopened, .opened, .read]
        guard let current = order.firstIndex(of: all[index].readState),
              let proposed = order.firstIndex(of: newState),
              proposed > current
        else { return }
        all[index].readState = newState
        save(all)
    }

    // MARK: - Article content

    func saveContent(_ content: ArticleContent, for item: ReadingListItem) -> ReadingListItem {
        let fileName = "\(item.id.uuidString).json"
        mutationLock.lock()
        defer { mutationLock.unlock() }
        var all = items()
        guard let index = all.firstIndex(where: { $0.id == item.id }) else { return item }
        if let data = try? JSONEncoder().encode(content) {
            try? data.write(to: articlesDirectory.appendingPathComponent(fileName), options: .atomic)
            all[index].contentFileName = fileName
            all[index].title = content.title
            all[index].state = .ready
            all[index].wordCount = content.blocks.reduce(0) {
                $0 + $1.text.split(whereSeparator: { $0.isWhitespace }).count
            }
        } else {
            all[index].state = .failed
        }
        save(all)
        return all[index]
    }

    func content(for item: ReadingListItem) -> ArticleContent? {
        guard let fileName = item.contentFileName else { return nil }
        guard let data = try? Data(contentsOf: articlesDirectory.appendingPathComponent(fileName))
        else { return nil }
        return try? JSONDecoder().decode(ArticleContent.self, from: data)
    }

    // MARK: - Private

    private func save(_ items: [ReadingListItem]) {
        if let data = try? JSONEncoder().encode(items) {
            try? data.write(to: listFileURL, options: .atomic)
        }
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .readingListChanged, object: nil)
        }
    }
}
