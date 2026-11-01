import LunaCompanionShareCore
import XCTest
import AVFoundation
@testable import LunaMusicCore
import LunaPodcastCore

@MainActor final class PodcastAutomationTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("PodcastAutomationTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }
    private func audio() throws -> URL {
        let source = directory.appendingPathComponent("Source.wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 22_050, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 22_050)!
        buffer.frameLength = 22_050
        for index in 0..<22_050 { buffer.floatChannelData![0][index] = 0 }
        let file = try AVAudioFile(forWriting: source, settings: format.settings)
        try file.write(from: buffer)
        return source
    }
    func testImportCopiesFileQueuesAndDeduplicatesByKey() async throws {
        let source = try audio()
        let library = PodcastLibraryController(url: directory.appendingPathComponent("Library/library.json"))
        let list = try PodcastAutomation.createAudioList(name: "Articles", library: library)
        let episode = try await PodcastAutomation.importAudio(at: source, title: "An Article", listID: list.id,
            enqueue: true, importKey: "reader-save-1", library: library)
        XCTAssertNotEqual(source, episode.mediaURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: episode.mediaURL.path))
        XCTAssertEqual(library.state.queue, [episode.id])
        try FileManager.default.removeItem(at: source)
        // A retry can return the existing import even if the input has expired.
        let repeated = try await PodcastAutomation.importAudio(at: source, title: "Another Title", listID: list.id,
            enqueue: true, importKey: "reader-save-1", library: library)
        XCTAssertEqual(repeated.id, episode.id)
        XCTAssertEqual(library.state.episodes.count, 1)
        XCTAssertEqual(library.state.queue, [episode.id])
        XCTAssertEqual(repeated.title, "An Article")
    }
    func testImportWithoutQueueStillReturnsPlayableEpisode() async throws {
        let library = PodcastLibraryController(url: directory.appendingPathComponent("Library/library.json"))
        let episode = try await PodcastAutomation.importAudio(at: audio(), title: "", listID: nil, enqueue: false, library: library)
        XCTAssertEqual(episode.title, "Source")
        XCTAssertTrue(library.state.queue.isEmpty)
        XCTAssertNotNil(library.state.shows[episode.showID])
    }
    func testExternalAudioIsExcludedFromCloudLibrary() async throws {
        let library = PodcastLibraryController(url: directory.appendingPathComponent("Library/library.json"))
        let list = try PodcastAutomation.createAudioList(name: "Articles", library: library)
        let episode = try await PodcastAutomation.importAudio(at: audio(), title: "Article", listID: list.id, enqueue: true, library: library)
        let cloud = ReaderPodcastSource.cloudState(library.state)
        XCTAssertNil(cloud.shows[list.id]); XCTAssertNil(cloud.episodes[episode.id]); XCTAssertTrue(cloud.queue.isEmpty)
    }
    func testRejectsFeedAsLocalImportDestination() async throws {
        let library = PodcastLibraryController(url: directory.appendingPathComponent("Library/library.json"))
        let show = PodcastShow(feedURL: URL(string: "https://example.com/feed")!, title: "RSS")
        try library.edit { $0.shows[show.id] = show }
        do {
            _ = try await PodcastAutomation.importAudio(at: audio(), title: "Article", listID: show.id, enqueue: true, library: library)
            XCTFail("Expected a local audio list validation error")
        } catch { XCTAssertTrue(library.state.episodes.isEmpty) }
    }
    func testInitialProgressAndPositionTicksAreNotAutomationChanges() throws {
        var before = PodcastLibraryState()
        let episode = PodcastEpisode(showID: "show", guid: "episode", title: "Episode", publishedAt: Date(), mediaURL: URL(string: "https://example.com/audio.mp3")!)
        before.episodes[episode.id] = episode
        var after = before
        after.progress[episode.id] = PodcastEpisodeState()
        XCTAssertTrue(PodcastAutomation.changes(from: before, to: after).isEmpty)
        after.progress[episode.id]?.position = 12
        XCTAssertTrue(PodcastAutomation.changes(from: before, to: after).isEmpty)
        after.progress[episode.id]?.listened = true
        let changes = PodcastAutomation.changes(from: before, to: after)
        XCTAssertEqual(changes.map(\.itemID), [episode.id])
        XCTAssertEqual(changes.map(\.operation), ["updated"])
    }

}

@MainActor final class CompanionShareImportTests: XCTestCase {
    func testInboxCopiesBeforePublishingAndIgnoresIncompleteCaptures() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = CompanionShareInbox(root: root.appendingPathComponent("Inbox"))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("Audio.wav")
        try Data([1, 2, 3]).write(to: source)
        let capture = CompanionShareCapture(kind: .podcast, filenames: ["0-Audio.wav"], playNext: true)
        try inbox.save(capture, files: [source]); try FileManager.default.removeItem(at: source)
        XCTAssertEqual(try inbox.pending().map(\.id), [capture.id])
        XCTAssertEqual(try Data(contentsOf: inbox.directory(for: capture).appendingPathComponent("0-Audio.wav")), Data([1, 2, 3]))
        let invalid = CompanionShareCapture(kind: .song, filenames: ["../escape.wav"])
        XCTAssertThrowsError(try inbox.save(invalid, files: [source]))
        XCTAssertEqual(try inbox.pending().count, 1)
        try inbox.remove(capture); XCTAssertTrue(try inbox.pending().isEmpty)
    }
    func testPodcastPlayNextPreservesSelectionOrderAndReplayDoesNotDuplicate() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = CompanionShareInbox(root: root.appendingPathComponent("Inbox"))
        let source = try makeAudio(root)
        let capture = CompanionShareCapture(kind: .podcast, filenames: ["0-First.wav", "1-Second.wav"], playNext: true)
        try inbox.save(capture, files: [source, source])
        let podcasts = PodcastLibraryController(url: root.appendingPathComponent("Podcasts/library.json"))
        let music = VaultMusicController(directory: root.appendingPathComponent("Music"))
        try await MusicShareImport.importCapture(capture, inbox: inbox, podcasts: podcasts, music: music)
        try await MusicShareImport.importCapture(capture, inbox: inbox, podcasts: podcasts, music: music)
        XCTAssertEqual(podcasts.state.episodes.count, 2)
        XCTAssertEqual(podcasts.state.queue.compactMap { podcasts.state.episodes[$0]?.title }, ["First", "Second"])
    }
    func testImportedSongSurvivesRestartAndCanBelongToSeveralPlaylists() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try makeAudio(root)
        let musicRoot = root.appendingPathComponent("Music")
        let music = VaultMusicController(directory: musicRoot)
        let first = try music.createPlaylist(name: "First", songs: [])
        let second = try music.createPlaylist(name: "Second", songs: [])
        for _ in 0..<2 {
            try await music.importSong(at: source, key: "test-song", title: "Audio", playlists: [first.persistentID, second.persistentID])
        }
        try FileManager.default.removeItem(at: source)
        let restored = VaultMusicController(directory: musicRoot)
        XCTAssertEqual(restored.songs.count, 1)
        let song = try XCTUnwrap(restored.songs.first)
        XCTAssertNotNil(restored.localURL(song))
        XCTAssertTrue(restored.playlists.allSatisfy { $0.items.map(\.persistentID) == [song.persistentID] })
        try await restored.removeCachedSong(song)
        XCTAssertNotNil(restored.localURL(song))
    }
    private func makeAudio(_ root: URL) throws -> URL {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("Original.wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 22_050, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 22_050)!
        buffer.frameLength = 22_050
        buffer.floatChannelData![0].initialize(repeating: 0, count: 22_050)
        let audio = try AVAudioFile(forWriting: url, settings: format.settings)
        try audio.write(from: buffer)
        return url
    }
}
