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

    /// Serializes read-modify-write mutations WITHIN this process.
    private let mutationLock = NSLock()
    /// Serializes read-modify-write mutations ACROSS processes (app, SaveLink
    /// intent, share/action extensions all write `readingList.json`): without it,
    /// two processes that load → modify → save concurrently silently lose one
    /// side's update. Every mutation runs its read+modify+write inside one writing
    /// coordination via `coordinatedMutate`/`coordinatedUpdate`.
    private let fileCoordinator = NSFileCoordinator()

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
        var result: [ReadingListItem] = []
        var coordError: NSError?
        var ran = false
        fileCoordinator.coordinate(readingItemAt: listFileURL, options: [], error: &coordError) { url in
            ran = true
            result = Self.decodeItems(at: url)
        }
        if !ran { result = Self.decodeItems(at: listFileURL) }
        return result
    }

    /// Reorders the stored list to match `orderedIDs` (items not listed keep
    /// their relative order at the end). Backs manual drag-to-reorder.
    func setOrder(_ orderedIDs: [UUID]) {
        coordinatedMutate { all in
            let byID = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            var reordered = orderedIDs.compactMap { byID[$0] }
            let placed = Set(orderedIDs)
            reordered.append(contentsOf: all.filter { !placed.contains($0.id) })
            all = reordered
        }
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

    // Mutations are targeted (fetch-fresh, set one field, save) rather than
    // whole-item writes: callers hold stale copies, and overwriting the whole
    // item silently reverts fields written by other screens in the meantime.

    /// Persists the RSVP resume position.
    func setLastWordIndex(_ wordIndex: Int, for itemID: UUID) {
        coordinatedUpdate { all in
            guard let index = all.firstIndex(where: { $0.id == itemID }),
                  all[index].lastWordIndex != wordIndex else { return false }
            all[index].lastWordIndex = wordIndex
            return true
        }
    }

    /// Marks a download/extraction failure.
    func markFailed(_ itemID: UUID) {
        coordinatedUpdate { all in
            guard let index = all.firstIndex(where: { $0.id == itemID }) else { return false }
            all[index].state = .failed
            return true
        }
    }

    /// Persists the scroll reader's resume position.
    func setLastScrollOffset(_ offset: Double, for itemID: UUID) {
        coordinatedUpdate { all in
            guard let index = all.firstIndex(where: { $0.id == itemID }),
                  all[index].lastScrollOffset != offset else { return false }
            all[index].lastScrollOffset = offset
            return true
        }
    }

    /// Persists the read-aloud resume position (marks audio as having played).
    func setLastSpokenWordIndex(_ wordIndex: Int, for itemID: UUID) {
        coordinatedUpdate { all in
            guard let index = all.firstIndex(where: { $0.id == itemID }),
                  all[index].lastSpokenWordIndex != wordIndex else { return false }
            all[index].lastSpokenWordIndex = wordIndex
            return true
        }
    }

    /// Persists how far through the article the user has gotten (0…1, only
    /// ever increases).
    func setReadingProgress(_ progress: Double, for itemID: UUID) {
        coordinatedUpdate { all in
            guard let index = all.firstIndex(where: { $0.id == itemID }) else { return false }
            let clamped = min(max(progress, 0), 1)
            guard clamped > (all[index].readingProgress ?? 0) else { return false }
            all[index].readingProgress = clamped
            return true
        }
    }

    /// Persists the eye-tracking estimate (nil clears it).
    func setEyeTrackedWordIndex(_ wordIndex: Int?, for itemID: UUID) {
        coordinatedUpdate { all in
            guard let index = all.firstIndex(where: { $0.id == itemID }),
                  all[index].eyeTrackedWordIndex != wordIndex else { return false }
            all[index].eyeTrackedWordIndex = wordIndex
            return true
        }
    }

    /// Disabling eye tracking wipes every stored gaze estimate.
    func clearAllEyeTracking() {
        coordinatedUpdate { all in
            var changed = false
            for index in all.indices where all[index].eyeTrackedWordIndex != nil {
                all[index].eyeTrackedWordIndex = nil
                changed = true
            }
            return changed
        }
    }

    func delete(_ item: ReadingListItem) {
        coordinatedMutate { all in
            if let found = all.first(where: { $0.id == item.id }) { self.removeFiles(for: found) }
            all.removeAll { $0.id == item.id }
        }
    }

    /// Removes every finished article (and its cached content) in one pass.
    func deleteAllRead() {
        coordinatedMutate { all in
            for item in all where item.readState == .read { self.removeFiles(for: item) }
            all.removeAll { $0.readState == .read }
        }
    }

    /// Removes a set of items (and their cached content) in one pass — used to clear
    /// the whole Archive section at once.
    func deleteItems(ids: Set<UUID>) {
        coordinatedMutate { all in
            for item in all where ids.contains(item.id) { self.removeFiles(for: item) }
            all.removeAll { ids.contains($0.id) }
        }
    }

    /// Remembers which reader the user last used for an article.
    func setReaderMode(_ mode: ReadingListItem.ReaderMode, for itemID: UUID) {
        coordinatedUpdate { all in
            guard let index = all.firstIndex(where: { $0.id == itemID }),
                  all[index].lastReaderMode != mode else { return false }
            all[index].lastReaderMode = mode
            return true
        }
    }

    /// Updates a destination's delivery status; `.sent` also stamps the
    /// destination's `datesSent` (the once-per-day resend guard).
    func setSendState(
        _ sendState: ReadingListItem.SendState, for itemID: UUID, destination: String
    ) {
        coordinatedUpdate { all in
            guard let index = all.firstIndex(where: { $0.id == itemID }) else { return false }
            all[index].sendStates[destination] = sendState
            if sendState == .sent {
                all[index].datesSent[destination] = Date()
            }
            return true
        }
    }

    /// Records a save press on an already-listed URL and returns the previous
    /// press time (the item's save time, if this is the first repeat press) —
    /// the primitive behind double-save-to-send detection.
    @discardableResult
    func recordSaveAttempt(for itemID: UUID) -> Date? {
        coordinatedMutate { all in
            guard let index = all.firstIndex(where: { $0.id == itemID }) else { return nil }
            let previous = all[index].lastSaveAttemptDate ?? all[index].dateAdded
            all[index].lastSaveAttemptDate = Date()
            return previous
        }
    }

    /// Sets the leading-label source (e.g. the email sender for imported mail,
    /// shown where the host would be).
    func setChannelName(_ name: String, for itemID: UUID) {
        coordinatedUpdate { all in
            guard let index = all.firstIndex(where: { $0.id == itemID }),
                  all[index].channelName != name else { return false }
            all[index].channelName = name
            return true
        }
    }

    /// Writes downloaded art bytes to the Articles dir and points the item at it.
    func setThumbnail(_ data: Data, for itemID: UUID) {
        let fileName = "\(itemID.uuidString)-thumb.jpg"
        coordinatedUpdate { all in
            guard let index = all.firstIndex(where: { $0.id == itemID }) else { return false }
            try? data.write(to: self.articlesDirectory.appendingPathComponent(fileName), options: .atomic)
            all[index].thumbnailFileName = fileName
            return true
        }
    }

    /// Records which friend shared this item to us (set once, on acceptance).
    func setSharedBy(_ username: String, for itemID: UUID) {
        coordinatedUpdate { all in
            guard let index = all.firstIndex(where: { $0.id == itemID }),
                  all[index].sharedByUsername != username else { return false }
            all[index].sharedByUsername = username
            return true
        }
    }

    /// Fills in the YouTube metadata produced by ingestion and marks the item
    /// ready (videos have no article content).
    func saveYouTubeMetadata(
        videoID: String, title: String, channelName: String?,
        thumbnailFileName: String?, for itemID: UUID
    ) -> ReadingListItem? {
        coordinatedMutate { all in
            guard let index = all.firstIndex(where: { $0.id == itemID }) else { return nil }
            all[index].youtubeVideoID = videoID
            all[index].platform = .youtube
            all[index].platformItemID = videoID
            all[index].title = title
            all[index].channelName = channelName
            all[index].thumbnailFileName = thumbnailFileName
            all[index].state = .ready
            return all[index]
        }
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
        coordinatedMutate { all in
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
            return all[index]
        }
    }

    /// Raises the item's read state; never downgrades (read stays read).
    func markReadState(_ newState: ReadingListItem.ReadState, for itemID: UUID) {
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

    /// Forces an item back to unread (the Archive-section "Unarchive" action) — a
    /// deliberate downgrade that `markReadState`'s forward-only guard disallows.
    func markUnread(_ itemID: UUID) {
        coordinatedUpdate { all in
            guard let index = all.firstIndex(where: { $0.id == itemID }),
                  all[index].readState != .unopened else { return false }
            all[index].readState = .unopened
            return true
        }
    }

    // MARK: - Catch-up

    /// Stamps a new bump date on an item and moves it to the top of the list (it
    /// re-sorts up in the reading list and shows the bump date on future catch-up
    /// cards).
    func bump(_ itemID: UUID) {
        coordinatedUpdate { all in
            guard let index = all.firstIndex(where: { $0.id == itemID }) else { return false }
            var item = all.remove(at: index)
            item.bumpDate = Date()
            all.insert(item, at: 0)
            return true
        }
    }

    /// Overwrites the entire list with `items` — used to UNDO a whole catch-up
    /// session (bumps + read marks) in one shot from a pre-session snapshot.
    func restore(_ items: [ReadingListItem]) {
        coordinatedMutate { all in all = items }
    }

    // MARK: - Article content

    func saveContent(_ content: ArticleContent, for item: ReadingListItem) -> ReadingListItem {
        let fileName = "\(item.id.uuidString).json"
        return coordinatedMutate { all in
            guard let index = all.firstIndex(where: { $0.id == item.id }) else { return item }
            if let data = try? JSONEncoder().encode(content) {
                try? data.write(
                    to: self.articlesDirectory.appendingPathComponent(fileName), options: .atomic)
                all[index].contentFileName = fileName
                all[index].title = content.title
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
    }

    /// Marks a hard-paywalled article as needing a user-solved archive CAPTCHA: it
    /// lands in the list (with its real title) in the `.needsCaptcha` state, shown
    /// with a "tap to unlock" affordance. Tapping opens the archive.today snapshot in
    /// a web view; once the user solves the CAPTCHA the article is extracted and
    /// `saveContent` moves it to `.ready`.
    func markNeedsCaptcha(_ itemID: UUID, title: String?) {
        coordinatedUpdate { all in
            guard let index = all.firstIndex(where: { $0.id == itemID }) else { return false }
            // Never downgrade a readable item (a concurrent app/extension extract,
            // or a reused cf_clearance, may have already filled it in).
            guard all[index].state != .ready else { return false }
            all[index].state = .needsCaptcha
            if let title, !title.isEmpty { all[index].title = title }
            return true
        }
    }

    func content(for item: ReadingListItem) -> ArticleContent? {
        guard let fileName = item.contentFileName else { return nil }
        guard let data = try? Data(contentsOf: articlesDirectory.appendingPathComponent(fileName))
        else { return nil }
        return try? JSONDecoder().decode(ArticleContent.self, from: data)
    }

    // MARK: - Private

    private static func decodeItems(at url: URL) -> [ReadingListItem] {
        guard let data = try? Data(contentsOf: url),
              let items = try? JSONDecoder().decode([ReadingListItem].self, from: data)
        else { return [] }
        return items
    }

    private static func encodeItems(_ items: [ReadingListItem], to url: URL) {
        if let data = try? JSONEncoder().encode(items) {
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Coordinated read-modify-write of the whole list, returning `body`'s value.
    /// Holds the in-process `mutationLock` AND an `NSFileCoordinator` writing
    /// coordination across the entire read+modify+write so other processes can't
    /// lose this update (or vice versa). Always writes + posts `.readingListChanged`.
    @discardableResult
    private func coordinatedMutate<T>(_ body: (inout [ReadingListItem]) -> T) -> T {
        mutationLock.lock()
        defer { mutationLock.unlock() }
        func perform(_ url: URL) -> T {
            var all = Self.decodeItems(at: url)
            let result = body(&all)
            Self.encodeItems(all, to: url)
            return result
        }
        var coordResult: T?
        var coordError: NSError?
        fileCoordinator.coordinate(writingItemAt: listFileURL, options: [], error: &coordError) { url in
            coordResult = perform(url)
        }
        let result = coordResult ?? perform(listFileURL)
        postChanged()
        return result
    }

    /// Like `coordinatedMutate` but only writes + notifies when `body` reports a
    /// change — preserves the "skip the write if nothing changed" behavior of the
    /// targeted setters (no spurious reloads).
    private func coordinatedUpdate(_ body: (inout [ReadingListItem]) -> Bool) {
        mutationLock.lock()
        defer { mutationLock.unlock() }
        var changed = false
        func perform(_ url: URL) {
            var all = Self.decodeItems(at: url)
            if body(&all) {
                Self.encodeItems(all, to: url)
                changed = true
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
        if let ext = item.sanitizedDocumentType {
            try? fileManager.removeItem(at: articlesDirectory
                .appendingPathComponent("\(item.id.uuidString)-source.\(ext)"))
        }
        if let thumb = item.thumbnailFileName {
            try? fileManager.removeItem(at: articlesDirectory.appendingPathComponent(thumb))
        }
    }
}
