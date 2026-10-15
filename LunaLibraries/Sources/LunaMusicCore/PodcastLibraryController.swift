import Foundation
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
        do { store = try PodcastStore(url: url); state = store!.state }
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
            if follow { try requireStore().follow(existing.id, true) }
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
    public func refresh(showIDs: [String]? = nil, force: Bool = false) async {
        let ids = showIDs ?? state.shows.values.filter(\.followed).map(\.id)
        // Bound publisher traffic, but don't make every show wait for a slow feed.
        await withTaskGroup(of: Void.self) { group in
            var iterator = ids.makeIterator()
            for _ in 0..<3 { if let id = iterator.next() { group.addTask { await self.refreshShow(id, force: force) } } }
            while await group.next() != nil {
                if !Task.isCancelled, let id = iterator.next() { group.addTask { await self.refreshShow(id, force: force) } }
            }
        }
        await PodcastDownloads.shared.reconcile()
    }
    private func refreshShow(_ id: String, force: Bool) async {
        if let task = refreshTasks[id] { await task.value; return }
        guard let show = state.shows[id], force || Date().timeIntervalSince(show.lastRefresh ?? .distantPast) >= 900 else { return }
        refreshingShowIDs.insert(id); isRefreshing = true
        let task = Task { [self] in
            do {
                let response = try await feedClient.fetch(show, force: force)
                var newIDs: [String] = []
                if let feed = response.feed {
                    newIDs = try await requireStore().mergeInBackground(feed, existingID: id, etag: response.etag, lastModified: response.lastModified)
                } else {
                    try await requireStore().updateInBackground { state in
                        state.shows[id]?.etag = response.etag; state.shows[id]?.lastModified = response.lastModified
                        state.shows[id]?.lastRefresh = Date(); state.shows[id]?.refreshError = nil
                    }
                }
                reloadState()
                if show.followed && show.settings.notifications && show.lastRefresh != nil && !newIDs.isEmpty { await notify(show: show, ids: newIDs) }
            } catch {
                try? edit { $0.shows[id]?.refreshError = error.localizedDescription }
                report(error)
            }
        }
        refreshTasks[id] = task
        await task.value
        refreshTasks[id] = nil; refreshingShowIDs.remove(id); isRefreshing = !refreshTasks.isEmpty
    }
    public func setFollowed(_ id: String, _ value: Bool) throws {
        try requireStore().follow(id, value); reloadState()
        Task { await PodcastDownloads.shared.reconcile() }
    }
    public func setNotifications(_ id: String, _ value: Bool) async throws {
        if value {
            guard try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) else {
                throw PodcastError("Enable notifications for Luna Music in Settings to receive new episode alerts.")
            }
        }
        try edit { $0.shows[id]?.settings.notifications = value; $0.shows[id]?.updatedAt = Date() }
    }
    private func notify(show: PodcastShow, ids: [String]) async {
        let episodes = ids.compactMap { state.episodes[$0] }
        guard let latest = PodcastPolicies.ordered(episodes, newestFirst: true).first else { return }
        let content = UNMutableNotificationContent(); content.title = show.title
        content.body = ids.count == 1 ? latest.title : "\(ids.count) new episodes, including \(latest.title)"
        content.sound = .default; content.userInfo = ["podcastEpisodeID": latest.id]
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "podcast.\(show.id).\(latest.id)", content: content, trigger: nil))
    }
}
