import XCTest
import AVFoundation
@testable import LunaPodcastCore
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

@MainActor final class PodcastRegressionTests: XCTestCase {
    func testPlaybackPreparesSpokenAudioAndDoesNotQueueTheShow() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = PodcastLibraryController(url: directory.appendingPathComponent("library.json"))
        let media = try XCTUnwrap(Bundle(for: VaultMusicTests.self).url(forResource: "streaming", withExtension: "mp4"))
        let episode = PodcastEpisode(showID: "show", guid: "one", title: "One", publishedAt: Date(), mediaURL: media)
        let other = PodcastEpisode(showID: "show", guid: "two", title: "Two", publishedAt: .distantPast, mediaURL: media)
        try library.edit { $0.episodes = [episode.id: episode, other.id: other]; $0.continuation = [other.id] }
        let player = PodcastPlaybackController(library: library)
        defer { player.pause() }
        try await player.play(episode)
        XCTAssertEqual(AVAudioSession.sharedInstance().category, .playback)
        XCTAssertEqual(AVAudioSession.sharedInstance().mode, .spokenAudio)
        XCTAssertFalse(AVAudioSession.sharedInstance().categoryOptions.contains(.allowAirPlay))
        XCTAssertNotNil(player.player.currentItem)
        XCTAssertNil(player.errorMessage)
        XCTAssertTrue(library.state.queue.isEmpty)
        XCTAssertTrue(library.state.continuation.isEmpty)
        for _ in 0..<100 {
            if player.isPlaying || player.errorMessage != nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertNil(player.errorMessage)
        XCTAssertTrue(player.isPlaying, "The local podcast fixture must actually start playback")
    }

    func testOldAutomaticBacklogIsDiscardedButExplicitQueueSurvives() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("library.json")
        let store = try PodcastStore(url: url)
        let episode = PodcastEpisode(showID: "show", guid: "one", title: "One", publishedAt: Date(), mediaURL: URL(string: "https://example.com/one.mp3")!)
        try store.update { $0.episodes[episode.id] = episode; $0.currentEpisodeID = episode.id; $0.queue = ["explicit"]; $0.continuation = ["automatic"] }
        let restored = try PodcastStore(url: url)
        XCTAssertEqual(restored.state.queue, ["explicit"])
        XCTAssertTrue(restored.state.continuation.isEmpty)
        // Also ignore a stale backlog if introduced after loading.
        try restored.update { $0.queue = []; $0.continuation = [episode.id] }
        XCTAssertNil(try restored.finishNaturally(episode.id))
        XCTAssertTrue(restored.state.naturallyExhaustedQueue)
    }

    func testRepeatedDirectoryTapsPushOnlyOnceAndShowLoading() async throws {
        let controller = DelayedPodcastList()
        let navigation = UINavigationController(rootViewController: controller)
        navigation.loadViewIfNeeded(); controller.loadViewIfNeeded()
        let result = PodcastDirectoryResult(id: "test", title: "Test", author: "", collectionID: "test")
        controller.sections = [.init(title: "Shows", rows: [.directory(result)])]
        controller.openDirectory(result); controller.openDirectory(result)
        XCTAssertEqual(controller.openingDirectoryID, result.id)
        XCTAssertFalse(controller.table.allowsSelection)
        let cell = controller.tableView(controller.table, cellForRowAt: IndexPath(row: 0, section: 0))
        XCTAssertEqual(cell.accessoryView?.accessibilityIdentifier, "podcasts.opening")
        await controller.directoryTask?.value
        XCTAssertEqual(controller.loads, 1)
        XCTAssertEqual(navigation.viewControllers.count, 2)
        XCTAssertNil(controller.openingDirectoryID)
        XCTAssertTrue(controller.table.allowsSelection)
    }

    func testCancelledDirectoryLoadDoesNotPush() async throws {
        let controller = DelayedPodcastList()
        let navigation = UINavigationController(rootViewController: controller)
        controller.loadViewIfNeeded()
        controller.openDirectory(PodcastDirectoryResult(id: "test", title: "Test", author: "", collectionID: "test"))
        let task = controller.directoryTask
        controller.cancelDirectoryOpening()
        await task?.value
        XCTAssertEqual(navigation.viewControllers.count, 1)
        XCTAssertTrue(controller.table.allowsSelection)
    }

    func testPresentedPlayerFollowsQueueSwitchInBothDirections() async throws {
        let coordinator = MediaPlaybackCoordinator.shared
        coordinator.install()
        let previous = coordinator.active
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let host = UIViewController(); window.rootViewController = host; window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            if previous == .music { MusicPlaybackController.shared.willPlay?() }
            else { PodcastPlaybackController.shared.willPlay?() }
        }
        MusicPlaybackController.shared.willPlay?()
        let music = MusicPlayerViewController(showQueue: true)
        host.present(music, animated: false)
        // Exercise the same surface notifications sent by a successful switch,
        // without requiring an Apple Music account in the simulator.
        PodcastPlaybackController.shared.willPlay?()
        for _ in 0..<40 {
            if let navigation = host.presentedViewController as? UINavigationController,
               (navigation.topViewController as? PodcastPlayerViewController)?.showsQueue == true,
               navigation.topViewController?.viewIfLoaded?.window != nil,
               !navigation.isBeingPresented { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(((host.presentedViewController as? UINavigationController)?.topViewController as? PodcastPlayerViewController)?.showsQueue, true)
        MusicPlaybackController.shared.willPlay?()
        for _ in 0..<40 {
            if host.presentedViewController is MusicPlayerViewController { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(host.presentedViewController is MusicPlayerViewController)
        XCTAssertEqual(host.presentedViewController?.view.accessibilityIdentifier, "music.playback.queue")
        host.dismiss(animated: false)
    }

    func testSearchShowsHorizonLoadingAndClearingCancelsIt() {
        let controller = PodcastBrowserViewController()
        let owner = UIViewController()
        controller.loadViewIfNeeded(); controller.navigationOwner = owner; controller.mode = 3
        let search = owner.navigationItem.searchController!
        search.searchBar.text = "Some More News"
        controller.updateSearchResults(for: search)
        XCTAssertTrue(controller.isSearching)
        XCTAssertEqual(controller.table.tableFooterView?.subviews.first?.accessibilityIdentifier, "podcasts.loading")
        search.searchBar.text = ""
        controller.updateSearchResults(for: search)
        XCTAssertFalse(controller.isSearching)
    }
}

@MainActor private final class DelayedPodcastList: PodcastListViewController {
    var loads = 0
    override func directoryDestination(_ result: PodcastDirectoryResult) async throws -> UIViewController {
        loads += 1
        try await Task.sleep(for: .milliseconds(50))
        return UIViewController()
    }
}

@MainActor final class PodcastLoadingTests: XCTestCase {
    private func library() -> (PodcastLibraryController, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PodcastLoadingProtocol.self]
        return (PodcastLibraryController(url: root.appendingPathComponent("library.json"), session: URLSession(configuration: configuration)), root)
    }
    func testPrefetchedShowOpensWithoutSecondFetchOrFollowing() async throws {
        let (library, root) = library(); defer { try? FileManager.default.removeItem(at: root) }
        let url = URL(string: "https://podcast.test/\(UUID()).xml")!
        let result = PodcastDirectoryResult(id: "show", title: "Show", author: "", feedURL: url, collectionID: "show")
        await library.prefetch(result)
        XCTAssertTrue(library.state.shows.isEmpty)
        let id = try await library.addFeed(url, follow: false)
        XCTAssertEqual(PodcastLoadingProtocol.count(url), 1)
        XCTAssertEqual(library.state.shows[id]?.followed, false)
        _ = try await library.addFeed(url, follow: false)
        XCTAssertEqual(PodcastLoadingProtocol.count(url), 1)
    }
    func testTargetedRefreshIsNotLostBehindAnotherShowRefresh() async throws {
        let (library, root) = library(); defer { try? FileManager.default.removeItem(at: root) }
        let first = PodcastShow(feedURL: URL(string: "https://podcast.test/\(UUID()).xml")!, title: "First")
        let second = PodcastShow(feedURL: URL(string: "https://podcast.test/\(UUID()).xml")!, title: "Second")
        try library.edit { $0.shows = [first.id: first, second.id: second] }
        async let a: Void = library.refresh(showIDs: [first.id], force: true)
        async let b: Void = library.refresh(showIDs: [second.id], force: true)
        _ = await (a, b)
        XCTAssertNotNil(library.state.shows[first.id]?.lastRefresh)
        XCTAssertNotNil(library.state.shows[second.id]?.lastRefresh)
        XCTAssertFalse(library.isRefreshing)
        XCTAssertTrue(library.refreshingShowIDs.isEmpty)
    }
    func testCategoryShowsLoadingImmediately() {
        let controller = PodcastCategoryViewController(category: ("1303", "Comedy"))
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [PodcastLoadingProtocol.self]
        controller.directory = PodcastDirectory(session: URLSession(configuration: configuration))
        controller.loadViewIfNeeded()
        XCTAssertEqual(controller.table.tableFooterView?.subviews.first?.accessibilityIdentifier, "podcasts.loading")
    }
    func testFailedAudioClearsLoadingAndSurfacesError() async throws {
        guard let base = ProcessInfo.processInfo.environment["LUNA_PODCAST_STREAM_FIXTURE_URL"], let url = URL(string: base) else { throw XCTSkip("Run with the local podcast fixture.") }
        let (library, root) = library(); defer { try? FileManager.default.removeItem(at: root) }
        let episode = PodcastEpisode(showID: "missing", guid: UUID().uuidString, title: "Missing", publishedAt: Date(), mediaURL: url.deletingLastPathComponent().appendingPathComponent("missing.mp4"))
        try library.edit { $0.episodes[episode.id] = episode }
        let player = PodcastPlaybackController(library: library); defer { player.pause() }
        try? await player.play(episode)
        for _ in 0..<50 {
            if player.errorMessage != nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertNotNil(player.errorMessage)
        XCTAssertFalse(player.isBuffering); XCTAssertFalse(player.isPlaying)
        XCTAssertFalse(player.isLoadingChapters)
    }
    func testPauseWhileAudioIsLoadingClearsSpinnerAndDoesNotStartLater() async throws {
        guard let base = ProcessInfo.processInfo.environment["LUNA_PODCAST_STREAM_FIXTURE_URL"], let url = URL(string: base) else { throw XCTSkip("Run with the throttled local podcast fixture.") }
        let (library, root) = library(); defer { try? FileManager.default.removeItem(at: root) }
        let episode = PodcastEpisode(showID: "delayed", guid: UUID().uuidString, title: "Delayed", publishedAt: Date(), mediaURL: url.deletingLastPathComponent().appendingPathComponent("delayed.mp4"))
        try library.edit { $0.episodes[episode.id] = episode }
        let player = PodcastPlaybackController(library: library)
        let request = Task { try await player.play(episode) }
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(player.isBuffering); XCTAssertFalse(player.isPlaying)
        player.pause(); XCTAssertFalse(player.isBuffering)
        _ = try? await request.value
        try await Task.sleep(for: .seconds(2.5))
        XCTAssertFalse(player.isPlaying); XCTAssertFalse(player.isBuffering)
    }
    func testRemoteAudioStartsBeforeWholeFileArrives() async throws {
        guard let base = ProcessInfo.processInfo.environment["LUNA_PODCAST_STREAM_FIXTURE_URL"], let url = URL(string: base) else { throw XCTSkip("Run with the throttled local podcast fixture.") }
        let (library, root) = library(); defer { try? FileManager.default.removeItem(at: root) }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "session", value: UUID().uuidString)]
        let mediaURL = components.url!
        var episode = PodcastEpisode(showID: "stream", guid: UUID().uuidString, title: "Incremental stream", publishedAt: Date(), mediaURL: mediaURL)
        episode.artworkURL = url.deletingLastPathComponent().appendingPathComponent("slow-art.png")
        episode.chaptersURL = url.deletingLastPathComponent().appendingPathComponent("chapters.json")
        episode.transcripts = [.init(url: url.deletingLastPathComponent().appendingPathComponent("transcript.vtt"), type: "text/vtt")]
        try library.edit { $0.episodes[episode.id] = episode }
        let player = PodcastPlaybackController(library: library); defer { player.pause() }
        let started = Date()
        try await player.play(episode)
        for _ in 0..<150 {
            if player.isPlaying || player.errorMessage != nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertNil(player.errorMessage); XCTAssertTrue(player.isPlaying)
        XCTAssertLessThan(Date().timeIntervalSince(started), 15)
        for _ in 0..<10 {
            if !player.isLoadingTranscript && !player.isLoadingChapters { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(player.transcript.first?.text.trimmingCharacters(in: .whitespacesAndNewlines), "Ready before artwork.")
        XCTAssertEqual(player.chapters.first?.title, "Introduction")
        XCTAssertLessThan(Date().timeIntervalSince(started), 3, "Slow artwork must not delay audio, transcripts, or chapters")
        components.path = "/stats"
        let statsURL = components.url!
        let (data, _) = try await URLSession.shared.data(from: statsURL)
        let stats = try JSONDecoder().decode([String: Int].self, from: data)
        XCTAssertLessThan(try XCTUnwrap(stats["bytes"]), try XCTUnwrap(stats["total"]), "Playback must start before the entire asset is delivered")
        player.pause(); XCTAssertFalse(player.isBuffering)
    }
}

private final class PodcastLoadingProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var requests: [URL: Int] = [:]
    private var work: DispatchWorkItem?
    static func count(_ url: URL) -> Int { lock.lock(); defer { lock.unlock() }; return requests[url] ?? 0 }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        Self.lock.lock(); Self.requests[url, default: 0] += 1; Self.lock.unlock()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let data = Data("<rss version=\"2.0\"><channel><title>Fixture</title><item><guid>one</guid><title>Episode</title><enclosure url=\"https://podcast.test/one.mp3\" type=\"audio/mpeg\"/></item></channel></rss>".utf8)
            self.client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["ETag": "v1"])!, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: data); self.client?.urlProtocolDidFinishLoading(self)
        }
        self.work = work; DispatchQueue.global().asyncAfter(deadline: .now() + 0.1, execute: work)
    }
    override func stopLoading() { work?.cancel() }
}

@MainActor final class PodcastPlayerLayoutTests: XCTestCase {
    private var window: UIWindow?
    private var directory: URL!
    private var previousSurface: MediaPlaybackCoordinator.Surface!
    override func setUp() {
        super.setUp()
        MediaPlaybackCoordinator.shared.install()
        previousSurface = MediaPlaybackCoordinator.shared.active
        PodcastPlaybackController.shared.willPlay?()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }
    override func tearDown() {
        window?.isHidden = true; window = nil
        try? FileManager.default.removeItem(at: directory)
        if previousSurface == .music { MusicPlaybackController.shared.willPlay?() }
        super.tearDown()
    }
    private func fixture(queue: Bool = false, size: CGSize = CGSize(width: 393, height: 852), category: UIContentSizeCategory = .large) throws -> (PodcastPlayerViewController, PodcastLibraryController) {
        let library = PodcastLibraryController(url: directory.appendingPathComponent("library.json"))
        let show = PodcastShow(feedURL: URL(string: "https://example.com/feed")!, title: "Odd Lots")
        let artURL = URL(string: "https://example.com/layout-art")!
        let image = UIGraphicsImageRenderer(size: CGSize(width: 400, height: 400)).image { context in
            UIColor(red: 0.18, green: 0.03, blue: 0.3, alpha: 1).setFill(); context.fill(CGRect(x: 0, y: 0, width: 400, height: 400))
            ("Odd Lots" as NSString).draw(at: CGPoint(x: 35, y: 265), withAttributes: [.font: UIFont.systemFont(ofSize: 65), .foregroundColor: UIColor.white])
        }
        PodcastUI.images.setObject(image, forKey: artURL as NSURL)
        var episode = PodcastEpisode(showID: show.id, guid: "current", title: "How AI Is Upending the World of Work and Everything Else", publishedAt: Date(timeIntervalSince1970: 1791504000), mediaURL: URL(string: "https://example.com/audio.mp3")!)
        episode.artworkURL = artURL; episode.duration = 3621
        var next = episode; next.id = "next"; next.title = "Nate Soares on How AI Risk Changes the World"; next.duration = 4571
        next.summary = String(repeating: "A long description that must not squeeze the queue title. ", count: 20)
        try library.edit { state in
            state.shows[show.id] = show; state.episodes[episode.id] = episode; state.episodes[next.id] = next
            state.lastPlayedEpisodeID = episode.id; state.queue = [next.id]
        }
        let controller = PodcastPlayerViewController(showQueue: queue, player: PodcastPlaybackController(library: library), library: library)
        let navigation = UINavigationController(rootViewController: controller)
        navigation.traitOverrides.preferredContentSizeCategory = category
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene); window.frame = CGRect(origin: .zero, size: size)
        self.window = window; window.rootViewController = navigation; window.makeKeyAndVisible()
        navigation.view.layoutIfNeeded(); controller.view.layoutIfNeeded()
        return (controller, library)
    }
    private func descendants<T: UIView>(_ view: UIView, _ type: T.Type) -> [T] {
        (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants($0, type) }
    }
    private func capture(_ name: String) throws {
        let window = try XCTUnwrap(window)
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
        let attachment = XCTAttachment(image: image); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        try image.pngData()?.write(to: URL(fileURLWithPath: "/tmp/\(name).png"))
    }
    func testQueueMorphKeepsPlaybackControlsAndNavigationInPlace() throws {
        let (controller, _) = try fixture()
        let slider = try XCTUnwrap(descendants(controller.view, UISlider.self).first)
        let volume = try XCTUnwrap(descendants(controller.view, MPVolumeView.self).first)
        let button = try XCTUnwrap(descendants(controller.view, UIButton.self).first { $0.accessibilityIdentifier == "podcasts.playback.queueButton" })
        let sliderFrame = slider.frame, volumeFrame = volume.frame
        try capture("Podcast-player-artwork")
        button.sendActions(for: .touchUpInside)
        controller.setQueue(true, animated: false); controller.view.layoutIfNeeded()
        XCTAssertTrue(controller.showsQueue)
        XCTAssertEqual(controller.navigationController?.viewControllers.count, 1)
        XCTAssertTrue(controller.navigationController?.isNavigationBarHidden == true)
        XCTAssertEqual(slider.frame, sliderFrame); XCTAssertEqual(volume.frame, volumeFrame)
        XCTAssertEqual(button.accessibilityValue, "Shown")
        let queue = try XCTUnwrap(controller.children.first as? PodcastQueueViewController)
        queue.view.layoutIfNeeded(); queue.table.layoutIfNeeded()
        let cell = try XCTUnwrap(queue.table.cellForRow(at: IndexPath(row: 0, section: 0)) as? PodcastPlayerQueueCell)
        XCTAssertEqual(cell.heading.numberOfLines, 1); XCTAssertEqual(cell.detail.numberOfLines, 1)
        XCTAssertEqual(queue.tableView(queue.table, editingStyleForRowAt: IndexPath(row: 0, section: 0)), .none)
        XCTAssertFalse(queue.tableView(queue.table, shouldIndentWhileEditingRowAt: IndexPath(row: 0, section: 0)))
        XCTAssertGreaterThan(cell.heading.bounds.width, 150)
        try capture("Podcast-player-queue")
        controller.setQueue(false, animated: false); controller.view.layoutIfNeeded()
        XCTAssertFalse(controller.showsQueue); XCTAssertEqual(slider.frame, sliderFrame); XCTAssertEqual(volume.frame, volumeFrame)
    }
    func testSmallLandscapeAndLargeTextKeepMetadataAboveTimeline() throws {
        for (size, category) in [(CGSize(width: 320, height: 568), UIContentSizeCategory.large), (CGSize(width: 393, height: 852), .extraExtraExtraLarge), (CGSize(width: 852, height: 393), .large)] {
            let (controller, _) = try fixture(size: size, category: category)
            let title = try XCTUnwrap(descendants(controller.view, PodcastPlayerTitleView.self).first)
            let slider = try XCTUnwrap(descendants(controller.view, UISlider.self).first)
            let titleRect = title.convert(title.bounds, to: controller.view)
            XCTAssertGreaterThanOrEqual(title.bounds.height, title.font.lineHeight - 1)
            XCTAssertGreaterThan(title.bounds.width, 100)
            if size.width < size.height { XCTAssertLessThan(titleRect.maxY, slider.frame.minY) }
            for button in descendants(controller.view, UIButton.self).filter({ ["Playback Speed", "Sleep Timer", "Play", "Playing Next"].contains($0.accessibilityLabel ?? "") }) {
                XCTAssertGreaterThanOrEqual(button.bounds.height, 44)
            }
            controller.setQueue(true, animated: false); controller.view.layoutIfNeeded()
            try capture("Podcast-player-\(Int(size.width))-\(category.rawValue)")
            window?.isHidden = true
        }
    }
    func testScrubberCommitsAccessibilityAndTouchReleasePositions() throws {
        let (controller, library) = try fixture()
        let slider = try XCTUnwrap(descendants(controller.view, UISlider.self).first)
        XCTAssertGreaterThanOrEqual(slider.bounds.height, 44)
        slider.value = 123; slider.sendActions(for: .valueChanged)
        let id = try XCTUnwrap(library.state.lastPlayedEpisodeID)
        XCTAssertEqual(library.state.progress[id]?.position ?? -1, 123, accuracy: 0.001)
        slider.value = 456; slider.sendActions(for: .touchUpOutside)
        XCTAssertEqual(library.state.progress[id]?.position ?? -1, 456, accuracy: 0.001)
    }
    func testQueueRemovalAndClearEditOnlyUpcomingEpisodes() throws {
        let (controller, library) = try fixture(queue: true)
        let queue = try XCTUnwrap(controller.children.first as? PodcastQueueViewController)
        queue.view.layoutIfNeeded(); queue.table.layoutIfNeeded()
        let id = try XCTUnwrap(library.state.queue.first)
        let path = IndexPath(row: 0, section: 0)
        let cell = queue.tableView(queue.table, cellForRowAt: path)
        let action = try XCTUnwrap(cell.accessibilityCustomActions?.first)
        XCTAssertTrue(action.actionHandler?(action) == true)
        XCTAssertTrue(library.state.queue.isEmpty)
        XCTAssertNotNil(library.state.lastPlayedEpisodeID)
        try library.edit { $0.queue = [id] }
        let clear = try XCTUnwrap(descendants(queue.view, UIButton.self).first { $0.accessibilityLabel == "Clear Queue" })
        clear.isEnabled = true; clear.sendActions(for: .touchUpInside)
        XCTAssertTrue(library.state.queue.isEmpty); XCTAssertNotNil(library.state.lastPlayedEpisodeID)
    }
}

@MainActor final class PodcastQueueDownloadTests: XCTestCase {
    private func fixture(cap: Int64, sizesKnown: Bool = true) throws -> (PodcastLibraryController, PodcastDownloads, [PodcastEpisode], URL) {
        guard let base = ProcessInfo.processInfo.environment["LUNA_PODCAST_DOWNLOAD_FIXTURE_URL"], let url = URL(string: base) else {
            throw XCTSkip("Run with the local podcast download fixture.")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let library = PodcastLibraryController(url: root.appendingPathComponent("library.json"))
        let episodes = (0..<3).map { index -> PodcastEpisode in
            var episode = PodcastEpisode(showID: "local", guid: "episode-\(index)", title: "Episode \(index)", publishedAt: Date(), mediaURL: url.appendingPathComponent(index == 1 ? "two.wav" : "one.wav"))
            episode.mediaType = "audio/wav"; episode.duration = 30
            episode.byteCount = sizesKnown ? 480_044 : 0
            return episode
        }
        try library.edit {
            $0.episodes = Dictionary(uniqueKeysWithValues: episodes.map { ($0.id, $0) })
            $0.currentEpisodeID = episodes[0].id; $0.lastPlayedEpisodeID = episodes[0].id
            $0.queue = episodes.dropFirst().map(\.id); $0.settings.downloadByteLimit = cap
        }
        let downloads = PodcastDownloads(directory: root.appendingPathComponent("Downloads"), library: library, sessionConfiguration: .ephemeral)
        return (library, downloads, episodes, root)
    }
    private func waitUntil(file: StaticString = #filePath, line: UInt = #line, _ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(20)
        while !predicate(), Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        guard predicate() else {
            XCTFail("Podcast download/playback did not settle within 20 seconds", file: file, line: line)
            throw PodcastError("Podcast fixture timed out")
        }
    }
    func testQueueDownloadsWithinCapAndRestoresPausedEpisodeFromDisk() async throws {
        let (library, downloads, episodes, root) = try fixture(cap: 960_088, sizesKnown: false)
        defer { downloads.stop(); try? FileManager.default.removeItem(at: root) }
        await downloads.reconcile()
        try await waitUntil { downloads.localURL(episodes[1].id) != nil }
        XCTAssertNotNil(downloads.localURL(episodes[0].id))
        XCTAssertNil(downloads.localURL(episodes[2].id)); XCTAssertEqual(downloads.totalBytes, 960_088)
        let restored = PodcastDownloads(directory: root.appendingPathComponent("Downloads"), library: library, sessionConfiguration: .ephemeral)
        defer { restored.stop() }
        await restored.start()
        XCTAssertNotNil(restored.localURL(episodes[0].id)); XCTAssertEqual(restored.totalBytes, 960_088)
        let player = PodcastPlaybackController(library: library, downloads: restored)
        player.player.isMuted = true
        defer { player.pause(); player.player.replaceCurrentItem(with: nil) }
        try await player.resume()
        XCTAssertTrue((player.player.currentItem?.asset as? AVURLAsset)?.url.isFileURL == true)
        try await waitUntil { player.isPlaying }
        player.pause(); try await player.resume()
        XCTAssertTrue((player.player.currentItem?.asset as? AVURLAsset)?.url.isFileURL == true)
    }
    func testQueueReorderEvictsLowerPriorityAndEnqueueTriggersDownload() async throws {
        let (library, downloads, episodes, root) = try fixture(cap: 960_088)
        defer { downloads.stop(); try? FileManager.default.removeItem(at: root) }
        await downloads.reconcile(); try await waitUntil { downloads.localURL(episodes[1].id) != nil }
        try library.requireStore().enqueue(episodes[2].id, next: true)
        try await waitUntil { downloads.localURL(episodes[2].id) != nil }
        XCTAssertNotNil(downloads.localURL(episodes[0].id)); XCTAssertNil(downloads.localURL(episodes[1].id))
        XCTAssertEqual(downloads.totalBytes, 960_088)
    }
    func testNaturalCompletionDeletesAndRefillsIncludingSleepAtEnd() async throws {
        let (library, downloads, episodes, root) = try fixture(cap: 960_088)
        defer { downloads.stop(); try? FileManager.default.removeItem(at: root) }
        await downloads.reconcile(); try await waitUntil { downloads.localURL(episodes[1].id) != nil }
        let player = PodcastPlaybackController(library: library, downloads: downloads)
        player.player.isMuted = true
        defer { player.pause(); player.player.replaceCurrentItem(with: nil) }
        try await player.resume(); try await waitUntil { player.isPlaying }
        let firstFile = try XCTUnwrap(downloads.localURL(episodes[0].id))
        // Deliver AVPlayer's natural-end event directly: Simulator audio output
        // can stall its clock, while this still exercises the real end observer.
        NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: player.player.currentItem)
        try await waitUntil { player.currentEpisode?.id == episodes[1].id && player.isPlaying }
        try await waitUntil { downloads.localURL(episodes[2].id) != nil }
        XCTAssertNil(downloads.localURL(episodes[0].id)); XCTAssertFalse(FileManager.default.fileExists(atPath: firstFile.path))
        XCTAssertTrue((player.player.currentItem?.asset as? AVURLAsset)?.url.isFileURL == true)
        XCTAssertEqual(downloads.totalBytes, 960_088)
        player.setSleepTimer(minutes: nil, endOfEpisode: true)
        // Deliver AVPlayer's natural-end event directly: Simulator audio output
        // can stall its clock, while this still exercises the real end observer.
        NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: player.player.currentItem)
        try await waitUntil { library.state.progress[episodes[1].id]?.listened == true && downloads.localURL(episodes[1].id) == nil }
        XCTAssertFalse(player.isPlaying); XCTAssertEqual(library.state.queue, [episodes[2].id])
        XCTAssertNotNil(downloads.localURL(episodes[2].id))
    }
    func testUnderreportedEnclosureCannotExceedCapOrSkipQueueOrder() async throws {
        let (library, downloads, episodes, root) = try fixture(cap: 100_000)
        defer { downloads.stop(); try? FileManager.default.removeItem(at: root) }
        try library.edit { $0.episodes[episodes[0].id]?.byteCount = 1 }
        await downloads.reconcile()
        try await waitUntil { downloads.downloads[episodes[0].id]?.bytes == 480_044 && downloads.downloads[episodes[0].id]?.status == "waiting" }
        XCTAssertEqual(downloads.totalBytes, 0)
        XCTAssertNil(downloads.localURL(episodes[0].id)); XCTAssertNil(downloads.downloads[episodes[1].id])
    }
}

@MainActor final class PodcastTransportTests: XCTestCase {
    private var root: URL!
    private var playback: PodcastPlaybackController!
    private var downloads: PodcastDownloads!
    private var library: PodcastLibraryController!
    private var episodes: [PodcastEpisode] = []
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        library = PodcastLibraryController(url: root.appendingPathComponent("library.json"))
        let media = try XCTUnwrap(Bundle(for: VaultMusicTests.self).url(forResource: "streaming", withExtension: "mp4"))
        episodes = (0..<3).map {
            var episode = PodcastEpisode(showID: "transport", guid: "\($0)", title: "Transport \($0)", publishedAt: Date(), mediaURL: media)
            episode.duration = 180; return episode
        }
        try library.edit { $0.episodes = Dictionary(uniqueKeysWithValues: episodes.map { ($0.id, $0) }); $0.settings.downloadByteLimit = 0 }
        downloads = PodcastDownloads(directory: root.appendingPathComponent("Downloads"), library: library, sessionConfiguration: .ephemeral)
        playback = PodcastPlaybackController(library: library, downloads: downloads)
    }
    override func tearDown() {
        playback.pause(); playback = nil; downloads.stop(); downloads = nil
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }
    private func waitFor(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<150 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTFail("Playback did not settle: \(playback.errorMessage ?? "no error")", file: file, line: line)
        throw PodcastError("Transport test timed out")
    }
    private func startQueue() async throws {
        try await playback.playEpisodes(episodes)
        try await waitFor { playback.isPlaying }
    }
    func testRapidSeeksWhilePlayingAndPausedCommitLatestTarget() async throws {
        try await startQueue()
        playback.seek(to: 30); playback.seek(to: 90); playback.seek(to: 60)
        try await waitFor { abs(playback.player.currentTime().seconds - 60) < 2 && playback.isPlaying }
        playback.pause(); playback.seek(to: 120); playback.seek(to: 45)
        try await waitFor { abs(playback.player.currentTime().seconds - 45) < 0.2 }
        try await Task.sleep(for: .seconds(1))
        XCTAssertFalse(playback.isPlaying); XCTAssertEqual(playback.player.rate, 0)
        XCTAssertEqual(playback.position, 45, accuracy: 0.2)
        XCTAssertEqual(library.state.progress[episodes[0].id]?.position ?? -1, 45, accuracy: 0.2)
        try await playback.resume(); try await waitFor { playback.isPlaying }
        XCTAssertEqual(playback.position, 45, accuracy: 2)
    }
    func testSeekOnColdRestoredPlayerPersistsAndResumesAtTarget() async throws {
        try library.requireStore().recordPlaybackStarted(episodes[0].id)
        try library.requireStore().recordPosition(episodes[0].id, position: 20)
        library.reloadState()
        playback = PodcastPlaybackController(library: library, downloads: downloads)
        playback.seek(to: 80)
        XCTAssertNil(playback.player.currentItem)
        XCTAssertEqual(library.state.progress[episodes[0].id]?.position, 80)
        try await playback.resume(); try await waitFor { playback.isPlaying }
        XCTAssertEqual(playback.player.currentTime().seconds, 80, accuracy: 2)
    }
    func testSeekToEndAdvancesExplicitQueueWithoutNaturalFallback() async throws {
        try await startQueue()
        playback.seek(to: playback.duration)
        try await waitFor { playback.currentEpisode?.id == episodes[1].id && playback.isPlaying }
        XCTAssertEqual(library.state.queue, [episodes[2].id])
        XCTAssertTrue(library.state.progress[episodes[0].id]?.listened == true)
        XCTAssertFalse(library.state.naturallyExhaustedQueue)
        playback.seek(to: playback.duration)
        try await waitFor { playback.currentEpisode?.id == episodes[2].id && playback.isPlaying }
        playback.seek(to: playback.duration)
        try await waitFor { playback.player.currentItem == nil }
        XCTAssertFalse(library.state.naturallyExhaustedQueue)
        try await playback.resume(); try await waitFor { playback.isPlaying }
        XCTAssertLessThan(playback.position, 2)
    }
    func testPauseImmediatelyAfterTerminalSeekWinsOverQueuedPlay() async throws {
        try await startQueue()
        playback.seek(to: playback.duration); playback.pause()
        try await waitFor { playback.currentEpisode?.id == episodes[1].id }
        XCTAssertFalse(playback.isPlaying); XCTAssertNil(playback.player.currentItem)
    }
    func testActualAudioEndAdvancesQueueAndFinalItemCanReplay() async throws {
        try await playback.playEpisodes(Array(episodes.prefix(2)))
        try await waitFor { playback.isPlaying }
        playback.seek(to: 179)
        try await waitFor { playback.currentEpisode?.id == episodes[1].id && playback.isPlaying }
        playback.seek(to: 179)
        try await waitFor { playback.player.currentItem == nil }
        XCTAssertTrue(library.state.naturallyExhaustedQueue)
        try await playback.resume(); try await waitFor { playback.isPlaying }
        XCTAssertLessThan(playback.position, 2)
    }
    func testMissingFeedDurationRecoversSavedEOFIntoQueuedEpisode() async throws {
        var episode = episodes[0]; episode.duration = 0
        try library.edit { $0.episodes[episode.id] = episode; $0.queue = [episodes[1].id] }
        try library.requireStore().recordPlaybackStarted(episode.id)
        try library.requireStore().recordPosition(episode.id, position: 180)
        library.reloadState()
        playback = PodcastPlaybackController(library: library, downloads: downloads)
        try await playback.resume(); try await waitFor { playback.isPlaying }
        XCTAssertEqual(playback.currentEpisode?.id, episodes[1].id)
    }
    func testSeekBackIntoCompletedEpisodeResumesChosenPosition() async throws {
        try await playback.play(episodes[0]); try await waitFor { playback.isPlaying }
        playback.seek(to: playback.duration)
        try await waitFor { playback.player.currentItem == nil }
        playback.seek(to: 45)
        try await playback.resume(); try await waitFor { playback.isPlaying }
        XCTAssertEqual(playback.player.currentTime().seconds, 45, accuracy: 2)
        XCTAssertFalse(library.state.progress[episodes[0].id]?.listened == true)
    }
    func testNativePlayerPauseCannotBeUndoneBySeek() async throws {
        try await startQueue(); playback.player.pause()
        try await waitFor { !playback.isPlaying && !playback.isBuffering }
        playback.seek(to: 60)
        try await waitFor { abs(playback.player.currentTime().seconds - 60) < 0.2 }
        XCTAssertEqual(playback.player.rate, 0)
        playback.player.playImmediately(atRate: playback.rate)
        try await waitFor { playback.isPlaying }
        playback.toggle()
        XCTAssertFalse(playback.isPlaying); XCTAssertEqual(playback.player.rate, 0)
    }
    func testPausedSeekToEndPreparesNextWithoutStartingAudio() async throws {
        try await startQueue(); playback.pause()
        playback.seek(to: playback.duration)
        try await waitFor { playback.currentEpisode?.id == episodes[1].id }
        try await Task.sleep(for: .seconds(1))
        XCTAssertFalse(playback.isPlaying); XCTAssertFalse(playback.isBuffering)
        XCTAssertEqual(playback.position, 0); XCTAssertNil(playback.player.currentItem)
        try await playback.resume(); try await waitFor { playback.isPlaying }
        XCTAssertEqual(playback.currentEpisode?.id, episodes[1].id)
    }
    func testDuplicateEndAndLateEndAfterPauseCannotAutoplay() async throws {
        try await startQueue()
        let first = try XCTUnwrap(playback.player.currentItem)
        NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: first)
        NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: first)
        try await waitFor { playback.currentEpisode?.id == episodes[1].id && playback.isPlaying }
        XCTAssertEqual(library.state.queue, [episodes[2].id])
        playback.pause()
        NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: playback.player.currentItem)
        try await Task.sleep(for: .seconds(1))
        XCTAssertEqual(playback.currentEpisode?.id, episodes[1].id)
        XCTAssertFalse(playback.isPlaying); XCTAssertEqual(library.state.queue, [episodes[2].id])
    }
    func testRestorationRecoversTerminalPositionAndPendingNextPaused() throws {
        try library.requireStore().recordPlaybackStarted(episodes[0].id)
        try library.requireStore().recordPosition(episodes[0].id, position: 180)
        try library.edit { $0.queue = [episodes[1].id, episodes[2].id] }
        playback = PodcastPlaybackController(library: library, downloads: downloads)
        XCTAssertEqual(playback.currentEpisode?.id, episodes[1].id)
        XCTAssertEqual(playback.position, 0); XCTAssertFalse(playback.isPlaying)
        XCTAssertEqual(library.state.lastPlayedEpisodeID, episodes[0].id)
        XCTAssertEqual(library.state.queue, [episodes[2].id])
        let restored = PodcastPlaybackController(library: library, downloads: downloads)
        XCTAssertEqual(restored.currentEpisode?.id, episodes[1].id)
    }
    func testSpeedWhilePausedDoesNotStartPlaybackAndSkipsSeek() async throws {
        try await startQueue(); playback.pause(); playback.setRate(1.75)
        playback.seek(to: 60)
        try await waitFor { abs(playback.player.currentTime().seconds - 60) < 0.2 }
        playback.skip(backward: true)
        try await waitFor { abs(playback.player.currentTime().seconds - 45) < 0.2 }
        playback.skip(backward: false)
        try await waitFor { abs(playback.player.currentTime().seconds - 75) < 0.2 }
        XCTAssertEqual(playback.player.rate, 0)
        try await playback.resume(); try await waitFor { playback.isPlaying }
        XCTAssertEqual(playback.player.rate, 1.75)
    }
}
