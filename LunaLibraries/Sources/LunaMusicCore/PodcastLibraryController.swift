import Foundation
import LunaAppConfig
import Combine
import UserNotifications
import LunaPodcastCore

@MainActor public final class PodcastLibraryController: ObservableObject {
    public static let shared = PodcastLibraryController()
    @Published public private(set) var state = PodcastLibraryState()
    @Published public private(set) var isRefreshing = false
    @Published public private(set) var errorMessage: String?
    public private(set) var store: PodcastStore?
    private let feedClient: PodcastFeedClient
    private var observer: NSObjectProtocol?
    @Published public private(set) var refreshingShowIDs: Set<String> = []
    private var prefetching: Set<String> = []
    private var refreshTasks: [String: Task<Void, Never>] = [:]
    nonisolated public static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("LunaMusic/Podcasts", isDirectory: true)
    }
    public init(url: URL = PodcastLibraryController.directory.appendingPathComponent("library.json"), session: URLSession = PodcastNetwork.session) {
        feedClient = PodcastFeedClient(session: session)
        do {
            store = try PodcastStore(url: url)
            let directory = url.deletingLastPathComponent().appendingPathComponent("ReaderAudio", isDirectory: true)
            if store!.state.episodes.values.contains(where: { $0.showID == ReaderPodcastSource.showID && $0.mediaURL.deletingLastPathComponent() != directory }) {
                try store!.update { state in
                    for (id, episode) in state.episodes where episode.showID == ReaderPodcastSource.showID {
                        state.episodes[id]?.mediaURL = directory.appendingPathComponent(episode.mediaURL.lastPathComponent == "\(id).gemini.m4a" ? "\(id).gemini.m4a" : "\(id).m4a")
                    }
                }
            }
            if store!.state.episodes.values.contains(where: { $0.mediaURL.isFileURL && $0.mediaURL.pathComponents.contains("ImportedAudio") }) {
                try store!.update { state in
                    for (id, episode) in state.episodes where episode.mediaURL.isFileURL && episode.mediaURL.pathComponents.contains("ImportedAudio") {
                        let filename = id + "." + episode.mediaURL.pathExtension
                        state.episodes[id]?.mediaURL = url.deletingLastPathComponent().appendingPathComponent("ImportedAudio").appendingPathComponent(filename)
                    }
                }
            }
            state = store!.state
            if url == Self.directory.appendingPathComponent("library.json") {
                store?.mutationHandler = PodcastAutomation.recordChanges
            }
        }
        catch { errorMessage = "Your podcast library could not be opened: \(error.localizedDescription)" }
        observer = NotificationCenter.default.addObserver(forName: .lunaPodcastsChanged, object: store, queue: .main) { [weak self] _ in
            Task { @MainActor in if let self, let store = self.store { self.state = store.state } }
        }
    }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
    public func requireStore() throws -> PodcastStore {
        guard let store else { throw PodcastError(errorMessage ?? "Your podcast library is unavailable.") }
        return store
    }
    public func edit(_ edit: (inout PodcastLibraryState) throws -> Void) throws { try requireStore().update(edit); reloadState() }
    public func reloadState() { if let store { state = store.state } }
    public func report(_ error: Error) { if !(error is CancellationError) { errorMessage = error.localizedDescription } }
    public func clearError() { errorMessage = nil }
    public func episodes(for showID: String, applySettings: Bool = true) -> [PodcastEpisode] {
        let show = state.shows[showID]
        return PodcastPolicies.ordered(state.episodes.values.filter {
            $0.showID == showID && (!applySettings || !(show?.settings.hidePlayed == true || state.settings.hidePlayed) || state.progress[$0.id]?.listened != true)
        }, newestFirst: show?.settings.newestFirst ?? true)
    }
    @discardableResult public func addFeed(_ url: URL, follow: Bool = true, directoryID: String? = nil) async throws -> String {
        guard PodcastIdentity.webURL(url.absoluteString) != nil else { throw PodcastError("Enter an http or https podcast feed address.") }
        if let existing = state.shows.values.first(where: { $0.feedURL == url }) {
            if follow { try setFollowed(existing.id, true) }
            reloadState()
            Task { await refresh(showIDs: [existing.id]) }
            return existing.id
        }
        let response = try await feedClient.fetch(PodcastShow(feedURL: url, title: ""))
        guard let feed = response.feed else { throw PodcastError("The podcast feed is empty.") }
        try Task.checkCancellation()
        let store = try requireStore()
        _ = try await store.mergeInBackground(feed, follow: follow, directoryID: directoryID, etag: response.etag, lastModified: response.lastModified)
        reloadState(); Task { await PodcastDownloads.shared.reconcile() }
        if follow && state.shows[feed.show.id]?.settings.notifications == true {
            await PodcastEpisodeNotifications.shared.requestPermissionIfNeeded()
        }
        return feed.show.id
    }
    /// Warm only metadata. Browsing never follows shows or downloads their audio.
    public func prefetch(_ result: PodcastDirectoryResult) async {
        guard prefetching.count < 3, !prefetching.contains(result.collectionID), !Task.isCancelled else { return }
        prefetching.insert(result.collectionID)
        defer { prefetching.remove(result.collectionID) }
        do {
            var url = result.feedURL
            if url == nil { url = try await PodcastDirectory().lookup([result.collectionID], country: state.settings.countryCode).first?.feedURL }
            try Task.checkCancellation()
            guard let url, !state.shows.values.contains(where: { $0.feedURL == url }) else { return }
            _ = try await feedClient.fetch(PodcastShow(feedURL: url, title: ""))
        } catch { /* Speculative failures are retried by an explicit open. */ }
    }
    public func refresh(showIDs: [String]? = nil, force: Bool = false, minimumInterval: TimeInterval = 900) async {
        // Drain a previous interrupted run before spending this run's time on feeds.
        if !Task.isCancelled { await PodcastEpisodeNotifications.shared.deliverPending(in: self) }
        let shows = showIDs.map { ids in ids.compactMap { state.shows[$0] } } ?? state.shows.values.filter(\.followed)
        let ids = PodcastPolicies.refreshOrder(shows)
        // Bound publisher traffic, but don't make every show wait for a slow feed.
        await withTaskGroup(of: Void.self) { group in
            var iterator = ids.makeIterator()
            for _ in 0..<3 { if let id = iterator.next() { group.addTask { await self.refreshShow(id, force: force, minimumInterval: minimumInterval) } } }
            while await group.next() != nil {
                if !Task.isCancelled, let id = iterator.next() { group.addTask { await self.refreshShow(id, force: force, minimumInterval: minimumInterval) } }
            }
        }
        if !Task.isCancelled { await PodcastEpisodeNotifications.shared.deliverPending(in: self) }
        if !Task.isCancelled { await PodcastDownloads.shared.reconcile() }
    }
    private func refreshShow(_ id: String, force: Bool, minimumInterval: TimeInterval) async {
        if let task = refreshTasks[id] { await task.value; return }
        guard !Task.isCancelled, let show = state.shows[id],
              show.id != ReaderPodcastSource.showID,
              ["http", "https"].contains(show.feedURL.scheme?.lowercased() ?? ""),
              force || Date().timeIntervalSince(show.lastRefreshAttempt ?? show.lastRefresh ?? .distantPast) >= minimumInterval else { return }
        refreshingShowIDs.insert(id); isRefreshing = true
        let task = Task { [self] in
            do {
                try Task.checkCancellation()
                try await requireStore().updateInBackground { $0.shows[id]?.lastRefreshAttempt = Date() }
                reloadState()
                let response = try await feedClient.fetch(show, force: force)
                if let feed = response.feed {
                    _ = try await requireStore().mergeInBackground(feed, existingID: id, etag: response.etag, lastModified: response.lastModified, recordNotifications: true)
                } else {
                    try await requireStore().updateInBackground { state in
                        state.shows[id]?.etag = response.etag; state.shows[id]?.lastModified = response.lastModified
                        state.shows[id]?.lastRefresh = Date(); state.shows[id]?.refreshError = nil
                    }
                }
                reloadState()
            } catch {
                if !Task.isCancelled {
                    try? edit { $0.shows[id]?.refreshError = error.localizedDescription }
                    report(error)
                }
            }
        }
        refreshTasks[id] = task
        await withTaskCancellationHandler(operation: { await task.value }, onCancel: { task.cancel() })
        refreshTasks[id] = nil; refreshingShowIDs.remove(id); isRefreshing = !refreshTasks.isEmpty
    }
    public func setFollowed(_ id: String, _ value: Bool) throws {
        try requireStore().follow(id, value); reloadState()
        Task {
            if value && state.shows[id]?.settings.notifications == true {
                await PodcastEpisodeNotifications.shared.requestPermissionIfNeeded()
            } else if !value { await PodcastEpisodeNotifications.shared.removeAlerts(for: id) }
            await PodcastDownloads.shared.reconcile()
        }
    }
    public func setNotifications(_ id: String, _ value: Bool) async throws {
        if value {
            guard try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) else {
                throw PodcastError("Enable notifications for Luna Music in Settings to receive new episode alerts.")
            }
        }
        try edit { state in
            state.shows[id]?.settings.notifications = value; state.shows[id]?.updatedAt = Date()
            if !value {
                let episodes = state.episodes
                state.pendingNotificationEpisodeIDs?.removeAll { episodes[$0]?.showID == id }
            }
        }
        if !value { await PodcastEpisodeNotifications.shared.removeAlerts(for: id) }
    }
}
