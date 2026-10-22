import XCTest
import LunaPodcastCore

final class PodcastNotificationTests: XCTestCase {
    private func show(_ id: String) -> PodcastShow {
        PodcastShow(feedURL: URL(string: "https://example.com/\(id).xml")!, title: id, id: id)
    }
    private func episode(_ id: String, show: PodcastShow) -> PodcastEpisode {
        PodcastEpisode(showID: show.id, guid: id, title: id, publishedAt: Date(), mediaURL: URL(string: "https://example.com/\(id).mp3")!)
    }
    func testNewShowsDefaultToNotificationsAndOldOffPreferenceSurvives() throws {
        XCTAssertTrue(PodcastShowSettings().notifications)
        var original = show("old")
        original.settings.notifications = false
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        json.removeValue(forKey: "lastRefreshAttempt")
        let decoded = try JSONDecoder().decode(PodcastShow.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertFalse(decoded.settings.notifications)
        XCTAssertNil(decoded.lastRefreshAttempt)
        let library = try JSONDecoder().decode(PodcastLibraryState.self, from: JSONEncoder().encode(PodcastLibraryState()))
        XCTAssertNil(library.pendingNotificationEpisodeIDs)
    }
    func testLeastRecentlyAttemptedIncludingFailuresRunsFirstAfterInterruption() {
        var a = show("a"), b = show("b"), c = show("c"), d = show("d")
        a.lastRefresh = Date(timeIntervalSince1970: 100)
        b.lastRefresh = Date(timeIntervalSince1970: 200)
        c.lastRefresh = Date(timeIntervalSince1970: 300)
        d.lastRefresh = nil
        XCTAssertEqual(PodcastPolicies.refreshOrder([c, b, a, d]), ["d", "a", "b", "c"])
        // d and a were attempted before expiration; b/c must get their turn next.
        d.lastRefreshAttempt = Date(timeIntervalSince1970: 400)
        a.lastRefreshAttempt = Date(timeIntervalSince1970: 401)
        a.refreshError = "Offline"
        XCTAssertEqual(PodcastPolicies.refreshOrder([a, b, c, d]), ["b", "c", "d", "a"])
        b.lastRefresh = c.lastRefresh
        XCTAssertEqual(PodcastPolicies.refreshOrder([c, b]), ["b", "c"])
    }
    @MainActor func testNewEpisodeOutboxIsAtomicDurableAndDeduplicated() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try PodcastStore(url: directory.appendingPathComponent("library.json"))
        let podcast = show("show")
        let old = episode("old", show: podcast), new = episode("new", show: podcast), other = episode("other", show: podcast)
        _ = try await store.mergeInBackground(.init(show: podcast, episodes: [old]), follow: true, recordNotifications: true)
        XCTAssertTrue(store.state.pendingNotificationEpisodeIDs?.isEmpty ?? true, "Initial archive must not alert")
        try store.update { $0.shows[podcast.id]?.lastRefreshAttempt = Date(timeIntervalSince1970: 123) }
        _ = try await store.mergeInBackground(.init(show: podcast, episodes: [old, new, other]), recordNotifications: true)
        XCTAssertEqual(Set(store.state.pendingNotificationEpisodeIDs ?? []), [new.id, other.id])
        XCTAssertEqual(store.state.shows[podcast.id]?.lastRefreshAttempt, Date(timeIntervalSince1970: 123))
        let restored = try PodcastStore(url: store.url)
        XCTAssertEqual(restored.state.pendingNotificationEpisodeIDs, store.state.pendingNotificationEpisodeIDs, "Expiration after merge must retain alerts")
        _ = try await restored.mergeInBackground(.init(show: podcast, episodes: [old, new, other]), recordNotifications: true)
        XCTAssertEqual(restored.state.pendingNotificationEpisodeIDs?.count, 2, "Repeated feed must not duplicate alerts")
        try restored.follow(podcast.id, false)
        XCTAssertEqual(restored.state.pendingNotificationEpisodeIDs, [], "Unfollow must discard undelivered alerts before a later refollow")
    }
    @MainActor func testMuteAndUnfollowDuringFetchPreventAlertsAndDoNotReplayArchive() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try PodcastStore(url: directory.appendingPathComponent("library.json"))
        let podcast = show("show")
        _ = try await store.mergeInBackground(.init(show: podcast, episodes: []), follow: true)
        let muted = episode("muted", show: podcast), unfollowed = episode("unfollowed", show: podcast)
        try store.update { $0.shows[podcast.id]?.settings.notifications = false }
        _ = try await store.mergeInBackground(.init(show: podcast, episodes: [muted]), recordNotifications: true)
        XCTAssertTrue(store.state.pendingNotificationEpisodeIDs?.isEmpty ?? true)
        try store.update { $0.shows[podcast.id]?.settings.notifications = true }
        try store.follow(podcast.id, false)
        _ = try await store.mergeInBackground(.init(show: podcast, episodes: [muted, unfollowed]), recordNotifications: true)
        XCTAssertTrue(store.state.pendingNotificationEpisodeIDs?.isEmpty ?? true)
        try store.follow(podcast.id, true)
        _ = try await store.mergeInBackground(.init(show: podcast, episodes: [muted, unfollowed]), recordNotifications: true)
        XCTAssertTrue(store.state.pendingNotificationEpisodeIDs?.isEmpty ?? true)
    }
    func testCloudSettingsMergeKeepsDeviceCheckOrderAndOutbox() {
        var local = PodcastLibraryState(), remote = PodcastLibraryState()
        var podcast = show("show")
        podcast.lastRefreshAttempt = Date(timeIntervalSince1970: 100)
        podcast.updatedAt = Date(timeIntervalSince1970: 200)
        local.shows[podcast.id] = podcast
        local.pendingNotificationEpisodeIDs = ["local-alert"]
        podcast.lastRefreshAttempt = Date(timeIntervalSince1970: 900)
        podcast.updatedAt = Date(timeIntervalSince1970: 1000)
        podcast.settings.notifications = false
        remote.shows[podcast.id] = podcast
        remote.pendingNotificationEpisodeIDs = ["remote-alert"]
        let merged = PodcastLibraryMerge.merge(local: local, remote: remote)
        XCTAssertEqual(merged.shows[podcast.id]?.lastRefreshAttempt, Date(timeIntervalSince1970: 100))
        XCTAssertEqual(merged.pendingNotificationEpisodeIDs, ["local-alert"])
        XCTAssertFalse(merged.shows[podcast.id]!.settings.notifications)
    }
}
