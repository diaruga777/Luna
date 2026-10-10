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
        XCTAssertEqual(PodcastPolicies.resumeDecision(state), .resume(episodes[6].id))
        state.naturallyExhaustedQueue = true
        XCTAssertEqual(PodcastPolicies.resumeDecision(state), .start(episodes[2].id))
        state.cursors["a"] = .init(episode: episodes[3]); state.cursors["b"] = .init(episode: episodes[7])
        for index in [3, 7] { var progress = PodcastEpisodeState(); progress.listened = true; state.progress[episodes[index].id] = progress }
        XCTAssertEqual(PodcastPolicies.resumeDecision(state), .nothing)
    }
    func testOlderBacklogIsNotResurrectedAndNoHistoryIsNoOp() {
        var (state, episodes) = sample(); state.naturallyExhaustedQueue = true
        state.cursors["a"] = .init(episode: episodes[3]); state.cursors["b"] = .init(episode: episodes[7])
        XCTAssertEqual(PodcastPolicies.resumeDecision(state), .nothing)
        state.lastPlayedEpisodeID = nil
        XCTAssertEqual(PodcastPolicies.resumeDecision(state), .nothing)
    }
    func testGestureBoundariesAndNoDestination() {
        var gesture = MediaSkipGesture()
        XCTAssertEqual(gesture.receive(.backward, at: 10, canSwitch: true), [])
        XCTAssertEqual(gesture.receive(.forward, at: 12, canSwitch: true), [.switchQueue])
        XCTAssertEqual(gesture.expire(at: 13), [])
        XCTAssertEqual(gesture.receive(.backward, at: 20, canSwitch: true), [])
        XCTAssertEqual(gesture.receive(.forward, at: 22.001, canSwitch: true), [.backward, .forward])
        XCTAssertEqual(gesture.receive(.backward, at: 30, canSwitch: false), [])
        XCTAssertEqual(gesture.receive(.forward, at: 31, canSwitch: false), [.backward, .forward])
        XCTAssertEqual(gesture.receive(.backward, at: 40, canSwitch: true), [])
        XCTAssertEqual(gesture.expire(at: 41.9), [])
        XCTAssertEqual(gesture.expire(at: 42), [.backward])
    }
    @MainActor func testDurabilityNaturalEndAndManualMarking() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try PodcastStore(url: directory.appendingPathComponent("library.json"))
        let (state, episodes) = sample(); try store.update { $0 = state }
        try store.recordPlaybackStarted(episodes[1].id)
        try store.recordPosition(episodes[1].id, position: 123.5)
        try store.markListened(episodes[1].id, true)
        XCTAssertEqual(PodcastPolicies.resumeDecision(store.state), .resume(episodes[1].id))
        try store.enqueue(episodes[2].id, next: false)
        XCTAssertEqual(try store.finishNaturally(episodes[1].id), episodes[2].id)
        XCTAssertFalse(store.state.naturallyExhaustedQueue)
        try store.recordPlaybackStarted(episodes[2].id)
        XCTAssertNil(try store.finishNaturally(episodes[2].id))
        XCTAssertTrue(store.state.naturallyExhaustedQueue)
        XCTAssertEqual(try PodcastStore(url: store.url).state, store.state)
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
        XCTAssertEqual(PodcastPolicies.resumeDecision(state), .start(episodes[0].id))
        state.shows["a"]?.followed = false
        XCTAssertEqual(PodcastPolicies.resumeDecision(state), .start(episodes[7].id))
    }
    func testQueueAddedAfterExhaustionWinsOverSubscriptions() {
        var (state, episodes) = sample(); state.naturallyExhaustedQueue = true; state.queue = [episodes[3].id]
        XCTAssertEqual(PodcastPolicies.resumeDecision(state), .start(episodes[3].id))
    }
    func testGestureRepeatedBackAndReversedOrder() {
        var gesture = MediaSkipGesture()
        XCTAssertEqual(gesture.receive(.forward, at: 1, canSwitch: true), [.forward])
        XCTAssertEqual(gesture.receive(.backward, at: 2, canSwitch: true), [])
        XCTAssertEqual(gesture.receive(.backward, at: 2.5, canSwitch: true), [.backward])
        XCTAssertEqual(gesture.receive(.forward, at: 3, canSwitch: true), [.switchQueue])
        XCTAssertEqual(gesture.receive(.backward, at: 4, canSwitch: true), [])
        gesture.cancel(); XCTAssertEqual(gesture.receive(.forward, at: 5, canSwitch: true), [.forward])
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
    func testPlayedDownloadRetentionAndSavedPins() {
        var (state, episodes) = sample(); let id = episodes[0].id
        let now = Date(); var progress = PodcastEpisodeState(); progress.listened = true; progress.completedAt = now
        state.progress[id] = progress
        XCTAssertFalse(PodcastPolicies.shouldRemoveDownload(episodeID: id, manual: false, wanted: [], state: state, now: now))
        XCTAssertTrue(PodcastPolicies.shouldRemoveDownload(episodeID: id, manual: false, wanted: [], state: state, now: now.addingTimeInterval(86401)))
        state.progress[id]?.saved = true
        XCTAssertFalse(PodcastPolicies.shouldRemoveDownload(episodeID: id, manual: false, wanted: [], state: state, now: now.addingTimeInterval(86401)))
        state.progress[id]?.saved = false; state.settings.removePlayedDownloads = false
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
