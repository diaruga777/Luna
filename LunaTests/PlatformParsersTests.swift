//
//  PlatformParsersTests.swift
//  LunaTests
//

import LunaModels
import LunaPlatforms
import LunaURLClassification
import XCTest
@testable import Luna
@testable import LunaPlatforms

final class PlatformParsersTests: XCTestCase {

    func testXParsesAndRejects() {
        XCTAssertEqual(XLink.tweetID(from: "https://x.com/jack/status/20"), "20")
        XCTAssertEqual(
            XLink.tweetID(from: "https://twitter.com/user/status/1234567890123456789"),
            "1234567890123456789")
        XCTAssertNil(XLink.tweetID(from: "https://x.com/jack"))
        XCTAssertNil(XLink.tweetID(from: "https://example.com/user/status/20"))
    }

    /// `XLink` delegates its host check to `PlatformRecognizer`, which
    /// suffix-matches any x.com/twitter.com subdomain rather than a small
    /// fixed set. Any such subdomain parses; none is silently rejected.
    func testXRecognizesAnyTwitterSubdomain() {
        XCTAssertEqual(XLink.tweetID(from: "https://some-other.twitter.com/jack/status/20"), "20")
    }

    func testTikTokRecognizesHostAndVideoID() {
        XCTAssertTrue(TikTokLink.isTikTok("https://www.tiktok.com/@user/video/7212345678901234567"))
        XCTAssertEqual(
            TikTokLink.videoID(from: "https://www.tiktok.com/@user/video/7212345678901234567"),
            "7212345678901234567")
        XCTAssertTrue(TikTokLink.isTikTok("https://vm.tiktok.com/ZMabc/")) // short form
        XCTAssertNil(TikTokLink.videoID(from: "https://vm.tiktok.com/ZMabc/")) // id not in URL
        XCTAssertFalse(TikTokLink.isTikTok("https://example.com/@user/video/1"))
    }

    /// Covers `PlatformRecognizer.recognize`'s Reddit post-id resolution and
    /// `RedditLink.jsonURL`, which builds the JSON API URL from a permalink
    /// without gating on host at all.
    func testRedditParsesPostIDAndJSONURL() {
        let url = "https://www.reddit.com/r/swift/comments/abc123/some_title/"
        XCTAssertEqual(PlatformRecognizer.recognize(url)?.itemID, "abc123")
        XCTAssertEqual(
            RedditLink.jsonURL(for: url)?.absoluteString,
            "https://www.reddit.com/r/swift/comments/abc123/some_title.json")
        XCTAssertNil(PlatformRecognizer.recognize("https://example.com/r/swift/comments/x/y"))
    }

    /// `PlatformRecognizer` classifies Reddit ONLY on an individual post permalink —
    /// a subreddit / home feed (and a subreddit literally named "comments") is not a
    /// reddit item; posts, galleries, and `redd.it/<id>` short links are.
    func testRedditRecognizerRequiresAPost() {
        // Feeds / listings must NOT classify as a reddit item.
        XCTAssertNil(PlatformRecognizer.recognize("https://www.reddit.com/"))
        XCTAssertNil(PlatformRecognizer.recognize("https://www.reddit.com/r/pics/"))
        XCTAssertNil(PlatformRecognizer.recognize("https://www.reddit.com/r/pics/top/"))
        XCTAssertNil(PlatformRecognizer.recognize("https://www.reddit.com/r/comments/top/"))
        XCTAssertNil(PlatformRecognizer.recognize("https://www.reddit.com/user/spez/comments/"))

        // Posts / galleries / short links must classify (with the id extracted).
        let post = PlatformRecognizer.recognize("https://www.reddit.com/r/pics/comments/1abc2d/title/")
        XCTAssertEqual(post?.platform, .reddit)
        XCTAssertEqual(post?.itemID, "1abc2d")
        XCTAssertEqual(PlatformRecognizer.recognize("https://www.reddit.com/comments/1abc2d")?.itemID, "1abc2d")
        XCTAssertEqual(
            PlatformRecognizer.recognize("https://www.reddit.com/user/spez/comments/1abc2d/title/")?.itemID,
            "1abc2d")
        XCTAssertEqual(PlatformRecognizer.recognize("https://www.reddit.com/gallery/1abc2d")?.itemID, "1abc2d")
        XCTAssertEqual(PlatformRecognizer.recognize("https://redd.it/1abc2d")?.itemID, "1abc2d")
    }

    /// Reddit's own app-native share links (`/r/<sub>/s/<token>`) are recognized as
    /// a Reddit post (they need a live HTTP redirect to resolve to a real post,
    /// which pure recognition can't do), but — mirroring TikTok's short links —
    /// `itemID` stays nil since the token isn't a decodable post id.
    func testRedditShareLinkIsRecognizedWithNilItemID() {
        let shareLink = PlatformRecognizer.recognize("https://www.reddit.com/r/WhatsWrongWithYourDog/s/qRjWPbZ2bo")
        XCTAssertEqual(shareLink?.platform, .reddit)
        XCTAssertNil(shareLink?.itemID)

        XCTAssertNil(PlatformRecognizer.recognize("https://www.reddit.com/r/pics/s/"))
        XCTAssertNil(PlatformRecognizer.recognize("https://www.reddit.com/r//s/abc"))
    }

    /// `PlatformRecognizer` is the only Instagram/Facebook recognition Luna
    /// ships; `InstagramPlatform`/`FacebookPlatform` resolve items through it
    /// alone.
    func testInstagramShortcodeViaRecognizer() {
        XCTAssertEqual(
            PlatformRecognizer.recognize("https://www.instagram.com/reel/CxYz123/")?.itemID, "CxYz123")
        XCTAssertEqual(
            PlatformRecognizer.recognize("https://instagram.com/p/AbC/")?.itemID, "AbC")
        XCTAssertNil(PlatformRecognizer.recognize("https://instagram.com/someuser")?.itemID)
        XCTAssertNil(PlatformRecognizer.recognize("https://example.com/p/AbC"))
    }

    func testFacebookRecognitionAndIDViaRecognizer() {
        XCTAssertEqual(
            PlatformRecognizer.recognize("https://www.facebook.com/watch/?v=123")?.platform, .facebook)
        XCTAssertEqual(
            PlatformRecognizer.recognize("https://www.facebook.com/watch/?v=123")?.itemID, "123")
        XCTAssertEqual(
            PlatformRecognizer.recognize("https://facebook.com/reel/456")?.itemID, "456")
        XCTAssertEqual(
            PlatformRecognizer.recognize("https://fb.watch/abcdef/")?.platform, .facebook)
        XCTAssertNil(PlatformRecognizer.recognize("https://example.com/reel/1"))
    }

    func testYouTubeShortRegistersMetadataAndBuildsPublicEndpoints() throws {
        let short = "https://youtube.com/shorts/FOKAYc5u5ws?si=zaOYqz9pQ75wNsNB"
        let match = try XCTUnwrap(PlatformRecognizer.recognize(short))
        XCTAssertEqual(match.platform, .youtube)
        XCTAssertEqual(match.itemID, "FOKAYc5u5ws")
        XCTAssertNotNil(PlatformRegistry.shared.module(for: .youtube)?.metadataFetcher)

        let oEmbed = try XCTUnwrap(YouTubeMetadataFetcher.oEmbedURL(videoID: match.itemID))
        XCTAssertEqual(
            oEmbed.absoluteString,
            "https://www.youtube.com/oembed?url=https://www.youtube.com/watch?v%3DFOKAYc5u5ws&format=json")
        XCTAssertEqual(
            YouTubeMetadataFetcher.thumbnailURL(videoID: match.itemID)?.absoluteString,
            "https://i.ytimg.com/vi/FOKAYc5u5ws/hqdefault.jpg")
    }

}
