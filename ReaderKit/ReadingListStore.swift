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
    func add(urlString: String, source: CaptureSource = .manual) -> ReadingListItem {
        mutationLock.lock()
        defer { mutationLock.unlock() }
        var all = items()
        if let existing = all.first(where: { $0.urlString == urlString }) {
            return existing
        }
        var item = ReadingListItem(urlString: urlString)
        item.captureSource = source
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

    /// Updates a destination's delivery status; `.sent` also stamps the
    /// destination's `datesSent` (the once-per-day resend guard).
    func setSendState(
        _ sendState: ReadingListItem.SendState, for itemID: UUID, destination: String
    ) {
        mutationLock.lock()
        defer { mutationLock.unlock() }
        var all = items()
        guard let index = all.firstIndex(where: { $0.id == itemID }) else { return }
        all[index].sendStates[destination] = sendState
        if sendState == .sent {
            all[index].datesSent[destination] = Date()
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

    /// Sets the leading-label source (e.g. the email sender for imported mail,
    /// shown where the host would be).
    func setChannelName(_ name: String, for itemID: UUID) {
        mutationLock.lock()
        defer { mutationLock.unlock() }
        var all = items()
        guard let index = all.firstIndex(where: { $0.id == itemID }),
              all[index].channelName != name else { return }
        all[index].channelName = name
        save(all)
    }

    /// Writes downloaded art bytes to the Articles dir and points the item at it.
    func setThumbnail(_ data: Data, for itemID: UUID) {
        let fileName = "\(itemID.uuidString)-thumb.jpg"
        try? data.write(to: articlesDirectory.appendingPathComponent(fileName), options: .atomic)
        mutationLock.lock()
        defer { mutationLock.unlock() }
        var all = items()
        guard let index = all.firstIndex(where: { $0.id == itemID }) else { return }
        all[index].thumbnailFileName = fileName
        save(all)
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
        all[index].platform = .youtube
        all[index].platformItemID = videoID
        all[index].title = title
        all[index].channelName = channelName
        all[index].thumbnailFileName = thumbnailFileName
        all[index].state = .ready
        save(all)
        return all[index]
    }

    /// Creates (or returns the existing) URL-less music/podcast item from a
    /// synthetic `clickmusic://`/`clickpodcast://` key, marked ready. Used by the
    /// media intents and incoming media shares.
    @discardableResult
    func createURLlessMediaItem(
        platform: ContentPlatform, creator: String, title: String
    ) -> ReadingListItem {
        let key = MediaItemKey.url(platform: platform, creator: creator, title: title)
        let item = add(urlString: key)
        let display = creator.isEmpty ? title : "\(creator) — \(title)"
        return savePlatformMetadata(
            platform: platform, platformItemID: nil, title: display, creator: creator,
            thumbnailFileName: nil, mediaCreatorName: creator, mediaItemTitle: title,
            mediaSourceService: nil, for: item.id) ?? item
    }

    /// Fills in metadata for a recognized platform item and marks it ready
    /// (platform items have no `ArticleContent`). Best-effort: any field may be
    /// nil and the item still renders (logo + deep link). Mirrors
    /// `saveYouTubeMetadata` for the generic platform path.
    func savePlatformMetadata(
        platform: ContentPlatform, platformItemID: String?, title: String?,
        creator: String?, thumbnailFileName: String?,
        mediaCreatorName: String?, mediaItemTitle: String?,
        mediaSourceService: MusicProvider?, for itemID: UUID
    ) -> ReadingListItem? {
        mutationLock.lock()
        defer { mutationLock.unlock() }
        var all = items()
        guard let index = all.firstIndex(where: { $0.id == itemID }) else { return nil }
        all[index].platform = platform
        all[index].platformItemID = platformItemID
        if let title, !title.isEmpty { all[index].title = title }
        if let creator, !creator.isEmpty { all[index].channelName = creator }
        if let thumbnailFileName { all[index].thumbnailFileName = thumbnailFileName }
        all[index].mediaCreatorName = mediaCreatorName
        all[index].mediaItemTitle = mediaItemTitle
        all[index].mediaSourceService = mediaSourceService
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
