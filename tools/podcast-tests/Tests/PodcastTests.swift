import XCTest
import LunaPodcastCore

final class PodcastTests: XCTestCase {
    func episode(_ name: String, show: String, day: Int) -> PodcastEpisode {
        PodcastEpisode(showID: show, guid: name, title: name, publishedAt: Date(timeIntervalSince1970: Double(day) * 86400), mediaURL: URL(string: "https://example.com/\(name).mp3")!)
    }
    func sample() -> (PodcastLibraryState, [PodcastEpisode]) {
        var state = PodcastLibraryState()
        var a = PodcastShow(feedURL: URL(string: "https://example.com/a")!, title: "A", id: "a"); a.followed = true
        var b = PodcastShow(feedURL: URL(string: "https://example.com/b")!, title: "B", id: "b"); b.followed = true
        state.shows = ["a": a, "b": b]
        let episodes = [episode("A", show: "a", day: 1), episode("B", show: "a", day: 3), episode("C", show: "a", day: 5), episode("D", show: "a", day: 7),
                        episode("1", show: "b", day: 2), episode("2", show: "b", day: 4), episode("3", show: "b", day: 6), episode("4", show: "b", day: 8)]
        state.episodes = Dictionary(uniqueKeysWithValues: episodes.map { ($0.id, $0) })
        state.lastPlayedEpisodeID = episodes[6].id
        state.cursors = ["a": .init(episode: episodes[1]), "b": .init(episode: episodes[6])]
        for episode in [episodes[1], episodes[6]] { var progress = PodcastEpisodeState(); progress.listened = true; state.progress[episode.id] = progress }
        return (state, episodes)
    }
    func testExactResumeAndUserExample() {
        var (state, episodes) = sample()
        state.progress[episodes[6].id]?.listened = false
        XCTAssertEqual(PodcastPolicies.resumeDecision(state, downloadedIDs: []), .resume(episodes[6].id))
        state.progress[episodes[6].id]?.listened = true
        state.naturallyExhaustedQueue = true
        XCTAssertEqual(PodcastPolicies.resumeDecision(state, downloadedIDs: Set(episodes.map(\.id))), .start(episodes[2].id))
        state.cursors["a"] = .init(episode: episodes[3]); state.cursors["b"] = .init(episode: episodes[7])
        for index in [3, 7] { var progress = PodcastEpisodeState(); progress.listened = true; state.progress[episodes[index].id] = progress }
        XCTAssertEqual(PodcastPolicies.resumeDecision(state, downloadedIDs: Set(episodes.map(\.id))), .nothing)
    }
    func testResumeKeepsPendingCurrentAfterLastPlayedEpisodeCompleted() {
        var (state, episodes) = sample()
        state.currentEpisodeID = episodes[7].id
        state.queue = [episodes[2].id]
        XCTAssertEqual(PodcastPolicies.resumeDecision(state, downloadedIDs: Set(episodes.map(\.id))), .resume(episodes[7].id))
        state.progress[episodes[6].id]?.listened = false
        XCTAssertEqual(PodcastPolicies.resumeDecision(state, downloadedIDs: Set(episodes.map(\.id))), .resume(episodes[6].id), "Preparation alone must not replace unfinished listening history")
    }
    func testOlderBacklogIsNotResurrectedAndNoHistoryIsNoOp() {
        var (state, episodes) = sample(); state.naturallyExhaustedQueue = true
        state.cursors["a"] = .init(episode: episodes[3]); state.cursors["b"] = .init(episode: episodes[7])
        XCTAssertEqual(PodcastPolicies.resumeDecision(state, downloadedIDs: Set(episodes.map(\.id))), .nothing)
        state.lastPlayedEpisodeID = nil
        XCTAssertEqual(PodcastPolicies.resumeDecision(state, downloadedIDs: Set(episodes.map(\.id))), .nothing)
    }
    func testCompletedHistoryUsesOnlyDownloadedNewerEpisodesEvenWithoutNaturalExhaustion() {
        var (state, episodes) = sample()
        state.currentEpisodeID = state.lastPlayedEpisodeID
        let original = state
        // A/0 and B/0 are downloaded old backlog; A/2 is eligible but remote.
        let downloaded = Set([episodes[0].id, episodes[4].id, episodes[3].id, episodes[7].id])
        XCTAssertEqual(PodcastPolicies.resumeDecision(state, downloadedIDs: downloaded), .start(episodes[3].id))
        XCTAssertEqual(state, original, "Choosing a replacement must preserve played history")
        XCTAssertEqual(PodcastPolicies.resumeDecision(state, downloadedIDs: [episodes[0].id, episodes[4].id]), .nothing)
        XCTAssertEqual(PodcastPolicies.resumeDecision(state, downloadedIDs: []), .nothing)
        state.naturallyExhaustedQueue = true
        XCTAssertEqual(PodcastPolicies.resumeDecision(state, downloadedIDs: downloaded), .start(episodes[3].id))
    }
    func testCompletedStagedCurrentIsNotReplayedAndExplicitQueueStillWins() {
        var (state, episodes) = sample()
        state.currentEpisodeID = episodes[1].id // Also completed.
        XCTAssertEqual(PodcastPolicies.resumeDecision(state, downloadedIDs: []), .nothing)
        state.queue = [episodes[0].id]
        XCTAssertEqual(PodcastPolicies.resumeDecision(state, downloadedIDs: []), .start(episodes[0].id))
    }
    func testUnstartedAutomaticDownloadsExpireAfterOneWeek() {
        var (state, episodes) = sample()
        let id = episodes[0].id
        let created = Date(timeIntervalSince1970: 1_000_000)
        let expiry = created.addingTimeInterval(7 * 86400)
        func expired(manual: Bool = false, now: Date = expiry) -> Bool {
            PodcastPolicies.isExpiredAutomaticDownload(episodeID: id, manual: manual, createdAt: created, state: state, now: now)
        }
        XCTAssertFalse(expired(now: expiry.addingTimeInterval(-1)))
        XCTAssertTrue(expired())
        XCTAssertFalse(expired(manual: true))
        var progress = PodcastEpisodeState()
        progress.position = 1; state.progress[id] = progress
        XCTAssertFalse(expired())
        progress.position = 0; progress.lastPlayedAt = created; state.progress[id] = progress
        XCTAssertFalse(expired(), "Started episodes remain protected even after rewinding to zero")
        progress.lastPlayedAt = nil; progress.listened = true; state.progress[id] = progress
        XCTAssertFalse(expired(), "Played episodes use their separate retention policy")
    }
    func testGestureBoundariesAndNoDestination() {
        var gesture = MediaSkipGesture()
        XCTAssertEqual(gesture.receive(.backward, at: 10, canSwitch: true), [.backward])
        // A long back operation gets a full second starting at completion.
        gesture.backwardCompleted(at: 20)
        XCTAssertEqual(gesture.receive(.forward, at: 21, canSwitch: true), [.switchQueue])
        XCTAssertEqual(gesture.receive(.forward, at: 21, canSwitch: true), [.forward])
        XCTAssertEqual(gesture.receive(.backward, at: 30, canSwitch: true), [.backward])
        gesture.backwardCompleted(at: 35)
        XCTAssertEqual(gesture.receive(.forward, at: 36.001, canSwitch: true), [.forward])
        XCTAssertEqual(gesture.receive(.backward, at: 40, canSwitch: false), [.backward])
        gesture.backwardCompleted(at: 40)
        XCTAssertEqual(gesture.receive(.forward, at: 40.5, canSwitch: false), [.forward])
        XCTAssertEqual(gesture.receive(.backward, at: 50, canSwitch: true), [.backward])
        XCTAssertEqual(gesture.receive(.forward, at: 50.1, canSwitch: true), [.forward], "An unfinished back cannot arm a switch")
        gesture.backwardCompleted(at: 60)
        XCTAssertEqual(gesture.receive(.forward, at: 59, canSwitch: true), [.forward])
    }
    @MainActor func testDurabilityNaturalEndAndManualMarking() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try PodcastStore(url: directory.appendingPathComponent("library.json"))
        let (state, episodes) = sample(); try store.update { $0 = state }
        try store.recordPlaybackStarted(episodes[1].id)
        try store.recordPosition(episodes[1].id, position: 123.5)
        try store.markListened(episodes[1].id, true)
        XCTAssertEqual(PodcastPolicies.resumeDecision(store.state, downloadedIDs: Set(episodes.map(\.id))), .start(episodes[2].id))
        try store.enqueue(episodes[2].id, next: false)
        XCTAssertEqual(try store.finishNaturally(episodes[1].id), episodes[2].id)
        XCTAssertFalse(store.state.naturallyExhaustedQueue)
        try store.recordPlaybackStarted(episodes[2].id)
        XCTAssertNil(try store.finishNaturally(episodes[2].id))
        XCTAssertTrue(store.state.naturallyExhaustedQueue)
        XCTAssertEqual(try PodcastStore(url: store.url).state, store.state)
    }
    @MainActor func testResumedEpisodeStaysQueuedUntilCompletionAndDoesNotPlayTwice() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try PodcastStore(url: directory.appendingPathComponent("library.json"))
        let (state, episodes) = sample()
        for queue in [[episodes[0].id, episodes[1].id, episodes[2].id],
                      [episodes[1].id, episodes[0].id, episodes[2].id]] {
            try store.update { $0 = state; $0.queue = queue }
            try store.recordPlaybackStarted(episodes[0].id)
            XCTAssertEqual(store.state.queue, queue)
            XCTAssertEqual(try store.finishNaturally(episodes[0].id), episodes[1].id)
            XCTAssertEqual(store.state.queue, [episodes[2].id])
            try store.recordPlaybackStarted(episodes[1].id)
            XCTAssertEqual(try store.finishNaturally(episodes[1].id), episodes[2].id)
            XCTAssertTrue(store.state.queue.isEmpty)
        }
    }
    func testRSSNamespacesAndDuplicateGUIDs() throws {
        let xml = """
        <rss xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd" xmlns:podcast="https://podcastindex.org/namespace/1.0" xmlns:psc="http://podlove.org/simple-chapters"><channel><title>Test &amp; Show</title><itunes:author>Author</itunes:author><itunes:type>serial</itunes:type><itunes:image href="https://example.com/art.jpg"/>
        <item><guid>one</guid><title>Episode</title><description><![CDATA[<p>Hello</p>]]></description><pubDate>Mon, 05 Oct 2026 12:00:00 +0000</pubDate><itunes:duration>1:02:03</itunes:duration><enclosure url="https://example.com/a.mp3" type="audio/mpeg" length="500"/><podcast:transcript url="https://example.com/a.vtt" type="text/vtt"/><psc:chapters><psc:chapter start="00:10" title="Opening"/></psc:chapters></item>
        <item><guid>one</guid><title>Duplicate</title><enclosure url="https://example.com/b.mp3" type="audio/mpeg"/></item><item><title>No media</title></item></channel></rss>
        """
        let feed = try PodcastFeed.parse(Data(xml.utf8), url: URL(string: "https://example.com/rss")!)
        XCTAssertEqual(feed.show.title, "Test & Show"); XCTAssertTrue(feed.show.serial)
        XCTAssertEqual(feed.episodes.count, 1); XCTAssertEqual(feed.episodes[0].duration, 3723)
        XCTAssertEqual(feed.episodes[0].summary, "<p>Hello</p>")
        XCTAssertEqual(feed.episodes[0].chapters.first?.start, 10)
        XCTAssertEqual(feed.episodes[0].transcripts.count, 1)
    }
    func testTranscriptAndOPML() throws {
        let text = "WEBVTT\n\n00:00:01.000 --> 00:00:03.500 align:start\nHello\nworld\n\n2\n00:00:05,000 --> 00:00:07,000\nSecond"
        let cues = try PodcastTranscript.parse(Data(text.utf8), type: "text/vtt")
        XCTAssertEqual(cues.count, 2); XCTAssertEqual(cues[0].text, "Hello\nworld"); XCTAssertEqual(cues[1].start, 5)
        var show = PodcastShow(feedURL: URL(string: "https://example.com/?a=1&b=2")!, title: "A & B"); show.followed = true
        XCTAssertEqual(try PodcastOPML.urls(PodcastOPML.export([show])), [show.feedURL])
    }
    func testAutomaticDownloadsRespectsSuppressionAndStations() {
        var (state, episodes) = sample()
        XCTAssertEqual(PodcastPolicies.automaticDownloads(state), Set([episodes[3].id, episodes[7].id]))
        var progress = PodcastEpisodeState(); progress.suppressAutomaticDownload = true; state.progress[episodes[3].id] = progress
        XCTAssertFalse(PodcastPolicies.automaticDownloads(state).contains(episodes[3].id))
        var station = PodcastStation(name: "Morning"); station.allShows = true; station.episodesPerShow = 1
        XCTAssertEqual(PodcastPolicies.stationEpisodes(station, state: state).map(\.title), ["A", "1"])
    }
}

extension PodcastTests {
    func testNeverPlayedFollowedShowAndUnfollowedExclusion() {
        var (state, episodes) = sample(); state.naturallyExhaustedQueue = true
        state.cursors["a"] = nil
        XCTAssertEqual(PodcastPolicies.resumeDecision(state, downloadedIDs: Set(episodes.map(\.id))), .start(episodes[0].id))
        state.shows["a"]?.followed = false
        XCTAssertEqual(PodcastPolicies.resumeDecision(state, downloadedIDs: Set(episodes.map(\.id))), .start(episodes[7].id))
    }
    func testQueueAddedAfterExhaustionWinsOverSubscriptions() {
        var (state, episodes) = sample(); state.naturallyExhaustedQueue = true; state.queue = [episodes[3].id]
        XCTAssertEqual(PodcastPolicies.resumeDecision(state, downloadedIDs: Set(episodes.map(\.id))), .start(episodes[3].id))
    }
    func testGestureRepeatedBackAndReversedOrder() {
        var gesture = MediaSkipGesture()
        XCTAssertEqual(gesture.receive(.forward, at: 1, canSwitch: true), [.forward])
        XCTAssertEqual(gesture.receive(.backward, at: 2, canSwitch: true), [.backward])
        gesture.backwardCompleted(at: 3)
        XCTAssertEqual(gesture.receive(.backward, at: 3.5, canSwitch: true), [.backward])
        XCTAssertEqual(gesture.receive(.forward, at: 3.6, canSwitch: true), [.forward])
        XCTAssertEqual(gesture.receive(.backward, at: 4, canSwitch: true), [.backward])
        gesture.backwardCompleted(at: 5)
        XCTAssertEqual(gesture.receive(.forward, at: 5.5, canSwitch: true), [.switchQueue])
        XCTAssertEqual(gesture.receive(.backward, at: 6, canSwitch: true), [.backward])
        gesture.backwardCompleted(at: 7)
        gesture.cancel(); XCTAssertEqual(gesture.receive(.forward, at: 7.1, canSwitch: true), [.forward])
    }
    @MainActor func testFeedRefreshPreservesFollowSettingsArchiveAndCursor() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try PodcastStore(url: directory.appendingPathComponent("library.json"))
        var (state, episodes) = sample(); state.shows["a"]?.settings.automaticDownloadLimit = 5
        try store.update { $0 = state }
        var show = state.shows["a"]!; show.title = "Updated"; show.followed = false; show.settings.automaticDownloadLimit = 0
        _ = try store.merge(PodcastFeed(show: show, episodes: [episodes[3]]), existingID: "a")
        XCTAssertTrue(store.state.shows["a"]!.followed)
        XCTAssertEqual(store.state.shows["a"]?.settings.automaticDownloadLimit, 5)
        XCTAssertEqual(store.state.episodes.count, 8)
        XCTAssertEqual(store.state.cursors["a"], state.cursors["a"])
        XCTAssertEqual(store.state.shows["a"]?.title, "Updated")
    }
    @MainActor func testCorruptStoreIsNotOverwritten() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let invalid = Data("broken".utf8); try invalid.write(to: url)
        XCTAssertThrowsError(try PodcastStore(url: url)); XCTAssertEqual(try Data(contentsOf: url), invalid)
    }
    func testMergeProgressFollowAndStationTombstoneDoesNotReplaceLocalQueue() {
        var (local, episodes) = sample(); var remote = local
        local.queue = [episodes[0].id]; remote.queue = [episodes[7].id]
        remote.shows["a"]?.followed = false; remote.shows["a"]?.updatedAt = Date().addingTimeInterval(100)
        var progress = PodcastEpisodeState(); progress.position = 42; progress.updatedAt = Date().addingTimeInterval(100); remote.progress[episodes[0].id] = progress
        let station = PodcastStation(name: "Deleted"); local.stations = [station]; remote.stations = [station]; local.deletedStations[station.id] = Date().addingTimeInterval(100)
        let merged = PodcastLibraryMerge.merge(local: local, remote: remote)
        XCTAssertEqual(merged.queue, local.queue); XCTAssertEqual(merged.lastPlayedEpisodeID, local.lastPlayedEpisodeID)
        XCTAssertEqual(merged.progress[episodes[0].id]?.position, 42); XCTAssertEqual(merged.shows["a"]?.followed, false); XCTAssertTrue(merged.stations.isEmpty)
    }
    func testInvalidURLsAtomAndMalformedXML() throws {
        XCTAssertNil(PodcastIdentity.webURL("file:///private/etc/passwd"))
        XCTAssertNil(PodcastIdentity.webURL("javascript:alert(1)"))
        XCTAssertThrowsError(try PodcastFeed.parse(Data("<html><title>No</title></html>".utf8), url: URL(string: "https://example.com/rss")!))
        let atom = "<feed xmlns='http://www.w3.org/2005/Atom'><title>Atom</title><entry><id>x</id><title>Episode</title><published>2026-10-01T10:00:00Z</published><link rel='enclosure' type='audio/mpeg' href='audio.mp3'/></entry></feed>"
        let feed = try PodcastFeed.parse(Data(atom.utf8), url: URL(string: "https://example.com/feed")!)
        XCTAssertEqual(feed.episodes.first?.mediaURL.absoluteString, "https://example.com/audio.mp3")
        XCTAssertNotEqual(feed.episodes.first?.publishedAt, .distantPast)
    }
    func testTTMLAndJSONTranscripts() throws {
        let ttml = "<tt><body><p begin='1.5s' dur='2500ms'>Hello <span>world</span></p></body></tt>"
        XCTAssertEqual(try PodcastTranscript.parse(Data(ttml.utf8), type: "application/ttml+xml"), [.init(start: 1.5, end: 4, text: "Hello world")])
        let json = "{\"segments\":[{\"startTime\":3,\"endTime\":5,\"body\":\"Hello\"}]}"
        XCTAssertEqual(try PodcastTranscript.parse(Data(json.utf8), type: "application/json").first?.start, 3)
    }
}

extension PodcastTests {
    @MainActor func testLegacyBookmarksAreIgnoredWithoutLosingLibraryState() throws {
        var (state, episodes) = sample()
        let id = episodes[0].id
        state.progress[id] = PodcastEpisodeState()
        state.progress[id]?.position = 123
        state.queue = [id]
        state.lastPlayedEpisodeID = id
        state.settings.downloadByteLimit = 500_000_000
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any])
        var progress = try XCTUnwrap(json["progress"] as? [String: [String: Any]])
        progress[id]?["saved"] = true
        json["progress"] = progress
        var settings = try XCTUnwrap(json["settings"] as? [String: Any])
        settings["downloadSavedEpisodes"] = true
        json["settings"] = settings
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("library.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        let store = try PodcastStore(url: url)
        XCTAssertEqual(store.state, state)
        try store.recordPosition(id, position: 124)
        let rewritten = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(rewritten.contains("\"saved\""))
        XCTAssertFalse(rewritten.contains("downloadSavedEpisodes"))
        XCTAssertEqual(try PodcastStore(url: url).state.progress[id]?.position, 124)
        XCTAssertEqual(store.state.queue, [id])
        XCTAssertEqual(store.state.settings.maximumDownloadBytes, 500_000_000)
    }
    func testPlayedDownloadRetention() {
        var (state, episodes) = sample(); let id = episodes[0].id
        let now = Date(); var progress = PodcastEpisodeState(); progress.listened = true; progress.completedAt = now
        state.progress[id] = progress
        XCTAssertFalse(PodcastPolicies.shouldRemoveDownload(episodeID: id, manual: false, wanted: [], state: state, now: now))
        XCTAssertTrue(PodcastPolicies.shouldRemoveDownload(episodeID: id, manual: false, wanted: [], state: state, now: now.addingTimeInterval(86401)))
        state.settings.removePlayedDownloads = false
        XCTAssertFalse(PodcastPolicies.shouldRemoveDownload(episodeID: id, manual: false, wanted: [], state: state, now: now.addingTimeInterval(86401)))
    }
}

final class PodcastRequestCacheTests: XCTestCase {
    actor Loader {
        var count = 0
        func load(fail: Bool = false) async throws -> Int {
            count += 1
            try await Task.sleep(for: .milliseconds(40))
            if fail { throw PodcastError("Offline") }
            return count
        }
    }
    func testPrefetchAndOpenShareRequestAndCachedValue() async throws {
        let cache = PodcastRequestCache<Int>(), loader = Loader()
        async let first = cache.value(for: "feed") { try await loader.load() }
        async let second = cache.value(for: "feed") { try await loader.load() }
        let values = try await [first, second]
        XCTAssertEqual(values, [1, 1])
        let cached = try await cache.value(for: "feed") { try await loader.load() }
        XCTAssertEqual(cached, 1)
        let forced = try await cache.value(for: "feed", force: true) { try await loader.load() }
        XCTAssertEqual(forced, 2)
    }
    func testCancellingPrefetchDoesNotCancelNavigationConsumer() async throws {
        let cache = PodcastRequestCache<Int>(), loader = Loader()
        let prefetch = Task { try await cache.value(for: "feed") { try await loader.load() } }
        try await Task.sleep(for: .milliseconds(10)); prefetch.cancel()
        let opened = try await cache.value(for: "feed") { try await loader.load() }
        XCTAssertEqual(opened, 1)
        _ = try await prefetch.value
    }
    func testFailureIsRetriedAndExpiredEntriesReload() async throws {
        let cache = PodcastRequestCache<Int>(lifetime: 0), loader = Loader()
        do { _ = try await cache.value(for: "feed") { try await loader.load(fail: true) }; XCTFail("Expected failure") } catch {}
        let retried = try await cache.value(for: "feed") { try await loader.load() }
        let expired = try await cache.value(for: "feed") { try await loader.load() }
        XCTAssertEqual(retried, 2); XCTAssertEqual(expired, 3)
    }
    func testCapacityEvictsOldestEntry() async throws {
        let cache = PodcastRequestCache<Int>(capacity: 1), loader = Loader()
        _ = try await cache.value(for: "a") { try await loader.load() }
        _ = try await cache.value(for: "b") { try await loader.load() }
        let evicted = try await cache.value(for: "a") { try await loader.load() }
        XCTAssertEqual(evicted, 3)
    }
}

extension PodcastTests {
    func testDownloadPlanPrioritizesCurrentThenQueueBeforeManualAndShowDownloads() {
        var (state, episodes) = sample()
        state.currentEpisodeID = episodes[0].id
        state.queue = [episodes[2].id, episodes[4].id]
        state.settings.downloadByteLimit = 300
        let sizes = Dictionary(uniqueKeysWithValues: episodes.map { ($0.id, Int64(100)) })
        let plan = PodcastDownloadPlan(state: state, sizes: sizes, manualIDs: [episodes[7].id])
        XCTAssertEqual(plan.episodeIDs, [episodes[0].id, episodes[2].id, episodes[4].id])
        XCTAssertEqual(plan.reservedBytes.values.reduce(0, +), 300)
    }
    func testDownloadPlanStopsAtFirstQueueEpisodeThatDoesNotFit() {
        var (state, episodes) = sample()
        state.currentEpisodeID = episodes[0].id; state.queue = [episodes[2].id, episodes[4].id]
        state.settings.downloadByteLimit = 250
        let sizes: [String: Int64] = [episodes[0].id: 100, episodes[2].id: 200, episodes[4].id: 10]
        XCTAssertEqual(PodcastDownloadPlan(state: state, sizes: sizes).episodeIDs, [episodes[0].id])
        state.queue.reverse()
        XCTAssertEqual(PodcastDownloadPlan(state: state, sizes: sizes).episodeIDs, [episodes[0].id, episodes[4].id])
    }
    func testUnknownDownloadReservesRemainingBudgetUntilSizeIsKnown() {
        var (state, episodes) = sample()
        state.currentEpisodeID = episodes[0].id; state.queue = [episodes[2].id, episodes[4].id]
        state.settings.downloadByteLimit = 300
        let sizes: [String: Int64] = [episodes[0].id: 100, episodes[4].id: 50]
        let unknown = PodcastDownloadPlan(state: state, sizes: sizes)
        XCTAssertEqual(unknown.episodeIDs, [episodes[0].id, episodes[2].id])
        XCTAssertEqual(unknown.reservedBytes[episodes[2].id], 200)
        var measured = sizes; measured[episodes[2].id] = 100
        XCTAssertEqual(PodcastDownloadPlan(state: state, sizes: measured).episodeIDs.prefix(3), [episodes[0].id, episodes[2].id, episodes[4].id])
    }
    func testDownloadPlanKeepsPausedEpisodeAfterRelaunchWithoutFollowedShow() {
        var (state, episodes) = sample()
        state.shows = [:]; state.lastPlayedEpisodeID = episodes[0].id
        state.settings.downloadByteLimit = 100
        XCTAssertEqual(PodcastDownloadPlan(state: state, sizes: [episodes[0].id: 100]).episodeIDs, [episodes[0].id])
        state.naturallyExhaustedQueue = true
        XCTAssertTrue(PodcastDownloadPlan(state: state, sizes: [:]).episodeIDs.isEmpty)
    }
    func testDownloadPlanHonorsSuppressionAndAllowsExplicitPlayedReplay() {
        var (state, episodes) = sample(); state.shows = [:]
        state.currentEpisodeID = episodes[0].id; state.queue = [episodes[6].id, episodes[6].id, "missing"]
        state.progress[episodes[0].id] = PodcastEpisodeState()
        state.progress[episodes[0].id]?.suppressAutomaticDownload = true
        let plan = PodcastDownloadPlan(state: state, sizes: [episodes[6].id: 100])
        XCTAssertEqual(plan.episodeIDs, [episodes[6].id])
    }
    func testCapReductionKeepsOpenAssetButStopsOtherDownloads() {
        var (state, episodes) = sample()
        state.currentEpisodeID = episodes[0].id; state.queue = [episodes[2].id]
        state.settings.downloadByteLimit = 50
        let plan = PodcastDownloadPlan(state: state, sizes: [episodes[0].id: 100, episodes[2].id: 10], protectedID: episodes[0].id)
        XCTAssertEqual(plan.episodeIDs, [episodes[0].id])
        XCTAssertTrue(PodcastDownloadPlan(state: state, sizes: [episodes[0].id: 100]).episodeIDs.isEmpty)
    }
    func testByteCapMigrationPreservesOldSettings() throws {
        var settings = PodcastSettings(); settings.cellularDownloads = true; settings.playedRetentionHours = 48
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any])
        json.removeValue(forKey: "downloadByteLimit")
        let decoded = try JSONDecoder().decode(PodcastSettings.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(decoded.maximumDownloadBytes, 2_000_000_000)
        XCTAssertTrue(decoded.cellularDownloads); XCTAssertEqual(decoded.playedRetentionHours, 48)
        settings.downloadByteLimit = -1; XCTAssertEqual(settings.maximumDownloadBytes, 0)
    }
    @MainActor func testFinishingMovesDownloadPriorityAndExplicitRequeueClearsSuppression() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try PodcastStore(url: directory.appendingPathComponent("library.json"))
        var (state, episodes) = sample()
        state.currentEpisodeID = episodes[0].id; state.queue = [episodes[2].id, episodes[4].id]
        state.settings.downloadByteLimit = 200
        try store.update { $0 = state }
        XCTAssertEqual(try store.finishNaturally(episodes[0].id), episodes[2].id)
        XCTAssertEqual(store.state.currentEpisodeID, episodes[2].id)
        let plan = PodcastDownloadPlan(state: store.state, sizes: [episodes[0].id: 100, episodes[2].id: 100, episodes[4].id: 100])
        XCTAssertEqual(plan.episodeIDs, [episodes[2].id, episodes[4].id])
        try store.update { $0.progress[episodes[0].id]?.suppressAutomaticDownload = true }
        try store.enqueue(episodes[0].id, next: true)
        XCTAssertEqual(store.state.progress[episodes[0].id]?.suppressAutomaticDownload, false)
        XCTAssertEqual(store.state.queue.first, episodes[0].id)
    }
    func testCompletedEpisodeDoesNotRedownloadAfterFinishing() {
        let (state, episodes) = sample()
        XCTAssertFalse(PodcastPolicies.automaticDownloads(state).contains(episodes[6].id))
    }
}

@MainActor final class PodcastStoreResponsivenessTests: XCTestCase {
    private func makeStore() throws -> PodcastStore {
        try PodcastStore(url: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("library.json"))
    }
    func testBackgroundSaveYieldsAndRetriesConcurrentEdits() async throws {
        let store = try makeStore()
        defer { try? FileManager.default.removeItem(at: store.url.deletingLastPathComponent()) }
        let started = expectation(description: "Background preparation began")
        let gate = PodcastSaveGate { started.fulfill() }
        let save = Task {
            try await store.updateInBackground { state in
                XCTAssertFalse(Thread.isMainThread)
                gate.waitOnce()
                state.settings.countryCode = "AU"
            }
        }
        await fulfillment(of: [started], timeout: 3)
        // This must remain possible while the background snapshot is prepared.
        try store.update { $0.settings.hidePlayed = true }
        gate.release()
        try await save.value
        XCTAssertTrue(store.state.settings.hidePlayed)
        XCTAssertEqual(store.state.settings.countryCode, "AU")
        XCTAssertEqual(try PodcastStore(url: store.url).state, store.state)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.url.deletingLastPathComponent().path), ["library.json"])
    }
    func testCancelledBackgroundSaveNeverPublishesOrReplacesDisk() async throws {
        let store = try makeStore()
        defer { try? FileManager.default.removeItem(at: store.url.deletingLastPathComponent()) }
        try store.update { $0.settings.countryCode = "US" }
        let before = try Data(contentsOf: store.url)
        let started = expectation(description: "Preparation began")
        let gate = PodcastSaveGate { started.fulfill() }
        let save = Task {
            try await store.updateInBackground { state in gate.waitOnce(); state.settings.countryCode = "AU" }
        }
        await fulfillment(of: [started], timeout: 3)
        save.cancel(); gate.release()
        do { try await save.value; XCTFail("Cancelled save committed") } catch is CancellationError { }
        XCTAssertEqual(store.state.settings.countryCode, "US")
        XCTAssertEqual(try Data(contentsOf: store.url), before)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.url.deletingLastPathComponent().path), ["library.json"])
    }
    func testConcurrentFeedImportsPreserveBothFeedsAndDurability() async throws {
        let store = try makeStore()
        defer { try? FileManager.default.removeItem(at: store.url.deletingLastPathComponent()) }
        func feed(_ name: String) -> PodcastFeed {
            let show = PodcastShow(feedURL: URL(string: "https://example.com/\(name)")!, title: name)
            let episode = PodcastEpisode(showID: show.id, guid: name, title: name, publishedAt: Date(), mediaURL: URL(string: "https://example.com/\(name).mp3")!)
            return PodcastFeed(show: show, episodes: [episode])
        }
        async let first = store.mergeInBackground(feed("a"), follow: true)
        async let second = store.mergeInBackground(feed("b"), follow: false)
        _ = try await (first, second)
        XCTAssertEqual(store.state.shows.count, 2); XCTAssertEqual(store.state.episodes.count, 2)
        XCTAssertEqual(try PodcastStore(url: store.url).state, store.state)
    }
    func testBatchMarkPlayedWritesAndPublishesOnce() async throws {
        let store = try makeStore()
        defer { try? FileManager.default.removeItem(at: store.url.deletingLastPathComponent()) }
        let published = expectation(description: "One publication"); published.assertForOverFulfill = true
        let observer = NotificationCenter.default.addObserver(forName: .lunaPodcastsChanged, object: nil, queue: .main) { _ in published.fulfill() }
        defer { NotificationCenter.default.removeObserver(observer) }
        try await store.markListenedInBackground(["a", "b", "c"], true)
        await fulfillment(of: [published], timeout: 1)
        XCTAssertEqual(store.state.progress.values.filter(\.listened).count, 3)
        XCTAssertEqual(try PodcastStore(url: store.url).state, store.state)
    }
    func testLargeFeedImportKeepsMainActorAvailable() async throws {
        let store = try makeStore()
        defer { try? FileManager.default.removeItem(at: store.url.deletingLastPathComponent()) }
        let show = PodcastShow(feedURL: URL(string: "https://example.com/large")!, title: "Large Archive")
        let episodes = (0..<2000).map { index in
            var episode = PodcastEpisode(showID: show.id, guid: "\(index)", title: "Episode \(index)", publishedAt: Date(), mediaURL: URL(string: "https://example.com/\(index).mp3")!)
            episode.summary = String(repeating: "<p>Long publisher show notes &amp; links.</p>", count: 100)
            return episode
        }
        let blockingStore = try makeStore()
        defer { try? FileManager.default.removeItem(at: blockingStore.url.deletingLastPathComponent()) }
        let blockingStart = Date()
        _ = try blockingStore.merge(PodcastFeed(show: show, episodes: episodes))
        let blockingDuration = Date().timeIntervalSince(blockingStart)
        var ticks = 0
        var largestGap: TimeInterval = 0
        let heartbeat = Task { @MainActor in
            var previous = Date()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(5)) } catch { return }
                let now = Date(); largestGap = max(largestGap, now.timeIntervalSince(previous)); previous = now; ticks += 1
            }
        }
        let start = Date()
        let ids = try await store.mergeInBackground(PodcastFeed(show: show, episodes: episodes), follow: false)
        heartbeat.cancel()
        print("Large-feed import: synchronous main-thread stall \(blockingDuration) s; background import \(Date().timeIntervalSince(start)) s; main heartbeat ticks: \(ticks); largest gap: \(largestGap) s")
        XCTAssertGreaterThan(ticks, 0)
        XCTAssertEqual(ids.count, 2000)
        XCTAssertEqual(try PodcastStore(url: store.url).state, store.state)
    }
}

private final class PodcastSaveGate: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var waited = false
    private let started: @Sendable () -> Void
    init(started: @escaping @Sendable () -> Void) { self.started = started }
    func waitOnce() {
        lock.lock(); let shouldWait = !waited; waited = true; lock.unlock()
        if shouldWait { started(); _ = semaphore.wait(timeout: .now() + 5) }
    }
    func release() { semaphore.signal() }
}

final class ReaderPodcastPrivacyTests: XCTestCase {
    func testLocalReadoutsStayOutOfCloudMergeAndDownloadBudget() {
        var state = PodcastLibraryState()
        let reader = PodcastShow(feedURL: URL(string: "lunamusic://reader")!, title: "Luna Reader", id: ReaderPodcastSource.showID)
        let readout = PodcastEpisode(showID: reader.id, guid: UUID().uuidString, title: "Private save", publishedAt: Date(), mediaURL: URL(fileURLWithPath: "/private/readout.m4a"))
        let show = PodcastShow(feedURL: URL(string: "https://example.com/feed")!, title: "RSS")
        let episode = PodcastEpisode(showID: show.id, guid: "one", title: "Episode", publishedAt: Date(), mediaURL: URL(string: "https://example.com/audio.mp3")!)
        state.shows = [reader.id: reader, show.id: show]; state.episodes = [readout.id: readout, episode.id: episode]
        state.progress[readout.id] = PodcastEpisodeState(); state.cursors[reader.id] = PodcastCursor(episode: readout)
        state.queue = [readout.id, episode.id]; state.currentEpisodeID = readout.id; state.lastPlayedEpisodeID = readout.id
        let cloud = ReaderPodcastSource.cloudState(state)
        XCTAssertEqual(Set(cloud.shows.keys), [show.id]); XCTAssertEqual(Set(cloud.episodes.keys), [episode.id])
        XCTAssertTrue(cloud.progress.isEmpty); XCTAssertTrue(cloud.cursors.isEmpty)
        XCTAssertNil(cloud.currentEpisodeID); XCTAssertNil(cloud.lastPlayedEpisodeID); XCTAssertEqual(cloud.queue, [episode.id])
        let imported = PodcastLibraryMerge.merge(local: PodcastLibraryState(), remote: state)
        XCTAssertNil(imported.episodes[readout.id]); XCTAssertNil(imported.shows[reader.id])
        let plan = PodcastDownloadPlan(state: state, sizes: [episode.id: 100])
        XCTAssertEqual(plan.episodeIDs, [episode.id])
        XCTAssertEqual(PodcastLibraryMerge.merge(local: state, remote: cloud).episodes[readout.id], readout)
    }
}
