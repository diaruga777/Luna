//
//  MediaPlatformTests.swift
//  LuneTests
//

import LuneSocial
import LunePlatforms
import LuneStorage
import LuneModels
import XCTest
@testable import Lune

final class MediaPlatformTests: XCTestCase {

    func testSpotifyClassification() {
        XCTAssertEqual(MediaLink.classify("https://open.spotify.com/track/abc123"),
                       MediaLink.Match(platform: .music, service: .spotify, itemID: "abc123"))
        XCTAssertEqual(MediaLink.classify("https://open.spotify.com/episode/ep1"),
                       MediaLink.Match(platform: .podcast, service: .spotify, itemID: "ep1"))
        XCTAssertNil(MediaLink.classify("https://example.com/track/x"))
    }

    func testAppleClassification() {
        XCTAssertEqual(
            MediaLink.classify("https://music.apple.com/us/album/x/123?i=456")?.service, .apple)
        XCTAssertEqual(
            MediaLink.classify("https://music.apple.com/us/album/x/123?i=456")?.platform, .music)
        XCTAssertEqual(
            MediaLink.classify("https://podcasts.apple.com/us/podcast/x/id123?i=789")?.platform,
            .podcast)
    }

    func testAppSchemeConversion() {
        XCTAssertEqual(
            MediaLink.appSchemeURL(forWebURL: "https://open.spotify.com/track/abc")?.absoluteString,
            "spotify:track:abc")
        XCTAssertEqual(
            MediaLink.appSchemeURL(forWebURL: "https://music.apple.com/us/album/x/1")?.absoluteString,
            "music://music.apple.com/us/album/x/1")
    }

    func testProviderSearchLinks() {
        XCTAssertEqual(
            MusicProvider.spotify.appSearchURL(query: "a b", platform: .music)?.absoluteString,
            "spotify:search:a%20b")
        XCTAssertTrue(
            MusicProvider.apple.appSearchURL(query: "a b", platform: .music)?.absoluteString
                .hasPrefix("music://music.apple.com/search?term=") ?? false)
    }

    func testApplePodcastSearchUsesPodcastsApp() {
        XCTAssertTrue(
            MusicProvider.apple.appSearchURL(query: "a b", platform: .podcast)?.absoluteString
                .hasPrefix("podcasts://podcasts.apple.com/search?term=") ?? false)
        XCTAssertTrue(
            MusicProvider.apple.webSearchURL(query: "a b", platform: .podcast)?.absoluteString
                .hasPrefix("https://podcasts.apple.com/search?term=") ?? false)
        // Spotify uses one app/scheme for songs and podcasts.
        XCTAssertEqual(
            MusicProvider.spotify.appSearchURL(query: "a b", platform: .podcast)?.absoluteString,
            "spotify:search:a%20b")
    }

    func testRegistryRoutesMediaToMusicAndPodcast() {
        XCTAssertEqual(PlatformRegistry.shared.detect("https://open.spotify.com/track/x")?.platform, .music)
        XCTAssertEqual(PlatformRegistry.shared.detect("https://open.spotify.com/show/y")?.platform, .podcast)
    }

    func testMediaItemKeyAndStoreCreation() {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("Media-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let store = ReadingListStore(containerURL: scratch)

        let item = store.createURLlessMediaItem(platform: .music, creator: "Artist", title: "Song")
        XCTAssertEqual(item.platform, .music)
        XCTAssertEqual(item.mediaCreatorName, "Artist")
        XCTAssertEqual(item.mediaItemTitle, "Song")
        XCTAssertTrue(item.isURLlessMedia)
        XCTAssertTrue(item.urlString.hasPrefix("lunemusic://"))
        // Idempotent on the synthetic key.
        let again = store.createURLlessMediaItem(platform: .music, creator: "Artist", title: "Song")
        XCTAssertEqual(again.id, item.id)
    }

    func testMediaItemMessageRoundTrip() throws {
        let body = MessageBody.mediaItem(kind: .podcast, creator: "Show", title: "Episode 1")
        let decoded = try MessageBody.decoded(from: try body.encoded())
        XCTAssertEqual(decoded, body)
    }
}
