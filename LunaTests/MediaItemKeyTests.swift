//
//  MediaItemKeyTests.swift
//  LunaTests
//

import LunaURLClassification
import XCTest
@testable import Luna

final class MediaItemKeyTests: XCTestCase {

    private func components(_ key: String) -> URLComponents? {
        URLComponents(string: key)
    }

    private func queryValue(_ key: String, _ name: String) -> String? {
        components(key)?.queryItems?.first { $0.name == name }?.value
    }

    func testMusicUsesLunaMusicSchemeAndArtistKey() {
        let key = MediaItemKey.url(platform: .music, creator: "Aphex Twin", title: "Xtal")
        XCTAssertEqual(components(key)?.scheme, "lunamusic")
        XCTAssertEqual(components(key)?.host, "item")
        XCTAssertEqual(queryValue(key, "artist"), "Aphex Twin")
        XCTAssertEqual(queryValue(key, "title"), "Xtal")
        XCTAssertNil(queryValue(key, "show"))
    }

    func testPodcastUsesLunaPodcastSchemeAndShowKey() {
        let key = MediaItemKey.url(platform: .podcast, creator: "The Daily", title: "Monday Episode")
        XCTAssertEqual(components(key)?.scheme, "lunapodcast")
        XCTAssertEqual(queryValue(key, "show"), "The Daily")
        XCTAssertEqual(queryValue(key, "title"), "Monday Episode")
        XCTAssertNil(queryValue(key, "artist"))
    }

    func testPercentEncodesSpecialCharacters() {
        let key = MediaItemKey.url(platform: .music, creator: "AC/DC", title: "Back & Forth")
        // Round-trips back to the original values once decoded.
        XCTAssertEqual(queryValue(key, "artist"), "AC/DC")
        XCTAssertEqual(queryValue(key, "title"), "Back & Forth")
    }

    func testNonPodcastPlatformDefaultsToMusicShape() {
        // Anything that isn't .podcast takes the music scheme/key.
        let key = MediaItemKey.url(platform: .youtube, creator: "Creator", title: "Title")
        XCTAssertEqual(components(key)?.scheme, "lunamusic")
        XCTAssertEqual(queryValue(key, "artist"), "Creator")
    }

    func testEmptyValuesStillProduceValidKey() {
        let key = MediaItemKey.url(platform: .music, creator: "", title: "")
        XCTAssertTrue(key.hasPrefix("lunamusic://item"))
    }
}
