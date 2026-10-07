import XCTest
import AVFoundation
import LunaPodcastCore
import MediaPlayer
@testable import LunaMusicCore
@testable import LunaMusicUI

final class VaultMusicTests: XCTestCase {
    func testRangeReadsDeduplicateAndVersionCacheIsolated() async throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data((0..<(MusicFileProtocol.chunkSize * 3)).map { UInt8($0 % 251) })
        let server = FakeMusicServer(bytes: bytes)
        let cache = try VaultMusicCache(root: root) { try await server.request($0) }
        let song = MusicSong(file: file(size: bytes.count), peer: "Mac")
        async let a = cache.range(song: song, offset: 10, length: 100)
        async let b = cache.range(song: song, offset: 20, length: 100)
        let (first, second) = try await (a, b)
        XCTAssertEqual(first, bytes.subdata(in: 10..<110)); XCTAssertEqual(second, bytes.subdata(in: 20..<120))
        let count = await server.readCount; XCTAssertEqual(count, 1)
        var changed = file(size: bytes.count); changed.version = "v2"
        _ = try await cache.range(song: MusicSong(file: changed, peer: "Mac"), offset: 10, length: 100)
        let updatedCount = await server.readCount; XCTAssertEqual(updatedCount, 2)
    }
    func testDownloadAtomicInstallationAndRemovalNeverMutatesServer() async throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data(repeating: 42, count: MusicFileProtocol.chunkSize + 31)
        let server = FakeMusicServer(bytes: bytes)
        let cache = try VaultMusicCache(root: root) { try await server.request($0) }
        let song = MusicSong(file: file(size: bytes.count), peer: "Mac")
        let url = try await cache.download(song)
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        XCTAssertTrue(VaultMusicCache.complete(url, size: Int64(bytes.count)))
        try await cache.purge(keeping: [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        let operations = await server.operations
        XCTAssertTrue(operations.allSatisfy { $0 == .read })
    }
    func testIncompleteRangeNeverCreatesPlayableCache() async throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let cache = try VaultMusicCache(root: root) { _ in try JSONEncoder().encode(MusicFileResponse(data: Data([0]))) }
        let song = MusicSong(file: file(size: 100), peer: "Mac")
        do { _ = try await cache.download(song); XCTFail("Incomplete download accepted") } catch {}
        XCTAssertFalse(VaultMusicCache.complete(VaultMusicCache.url(root: root, song: song), size: 100))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }
    func testCancelledDownloadCleansStagingFile() async throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let server = FakeMusicServer(bytes: Data(repeating: 1, count: MusicFileProtocol.chunkSize * 3), delay: 100_000_000)
        let cache = try VaultMusicCache(root: root) { try await server.request($0) }
        let song = MusicSong(file: file(size: MusicFileProtocol.chunkSize * 3), peer: "Mac")
        let work = Task { try await cache.download(song) }
        try await Task.sleep(for: .milliseconds(20)); work.cancel()
        do { _ = try await work.value; XCTFail("Cancelled download succeeded") } catch {}
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }
    @MainActor func testArtistAndAlbumMatchAcrossSourcesWithoutSongIDCollision() {
        let apple = MusicSong(TestAppleSong())
        var value = file(size: 100); value.artist = "beyonce"; value.albumArtist = "beyonce"; value.album = "Album"
        let vault = MusicSong(file: value, peer: "Mac")
        XCTAssertEqual(apple.artistPersistentID, vault.artistPersistentID)
        XCTAssertEqual(apple.albumPersistentID, vault.albumPersistentID)
        XCTAssertNotEqual(apple.persistentID, vault.persistentID)
    }
    @MainActor func testPlaylistSourceGuardsAndPickerFiltering() async throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let controller = VaultMusicController(directory: root)
        let server = FakeMusicServer(bytes: wave(seconds: 2))
        try controller.configure(peer: { "Mac" }, request: { try await server.request($0) })
        await controller.refresh()
        let song = try XCTUnwrap(controller.songs.first)
        let playlist = try controller.createPlaylist(name: "Offline", songs: [song])
        XCTAssertThrowsError(try controller.add([MusicSong(TestAppleSong())], to: playlist))
        let picker = MusicPlaylistSongPicker(playlist: playlist, songProvider: { [MusicSong(TestAppleSong()), song] }, addSongs: { _ in })
        picker.loadViewIfNeeded()
        XCTAssertEqual(picker.tableView(picker.tableView, numberOfRowsInSection: 0), 1)
        let restored = VaultMusicController(directory: root)
        XCTAssertEqual(restored.playlists.first?.items.map(\.persistentID), [song.persistentID])
    }
    @MainActor func testAutomaticCacheAndExplicitDeletionSurviveRelaunch() async throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let controller = VaultMusicController(directory: root)
        let server = FakeMusicServer(bytes: wave(seconds: 2))
        try controller.configure(peer: { "Mac" }, request: { try await server.request($0) })
        await controller.refresh()
        let song = try XCTUnwrap(controller.songs.first)
        let playlist = try controller.createPlaylist(name: "Most Played", songs: [song])
        controller.recordPlay(playlistID: playlist.persistentID)
        try await until { controller.isCached(song) }
        try await controller.removeCachedSong(song)
        XCTAssertFalse(controller.isCached(song))
        controller.recordPlay(playlistID: playlist.persistentID)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertFalse(controller.isCached(song))
        try controller.cacheSongs([song])
        try await until { controller.isCached(song) }
        try controller.setAutomaticPlaylistCount(0)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(controller.isCached(song))
        let restored = VaultMusicController(directory: root)
        XCTAssertEqual(restored.state.automaticPlaylistCount, 0)
        XCTAssertTrue(restored.isCached(song))
        XCTAssertTrue(restored.state.manual.contains(song.persistentID))
    }
    @MainActor func testRealAVPlayerStreamsSeeksAndCacheDecodesOffline() async throws {
        try AVAudioSession.sharedInstance().setCategory(.playback)
        try AVAudioSession.sharedInstance().setActive(true)
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "streaming", withExtension: "mp4"))
        let bytes = try Data(contentsOf: fixture)
        var info = file(size: bytes.count, duration: 180); info.path = "Artist/Album/streaming.mp4"
        let server = FakeMusicServer(bytes: bytes, delay: 500_000_000, fileInfo: info)
        let vault = VaultMusicController(directory: root)
        try vault.configure(peer: { "Mac" }, request: { try await server.request($0) })
        await vault.refresh()
        let song = try XCTUnwrap(vault.songs.first)
        let engine = AVPlayer()
        let player = MusicPlaybackController(defaults: UserDefaults(suiteName: UUID().uuidString)!, vault: vault, filePlayer: engine)
        try await player.play([song])
        try await until { player.isPlaying }
        let bytesRead = await server.bytesRead
        XCTAssertLessThan(bytesRead, bytes.count, "Playback should start without a full download")
        player.seek(to: 150)
        try await until { engine.currentTime().seconds >= 149 }
        player.togglePlayPause()
        try vault.cacheSongs([song])
        try await until { vault.isCached(song) }
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(vault.localURL(song))), bytes)
        await server.setOffline()
        let before = await server.readCount
        let asset = AVURLAsset(url: try XCTUnwrap(vault.localURL(song)))
        let playable = try await asset.load(.isPlayable)
        XCTAssertTrue(playable)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: try XCTUnwrap(tracks.first), outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM])
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        XCTAssertNotNil(output.copyNextSampleBuffer())
        reader.cancelReading()
        let after = await server.readCount
        XCTAssertEqual(before, after, "Offline decoding must not contact the Mac")
    }
    @MainActor func testVaultQueueTransportAndRepeat() async throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let vault = VaultMusicController(directory: root)
        let server = FakeMusicServer(bytes: wave(seconds: 10))
        try vault.configure(peer: { "Mac" }, request: { try await server.request($0) })
        await vault.refresh()
        let first = try XCTUnwrap(vault.songs.first)
        var secondFile = try XCTUnwrap(first.file); secondFile.path = "Artist/Album/Second.wav"
        let second = MusicSong(file: secondFile, peer: "Mac")
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let player = MusicPlaybackController(defaults: defaults, vault: vault)
        try await player.play([first, second])
        try await until { player.isPlaying }
        player.seek(to: 4)
        try await until { player.playbackTime >= 3.9 }
        player.togglePlayPause()
        XCTAssertFalse(player.isPlaying)
        try await player.resume()
        try await until { player.isPlaying }
        player.next()
        try await until { player.nowPlaying?.persistentID == second.persistentID && player.isPlaying }
        player.previous()
        try await until { player.nowPlaying?.persistentID == first.persistentID && player.isPlaying }
        player.cycleRepeat(); player.cycleRepeat()
        XCTAssertEqual(player.repeatMode, .one)
        player.togglePlayPause()
    }
    @MainActor private func until(file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool) async throws {
        for _ in 0..<600 { if condition() { return }; try await Task.sleep(for: .milliseconds(50)) }
        XCTFail("Timed out waiting for playback/cache state", file: file, line: line)
        throw MusicFileError("Test timed out")
    }
    private func temporary() -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); return root
    }
    private func file(size: Int, duration: Double = 10) -> MusicFile {
        MusicFile(path: "Artist/Album/Song.wav", version: "v1", size: Int64(size), title: "Song", artist: "Artist", album: "Album", duration: duration)
    }
    private func wave(seconds: Int) -> Data {
        let count = 44_100 * seconds * 2
        var data = Data()
        func text(_ value: String) { data.append(Data(value.utf8)) }
        func word(_ value: UInt16) { var v = value.littleEndian; withUnsafeBytes(of: &v) { data.append(contentsOf: $0) } }
        func number(_ value: UInt32) { var v = value.littleEndian; withUnsafeBytes(of: &v) { data.append(contentsOf: $0) } }
        text("RIFF"); number(UInt32(36 + count)); text("WAVEfmt "); number(16); word(1); word(1)
        number(44_100); number(88_200); word(2); word(16); text("data"); number(UInt32(count))
        data.append(Data(count: count)); return data
    }
}
private final class TestAppleSong: MPMediaItem {
    override var persistentID: UInt64 { 1 }
    override var title: String? { "Apple Song" }
    override var artist: String? { "Beyoncé" }
    override var albumArtist: String? { "Beyoncé" }
    override var albumTitle: String? { "Album" }
}
private actor FakeMusicServer {
    let bytes: Data
    let delay: UInt64
    let fileInfo: MusicFile?
    var readCount = 0
    var bytesRead = 0
    var operations: [MusicFileRequest.Operation] = []
    var offline = false
    init(bytes: Data, delay: UInt64 = 0, fileInfo: MusicFile? = nil) { self.bytes = bytes; self.delay = delay; self.fileInfo = fileInfo }
    func setOffline() { offline = true }
    func request(_ data: Data) async throws -> Data {
        if offline { throw MusicFileError("Offline") }
        if delay > 0 { try await Task.sleep(nanoseconds: delay) }
        let request = try JSONDecoder().decode(MusicFileRequest.self, from: data)
        operations.append(request.operation)
        if request.operation == .catalog {
            return try JSONEncoder().encode(MusicFileResponse(files: [fileInfo ?? MusicFile(path: "Artist/Album/Song.wav", version: "v1", size: Int64(bytes.count), title: "Song", artist: "Artist", album: "Album", duration: Double(bytes.count - 44) / 88_200)], generation: "test"))
        }
        readCount += 1; bytesRead += request.length
        return try JSONEncoder().encode(MusicFileResponse(data: bytes.subdata(in: Int(request.offset)..<Int(request.offset) + request.length)))
    }
}

@MainActor final class PodcastRuntimeTests: XCTestCase {
    func testNoHistoryResumeDoesNotTakeAudioOwnership() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = PodcastLibraryController(url: directory.appendingPathComponent("library.json"))
        let player = PodcastPlaybackController(library: library)
        var activations = 0; player.willPlay = { activations += 1 }
        try await player.resumeLastPodcast()
        XCTAssertEqual(activations, 0); XCTAssertNil(player.currentEpisode); XCTAssertFalse(player.isPlaying)
    }
    func testColdRestoreRetainsExactEpisodeAndPositionPaused() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = PodcastLibraryController(url: directory.appendingPathComponent("library.json"))
        let episode = PodcastEpisode(showID: "show", guid: "last", title: "Last Played", publishedAt: Date(), mediaURL: URL(string: "https://example.com/last.mp3")!)
        try library.edit { $0.episodes[episode.id] = episode }
        try library.requireStore().recordPlaybackStarted(episode.id)
        try library.requireStore().recordPosition(episode.id, position: 123.5)
        let restored = PodcastLibraryController(url: directory.appendingPathComponent("library.json"))
        let player = PodcastPlaybackController(library: restored)
        XCTAssertEqual(player.currentEpisode?.id, episode.id); XCTAssertEqual(player.position, 123.5); XCTAssertFalse(player.isPlaying)
    }
    func testRateAndSeekRejectNonFiniteValues() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let player = PodcastPlaybackController(library: PodcastLibraryController(url: directory.appendingPathComponent("library.json")))
        player.setRate(.nan); player.setRate(0); player.setRate(10); player.seek(to: .infinity)
        XCTAssertEqual(player.rate, 1); XCTAssertEqual(player.position, 0)
        player.setRate(1.5); XCTAssertEqual(player.rate, 1.5)
        player.setSleepTimer(minutes: nil, endOfEpisode: true); XCTAssertTrue(player.sleepAtEpisodeEnd)
        player.setSleepTimer(minutes: nil); XCTAssertFalse(player.sleepAtEpisodeEnd)
    }
}
