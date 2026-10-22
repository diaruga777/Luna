import XCTest
import UserNotifications
import LunaMusicCore
import LunaPodcastCore
@testable import LunaMusicApp

final class MusicLaunchRouteTests: XCTestCase {
    func testQueueDeepLinkOpensQueue() {
        XCTAssertEqual(MusicLaunchRoute(url: URL(string: "lunamusic://queue")!), .queue)
    }
    func testSearchAndLibraryLinks() {
        for path in ["search", "library"] {
            XCTAssertEqual(MusicLaunchRoute(url: URL(string: "lunamusic://\(path)")!), .search)
        }
    }
    func testUnrelatedURLsAreIgnored() {
        XCTAssertNil(MusicLaunchRoute(url: URL(string: "https://queue")!))
        XCTAssertNil(MusicLaunchRoute(url: URL(string: "lunamusic://invalid")!))
    }
}

final class PodcastEpisodeNotificationTests: XCTestCase {
    @MainActor func testSystemDeliveryIncludesArtworkAndDrainsTheOutboxOnce() async throws {
        guard let base = ProcessInfo.processInfo.environment["LUNA_PODCAST_FIXTURE_URL"], let fixture = URL(string: base) else {
            throw XCTSkip("Run with the local podcast fixture server.")
        }
        let center = UNUserNotificationCenter.current()
        let status = await center.notificationSettings().authorizationStatus
        guard status == .authorized || status == .provisional else { throw XCTSkip("Allow notifications in the simulator first.") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = PodcastLibraryController(url: directory.appendingPathComponent("library.json"))
        var show = PodcastShow(feedURL: fixture.appending(queryItems: [.init(name: "delivery", value: UUID().uuidString)]), title: "Notification Fixture")
        show.artworkURL = fixture.deletingLastPathComponent().appendingPathComponent("artwork.png")
        show.settings.automaticDownloadLimit = 0
        let episode = PodcastEpisode(showID: show.id, guid: "new", title: "New Episode", publishedAt: Date(), mediaURL: fixture.deletingLastPathComponent().appendingPathComponent("one.wav"))
        let store = try library.requireStore()
        _ = try await store.mergeInBackground(.init(show: show, episodes: []), follow: true)
        _ = try await store.mergeInBackground(.init(show: show, episodes: [episode]), recordNotifications: true)
        library.reloadState()
        await PodcastEpisodeNotifications.shared.deliverPending(in: library)
        XCTAssertEqual(library.state.pendingNotificationEpisodeIDs, [])
        var notifications: [UNNotification] = []
        for _ in 0..<40 {
            notifications = await center.deliveredNotifications().filter { $0.request.content.userInfo["podcastEpisodeID"] as? String == episode.id }
            if !notifications.isEmpty { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let notification = try XCTUnwrap(notifications.first)
        XCTAssertEqual(notification.request.content.title, "New Notification Fixture")
        XCTAssertEqual(notification.request.content.body, "New Episode")
        XCTAssertEqual(notification.request.content.attachments.count, 1)
        XCTAssertEqual(notification.request.content.attachments.first?.type, "public.jpeg")
        await PodcastEpisodeNotifications.shared.deliverPending(in: library)
        notifications = await center.deliveredNotifications().filter { $0.request.content.userInfo["podcastEpisodeID"] as? String == episode.id }
        XCTAssertEqual(notifications.count, 1)
        await PodcastEpisodeNotifications.shared.removeAlerts(for: show.id)
    }
    @MainActor func testNotificationCategoryHasBothBackgroundQueueActions() async throws {
        PodcastEpisodeNotifications.shared.register()
        let categories = await UNUserNotificationCenter.current().notificationCategories()
        let category = try XCTUnwrap(categories.first { $0.identifier == PodcastEpisodeNotifications.categoryID })
        XCTAssertEqual(category.actions.map(\.title), ["Add to Queue", "Play Next"])
        XCTAssertEqual(category.actions.map(\.identifier), [PodcastEpisodeNotifications.addToQueueID, PodcastEpisodeNotifications.playNextID])
        XCTAssertTrue(category.actions.allSatisfy { !$0.options.contains(.foreground) })
    }
    @MainActor func testExactNotificationCopyAndEpisodeRoute() {
        let show = PodcastShow(feedURL: URL(string: "https://example.com/feed")!, title: "A Podcast")
        let episode = PodcastEpisode(showID: show.id, guid: "new", title: "An Episode", publishedAt: Date(), mediaURL: URL(string: "https://example.com/audio.mp3")!)
        let content = PodcastEpisodeNotifications.content(show: show, episode: episode)
        XCTAssertEqual(content.title, "New A Podcast")
        XCTAssertEqual(content.body, "An Episode")
        XCTAssertEqual(content.userInfo["podcastEpisodeID"] as? String, episode.id)
        XCTAssertEqual(content.categoryIdentifier, PodcastEpisodeNotifications.categoryID)
        XCTAssertEqual(PodcastEpisodeNotifications.action(for: UNNotificationDefaultActionIdentifier), .open)
        XCTAssertEqual(PodcastEpisodeNotifications.action(for: UNNotificationDismissActionIdentifier), .ignore)
        XCTAssertEqual(PodcastEpisodeNotifications.action(for: "unknown"), .ignore)
    }
    @MainActor func testMutingClearsInterruptedNotificationsImmediately() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = PodcastLibraryController(url: directory.appendingPathComponent("library.json"))
        var show = PodcastShow(feedURL: URL(string: "https://example.com/feed")!, title: "A Podcast")
        show.followed = true
        let episode = PodcastEpisode(showID: show.id, guid: "new", title: "An Episode", publishedAt: Date(), mediaURL: URL(string: "https://example.com/audio.mp3")!)
        try library.edit {
            $0.shows[show.id] = show; $0.episodes[episode.id] = episode
            $0.pendingNotificationEpisodeIDs = [episode.id]
        }
        try await library.setNotifications(show.id, false)
        XCTAssertFalse(library.state.shows[show.id]!.settings.notifications)
        XCTAssertEqual(library.state.pendingNotificationEpisodeIDs, [])
        XCTAssertFalse(try PodcastStore(url: library.requireStore().url).state.shows[show.id]!.settings.notifications)
    }
    @MainActor func testNotificationActionsUseEpisodeMenuQueueSemantics() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = PodcastLibraryController(url: directory.appendingPathComponent("library.json"))
        let episodes = (0..<4).map { PodcastEpisode(showID: "show", guid: "\($0)", title: "\($0)", publishedAt: Date(), mediaURL: URL(string: "https://example.com/\($0).mp3")!) }
        try library.edit {
            $0.episodes = Dictionary(uniqueKeysWithValues: episodes.map { ($0.id, $0) })
            $0.currentEpisodeID = episodes[0].id
            $0.queue = [episodes[1].id]
        }
        XCTAssertEqual(PodcastEpisodeNotifications.action(for: PodcastEpisodeNotifications.addToQueueID), .addToQueue)
        try PodcastEpisodeNotifications.shared.enqueue(episodes[2].id, next: false, in: library)
        XCTAssertEqual(library.state.queue, [episodes[1].id, episodes[2].id])
        XCTAssertEqual(PodcastEpisodeNotifications.action(for: PodcastEpisodeNotifications.playNextID), .playNext)
        try PodcastEpisodeNotifications.shared.enqueue(episodes[3].id, next: true, in: library)
        XCTAssertEqual(library.state.queue, [episodes[3].id, episodes[1].id, episodes[2].id])
        try PodcastEpisodeNotifications.shared.enqueue(episodes[2].id, next: true, in: library)
        XCTAssertEqual(library.state.queue, [episodes[2].id, episodes[3].id, episodes[1].id])
        XCTAssertEqual(library.state.currentEpisodeID, episodes[0].id, "Actions must not start or replace playback")
        XCTAssertEqual(try PodcastStore(url: library.requireStore().url).state.queue, library.state.queue)
    }
}
