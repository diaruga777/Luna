@testable import LunaMusicCore
import Intents
import UIKit
import XCTest
@testable import LunaMusicApp

final class MusicSiriPlaybackTests: XCTestCase {
    private let library = [
        LibraryMusicEntity(id: "artist:abba", name: "ABBA", detail: "Artist", artist: "ABBA"),
        LibraryMusicEntity(id: "album:one", name: "ABBA", detail: "Album", artist: "ABBA", album: "ABBA"),
        LibraryMusicEntity(id: "song:one", name: "SOS", detail: "ABBA", artist: "ABBA", album: "ABBA"),
        LibraryMusicEntity(id: "song:two", name: "SOS", detail: "Rihanna", artist: "Rihanna"),
        LibraryMusicEntity(id: "playlist:one", name: "ABBA Favourites", detail: "Playlist")
    ]

    private func request(_ type: INMediaItemType, title: String? = nil, artist: String? = nil,
                         album: String? = nil, item: INMediaItem? = nil) -> INPlayMediaIntent {
        let search = INMediaSearch(mediaType: type, sortOrder: .unknown, mediaName: title, artistName: artist,
                                   albumName: album, genreNames: nil, moodNames: nil, releaseDate: nil,
                                   reference: .unknown, mediaIdentifier: nil)
        return INPlayMediaIntent(mediaItems: item.map { [$0] }, mediaContainer: nil, playShuffled: nil,
                                 playbackRepeatMode: .unknown, resumePlayback: nil, playbackQueueLocation: .now,
                                 playbackSpeed: nil, mediaSearch: search)
    }

    func testPlayABBAResolvesTheArtist() {
        for intent in [request(.music, title: "abba"), request(.unknown, artist: "ABBA"),
                       request(.artist, title: "ABBA"), request(.song, artist: "ABBA")] {
            XCTAssertEqual(MusicSiriPlayback.matches(for: intent, in: library).map(\.id), ["artist:abba"])
        }
    }

    func testSongArtistAlbumAndPlaylistConstraints() {
        for (intent, ids) in [
            (request(.song, title: "SOS", artist: "ABBA"), ["song:one"]),
            (request(.song, title: "SOS"), ["song:one", "song:two"]),
            (request(.song, title: "SOS", artist: "Queen"), []),
            (request(.album, album: "ABBA"), ["album:one"]),
            (request(.playlist, title: "abba favourites"), ["playlist:one"]),
            (request(.playlist, title: "SOS"), [])
        ] {
            XCTAssertEqual(MusicSiriPlayback.matches(for: intent, in: library).map(\.id), ids)
        }
    }

    func testChosenItemIsPlayedByItsStableID() {
        let item = INMediaItem(identifier: "song:two", title: "SOS", type: .song, artwork: nil)
        let intent = request(.song, title: "SOS", item: item)
        XCTAssertEqual(MusicSiriPlayback.matches(for: intent, in: library).map(\.id), ["song:two"])
        XCTAssertTrue(MusicSiriPlayback.matches(for: intent, in: Array(library.prefix(3))).isEmpty)
    }

    @MainActor func testFirstLoadWaitsForConcurrentLibraryPublication() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let vault = VaultMusicController(directory: directory)
        var state = VaultMusicState()
        state.files = [MusicFile(path: "SOS.mp3", version: "1", size: 1, title: "SOS", artist: "ABBA", album: "ABBA")]
        try vault.save(state)

        let library = MusicLibraryController(vault: vault)
        // Initialization and the two refreshes can all request different snapshots.
        async let refresh: Void = library.reload(refreshVault: false)
        await library.reload(refreshVault: false)
        XCTAssertTrue(library.artists.contains { $0.representativeItem?.artist == "ABBA" })
        await refresh
    }

    @MainActor func testHostAdvertisesMusicAndSuppliesTheSiriHandler() async throws {
        let info = try XCTUnwrap(Bundle.main.infoDictionary)
        XCTAssertTrue((info["INIntentsSupported"] as? [String])?.contains("INPlayMediaIntent") == true)
        XCTAssertTrue((info["INSupportedMediaCategories"] as? [String])?.contains("INMediaCategoryMusic") == true)
        let app = UIApplication.shared
        let delegate = try XCTUnwrap(app.delegate as? MusicAppDelegate)
        let intent = request(.playlist, title: UUID().uuidString)
        let handler = try XCTUnwrap(delegate.application(app, handlerFor: intent) as? MusicSiriPlayback)
        XCTAssertTrue(handler.responds(to: NSSelectorFromString("resolveMediaItemsForPlayMedia:withCompletion:")))
        XCTAssertTrue(handler.responds(to: NSSelectorFromString("handlePlayMedia:completion:")))
        let response = await handler.handle(intent: intent)
        XCTAssertTrue([.failure, .failureRequiringAppLaunch].contains(response.code))
    }
}
