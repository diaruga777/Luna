import XCTest
import AVFoundation
import UserNotifications
@testable import LunaMusicCore
import LunaAudioPlayback
import LunaModels
import LunaStorage
@testable import LunaMusicUI
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

final class ReaderMusicRouteTests: XCTestCase {
    func testReaderRouteAcceptsOnlyValidSaveIDs() {
        let id = UUID()
        XCTAssertEqual(MusicLaunchRoute(url: URL(string: "lunamusic://reader?save=\(id)")!), .reader(id))
        XCTAssertEqual(MusicLaunchRoute(url: URL(string: "lunamusic://reader")!), .reader(nil))
        XCTAssertNil(MusicLaunchRoute(url: URL(string: "lunamusic://reader?save=bad")!))
        XCTAssertNil(MusicLaunchRoute(url: URL(string: "lunamusic://reader?save=\(id)&save=\(id)")!))
    }
}

@MainActor final class ReaderPodcastIntegrationTests: XCTestCase {
    private var root: URL!
    private var saves: SavesStore!
    private var library: PodcastLibraryController!
    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        saves = SavesStore(containerURL: root.appendingPathComponent("shared"))
        library = PodcastLibraryController(url: root.appendingPathComponent("podcasts/library.json"))
    }
    override func tearDown() async throws {
        saves = nil; library = nil
        try? FileManager.default.removeItem(at: root)
    }
    private func save(_ title: String = "A text save") -> SavedItem {
        let item = saves.insertImported([SavesStore.ImportedLink(urlString: "https://example.com/\(UUID())", isArchived: false)])[0].item
        return saves.saveContent(ArticleContent(title: title, blocks: [.init(kind: .paragraph, text: "Here is the complete readable text of an article.", links: [])]), for: item)
    }
    private func controller(_ render: @escaping (AudioScript, URL, @escaping (Double) -> Void) async throws -> Double) -> ReaderPodcastController {
        ReaderPodcastController(saves: saves, library: library, directory: root.appendingPathComponent("podcasts/ReaderAudio"), render: render)
    }
    func testBrowseRenderQueueReuseAndRestoreWithoutChangingReaderProgress() async throws {
        let item = save()
        _ = saves.insertImported([SavesStore.ImportedLink(urlString: "https://example.com/pending", isArchived: false)])
        var renders = 0
        let reader = controller { script, url, progress in
            renders += 1; XCTAssertFalse(script.spokenBlocks.isEmpty)
            try Data("local audio".utf8).write(to: url); progress(1); return 12
        }
        let items = await reader.items()
        XCTAssertEqual(items.map(\.id), [item.id])
        let episode = try await reader.enqueue(item.id)
        let repeated = try await reader.enqueue(item.id)
        XCTAssertEqual(episode.id, repeated.id); XCTAssertEqual(renders, 1)
        XCTAssertEqual(library.state.queue, [episode.id]); XCTAssertEqual(library.state.currentEpisodeID, nil)
        XCTAssertEqual(saves.item(withID: item.id)?.readState, .unopened)
        XCTAssertEqual(episode.duration, 12); XCTAssertTrue(episode.mediaURL.isFileURL)
        let restored = PodcastLibraryController(url: try library.requireStore().url)
        XCTAssertEqual(restored.state.queue, [episode.id]); XCTAssertEqual(restored.state.episodes[episode.id], episode)
        XCTAssertTrue(FileManager.default.fileExists(atPath: episode.mediaURL.path))
        XCTAssertTrue(PodcastDownloadPlan(state: library.state, sizes: [:]).episodeIDs.isEmpty)
    }
    func testConcurrentAddsShareOneRenderAndPlayNextPreservesPodcastOrder() async throws {
        let item = save()
        var renders = 0
        let reader = controller { _, url, _ in
            renders += 1; try await Task.sleep(for: .milliseconds(40))
            try Data("audio".utf8).write(to: url); return 10
        }
        let show = PodcastShow(feedURL: URL(string: "https://example.com/feed")!, title: "Podcast")
        let podcast = PodcastEpisode(showID: show.id, guid: "one", title: "One", publishedAt: Date(), mediaURL: URL(string: "https://example.com/audio.mp3")!)
        try library.edit { $0.shows[show.id] = show; $0.episodes[podcast.id] = podcast; $0.queue = [podcast.id] }
        async let a = reader.enqueue(item.id, next: true)
        async let b = reader.enqueue(item.id, next: true)
        let (first, second) = try await (a, b)
        XCTAssertEqual(first.id, second.id); XCTAssertEqual(renders, 1)
        XCTAssertEqual(library.state.queue, [first.id, podcast.id]); XCTAssertTrue(reader.progress.isEmpty)
    }
    func testDifferentSavesKeepSelectionOrderAcrossSlowGeneration() async throws {
        let first = save("First"), second = save("Second")
        var count = 0
        let reader = controller { _, url, _ in
            count += 1
            if count == 1 { try await Task.sleep(for: .milliseconds(80)) }
            try Data("audio".utf8).write(to: url); return 5
        }
        let a = Task { try await reader.enqueue(first.id) }
        await Task.yield()
        let b = Task { try await reader.enqueue(second.id) }
        let firstEpisode = try await a.value, secondEpisode = try await b.value
        XCTAssertEqual(library.state.queue, [firstEpisode.id, secondEpisode.id])
    }
    func testFailedRenderDoesNotQueuePartialAudioAndCanRetry() async throws {
        let item = save()
        var fail = true
        let reader = controller { _, url, _ in
            try Data("partial".utf8).write(to: url)
            if fail { throw PodcastError("A test failure") }; return 10
        }
        do { _ = try await reader.enqueue(item.id); XCTFail("Expected failure") } catch {}
        XCTAssertTrue(library.state.queue.isEmpty); XCTAssertTrue(library.state.episodes.isEmpty)
        let files = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("podcasts/ReaderAudio").path)
        XCTAssertTrue(files.isEmpty); XCTAssertTrue(reader.progress.isEmpty)
        fail = false
        let episode = try await reader.enqueue(item.id)
        XCTAssertEqual(library.state.queue, [episode.id])
        try FileManager.default.removeItem(at: episode.mediaURL)
        _ = try await reader.enqueue(item.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: episode.mediaURL.path))
    }
    func testMissingSaveFailsWithoutCallingRenderer() async throws {
        let reader = controller { _, _, _ in XCTFail("No render expected"); return 0 }
        do { _ = try await reader.enqueue(UUID()); XCTFail("Expected missing save error") } catch {}
        XCTAssertTrue(library.state.queue.isEmpty)
    }
    func testRealSpeechPlaysAfterPodcastInTheSameQueue() async throws {
        let item = save("Readout Playback")
        let reader = ReaderPodcastController(saves: saves, library: library, directory: root.appendingPathComponent("podcasts/ReaderAudio"))
        let readout = try await reader.enqueue(item.id)
        XCTAssertGreaterThan(readout.duration, 0.5)
        let audioTracks = try await AVURLAsset(url: readout.mediaURL).loadTracks(withMediaType: .audio)
        XCTAssertFalse(audioTracks.isEmpty)
        let show = PodcastShow(feedURL: URL(string: "https://example.com/feed")!, title: "A podcast")
        var podcast = PodcastEpisode(showID: show.id, guid: "local-fixture", title: "Podcast fixture", publishedAt: Date(), mediaURL: readout.mediaURL)
        podcast.duration = readout.duration
        try library.edit { $0.shows[show.id] = show; $0.episodes[podcast.id] = podcast }
        let downloads = PodcastDownloads(directory: root.appendingPathComponent("downloads"), library: library, sessionConfiguration: .ephemeral)
        let playback = PodcastPlaybackController(library: library, downloads: downloads)
        defer { playback.pause(); downloads.stop() }
        try await playback.play(podcast)
        try await waitFor { playback.isPlaying && playback.position > 0.1 }
        playback.seek(to: max(0, readout.duration - 0.3))
        try await waitFor { playback.currentEpisode?.id == readout.id && playback.isPlaying && playback.position > 0.1 }
        XCTAssertTrue(library.state.queue.isEmpty)
        XCTAssertTrue(library.state.progress[podcast.id]?.listened == true)
        XCTAssertNil(playback.errorMessage)
    }
    private func waitFor(_ condition: () -> Bool) async throws {
        for _ in 0..<400 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("Timed out waiting for real readout playback")
        throw PodcastError("Playback timed out")
    }
    func testRemovingReadoutDeletesOnlyMusicsCopyAndAllowsRegeneration() async throws {
        let item = save()
        var renders = 0
        let reader = controller { _, url, _ in renders += 1; try Data("audio".utf8).write(to: url); return 5 }
        let episode = try await reader.enqueue(item.id)
        try reader.removeReadout(episode)
        XCTAssertFalse(FileManager.default.fileExists(atPath: episode.mediaURL.path))
        XCTAssertNil(library.state.episodes[episode.id]); XCTAssertTrue(library.state.queue.isEmpty)
        XCTAssertNotNil(saves.content(for: item))
        _ = try await reader.enqueue(item.id)
        XCTAssertEqual(renders, 2)
    }
    func testReaderNavigationSelectsPodcastsWithoutStartingPlayback() {
        let navigation = MediaLibraryNavigationController()
        navigation.loadViewIfNeeded()
        navigation.openReader(saveID: nil)
        XCTAssertEqual(navigation.surface, .podcasts)
        XCTAssertTrue(navigation.topViewController is ReaderPodcastsViewController)
        XCTAssertEqual(navigation.viewControllers.count, 2)
    }
}
