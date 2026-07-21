//
//  PlatformParsersTests.swift
//  LunaTests
//

import LunaModels
import LunaPlatforms
import LunaURLClassification
import XCTest
@testable import Luna

final class PlatformParsersTests: XCTestCase {

    func testXParsesAndRejects() {
        XCTAssertEqual(XLink.tweetID(from: "https://x.com/jack/status/20"), "20")
        XCTAssertEqual(
            XLink.tweetID(from: "https://twitter.com/user/status/1234567890123456789"),
            "1234567890123456789")
        XCTAssertNil(XLink.tweetID(from: "https://x.com/jack"))
        XCTAssertNil(XLink.tweetID(from: "https://example.com/user/status/20"))
    }

    /// `XLink` delegates its host check to `PlatformRecognizer`, which suffix-matches
    /// ANY x.com/twitter.com subdomain — not just the small fixed set `XLink` used to
    /// hardcode. A subdomain outside that old fixed set now parses instead of
    /// silently returning nil.
    func testXRecognizesAnyTwitterSubdomain() {
        XCTAssertEqual(XLink.tweetID(from: "https://some-other.twitter.com/jack/status/20"), "20")
        XCTAssertEqual(XLink.handle(from: "https://some-other.twitter.com/jack/status/20"), "@jack")
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

    /// `RedditLink.isReddit`/`.postID` had zero production callers (`.subreddit`,
    /// the one caller that used to gate on `.isReddit`, doesn't) and duplicated a
    /// narrower version of `PlatformRecognizer.reddit`'s host/post logic; both were
    /// deleted as dead code. `.jsonURL` doesn't gate on host at all and is unchanged.
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

    /// `InstagramLink`/`FacebookLink` (the presentation-layer parsers these used to
    /// test) had zero production callers — `InstagramPlatform`/`FacebookPlatform`
    /// never invoked them — and were deleted as dead code. `PlatformRecognizer` is
    /// the only Instagram/Facebook recognition Luna ships.
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

    func testRegistryDispatchesAcrossPlatforms() {
        let registry = PlatformRegistry.shared
        XCTAssertEqual(registry.detect("https://x.com/a/status/20")?.platform, .x)
        XCTAssertEqual(registry.detect("https://www.tiktok.com/@a/video/7212345678901234567")?.platform, .tiktok)
        XCTAssertEqual(registry.detect("https://www.reddit.com/r/s/comments/abc/t/")?.platform, .reddit)
        XCTAssertEqual(registry.detect("https://www.instagram.com/reel/Cx/")?.platform, .instagram)
        XCTAssertEqual(registry.detect("https://fb.watch/abc/")?.platform, .facebook)
        XCTAssertNil(registry.detect("https://en.wikipedia.org/wiki/Swift"))
    }
}
