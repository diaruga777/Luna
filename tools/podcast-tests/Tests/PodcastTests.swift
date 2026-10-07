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
