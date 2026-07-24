//
//  RedditMediaParserTests.swift
//  LunaTests
//

import LunaMediaDownload
import LunaModels
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
        // Reddit consistently serves the audio track at this sibling path
        // (confirmed against real DASHPlaylist.mpd manifests) — NOT a
        // DASH_audio.mp4-style filename.
        XCTAssertEqual(asset?.audioURL, URL(string: "https://v.redd.it/abc123def456/audio"))
    }

    func testDashManifestCapturedForMuxingFallback() {
        let data = listingJSON(postJSON: #"""
        {"is_video":true,"media":{"reddit_video":{
            "fallback_url":"https://v.redd.it/abc123def456/DASH_1080.mp4?source=fallback",
            "has_audio":true,
            "dash_url":"https://v.redd.it/abc123def456/DASHPlaylist.mpd?a=1"
        }}}
        """#)

        XCTAssertEqual(
            RedditMediaParser.asset(fromListingJSON: data)?.dashManifestURL,
            URL(string: "https://v.redd.it/abc123def456/DASHPlaylist.mpd?a=1"))
    }

    /// Mirrors the real structure of a Reddit DASHPlaylist.mpd: one
    /// `Representation` per media type nests its own `<BaseURL>`, and the
    /// audio one is identified by `mimeType="audio/mp4"` (not shared at the
    /// `AdaptationSet` level).
    func testAudioURLFromDASHManifestResolvesRelativeBaseURL() {
        let manifestURL = URL(string: "https://v.redd.it/abc123def456/DASHPlaylist.mpd")!
        let manifest = """
        <MPD><Period>
        <AdaptationSet>
        <Representation bandwidth="1000" codecs="avc1.4d401f" height="720" width="1280">
        <BaseURL>DASH_720.mp4</BaseURL>
        </Representation>
        </AdaptationSet>
        <AdaptationSet>
        <Representation audioSamplingRate="48000" bandwidth="131794" codecs="mp4a.40.2" mimeType="audio/mp4">
        <BaseURL>audio</BaseURL>
        </Representation>
        </AdaptationSet>
        </Period></MPD>
        """

        XCTAssertEqual(
            RedditMediaParser.audioURL(fromDASHManifest: manifest, manifestURL: manifestURL),
            URL(string: "https://v.redd.it/abc123def456/audio"))
    }

    func testAudioURLFromDASHManifestReturnsNilWhenNoAudioRepresentation() {
        let manifestURL = URL(string: "https://v.redd.it/abc123def456/DASHPlaylist.mpd")!
        let manifest = """
        <MPD><Period>
        <AdaptationSet>
        <Representation codecs="avc1.4d401f"><BaseURL>DASH_720.mp4</BaseURL></Representation>
        </AdaptationSet>
        </Period></MPD>
        """

        XCTAssertNil(RedditMediaParser.audioURL(fromDASHManifest: manifest, manifestURL: manifestURL))
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
