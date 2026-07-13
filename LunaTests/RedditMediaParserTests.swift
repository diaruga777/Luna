//
//  RedditMediaParserTests.swift
//  LunaTests
//

import LunaMediaDownload
import XCTest

final class RedditMediaParserTests: XCTestCase {
    private func listingJSON(postJSON: String) -> Data {
        Data(#"""
        [{"data":{"children":[{"data":\#(postJSON)}]}},{"data":{"children":[]}}]
        """#.utf8)
    }

    func testSilentVideoResolvesWithoutAudioURL() {
        let data = listingJSON(postJSON: #"""
        {"is_video":true,"secure_media":{"reddit_video":{
            "fallback_url":"https://v.redd.it/abc123def456/DASH_720.mp4?source=fallback",
            "has_audio":false
        }}}
        """#)

        XCTAssertEqual(
            RedditMediaParser.asset(fromListingJSON: data),
            MediaAsset(url: URL(string: "https://v.redd.it/abc123def456/DASH_720.mp4?source=fallback")!, kind: .video))
    }

    func testVideoWithAudioDerivesAudioTrackURL() {
        let data = listingJSON(postJSON: #"""
        {"is_video":true,"media":{"reddit_video":{
            "fallback_url":"https://v.redd.it/abc123def456/DASH_1080.mp4?source=fallback",
            "has_audio":true
        }}}
        """#)

        let asset = RedditMediaParser.asset(fromListingJSON: data)
        XCTAssertEqual(asset?.url, URL(string: "https://v.redd.it/abc123def456/DASH_1080.mp4?source=fallback"))
        XCTAssertEqual(asset?.kind, .video)
        XCTAssertEqual(asset?.audioURL, URL(string: "https://v.redd.it/abc123def456/DASH_audio.mp4"))
    }

    func testCrosspostRecursesIntoParentMedia() {
        let data = listingJSON(postJSON: #"""
        {"is_video":false,"crosspost_parent_list":[{
            "is_video":true,"secure_media":{"reddit_video":{
                "fallback_url":"https://v.redd.it/original111222/DASH_480.mp4?source=fallback",
                "has_audio":false
            }}
        }]}
        """#)

        XCTAssertEqual(
            RedditMediaParser.asset(fromListingJSON: data),
            MediaAsset(url: URL(string: "https://v.redd.it/original111222/DASH_480.mp4?source=fallback")!, kind: .video))
    }

    func testNonVideoPostResolvesToNoAsset() {
        let data = listingJSON(postJSON: #"""
        {"is_video":false,"url":"https://i.redd.it/somepicture.jpg"}
        """#)

        XCTAssertNil(RedditMediaParser.asset(fromListingJSON: data))
    }

    func testMalformedListingResolvesToNoAsset() {
        XCTAssertNil(RedditMediaParser.asset(fromListingJSON: Data("not json".utf8)))
    }
}
