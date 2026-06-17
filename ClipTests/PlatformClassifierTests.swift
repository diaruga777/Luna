//
//  PlatformClassifierTests.swift
//  ClipTests
//

import XCTest
@testable import Clip

/// The single classification authority — covers the expanded host variants that
/// previously slipped through and got treated as articles (#10).
final class PlatformClassifierTests: XCTestCase {

    private func platform(_ url: String) -> ContentPlatform? {
        PlatformClassifier.classify(url)?.platform
    }

    func testYouTubeVariants() {
        XCTAssertEqual(platform("https://www.youtube.com/watch?v=dQw4w9WgXcQ"), .youtube)
        XCTAssertEqual(platform("https://youtu.be/dQw4w9WgXcQ"), .youtube)
        XCTAssertEqual(platform("https://m.youtube.com/watch?v=dQw4w9WgXcQ"), .youtube)
        XCTAssertEqual(platform("https://www.youtube.com/shorts/dQw4w9WgXcQ"), .youtube)
    }

    func testXVariants() {
        XCTAssertEqual(platform("https://x.com/a/status/20"), .x)
        XCTAssertEqual(platform("https://twitter.com/a/status/20"), .x)
        XCTAssertEqual(platform("https://mobile.twitter.com/a/status/20"), .x)
        XCTAssertEqual(PlatformClassifier.classify("https://x.com/a/status/20")?.itemID, "20")
    }

    func testTikTokVariants() {
        XCTAssertEqual(platform("https://www.tiktok.com/@u/video/7212345678901234567"), .tiktok)
        XCTAssertEqual(platform("https://vm.tiktok.com/ZMabc/"), .tiktok)
    }

    func testRedditVariants() {
        XCTAssertEqual(platform("https://www.reddit.com/r/swift/comments/abc/t/"), .reddit)
        XCTAssertEqual(platform("https://old.reddit.com/r/swift/comments/abc/t/"), .reddit)
        XCTAssertEqual(platform("https://redd.it/abc123"), .reddit)
    }

    func testInstagramAndFacebookVariants() {
        XCTAssertEqual(platform("https://www.instagram.com/reel/Cx/"), .instagram)
        XCTAssertEqual(platform("https://instagr.am/p/Cx/"), .instagram)
        XCTAssertEqual(platform("https://www.facebook.com/watch/?v=1"), .facebook)
        XCTAssertEqual(platform("https://fb.watch/abc/"), .facebook)
    }

    func testMediaVariants() {
        XCTAssertEqual(platform("https://open.spotify.com/track/abc"), .music)
        XCTAssertEqual(platform("https://open.spotify.com/episode/xyz"), .podcast)
        XCTAssertEqual(platform("https://music.apple.com/us/album/x/1?i=2"), .music)
        XCTAssertEqual(platform("https://podcasts.apple.com/us/podcast/x/id1?i=2"), .podcast)
        XCTAssertEqual(PlatformClassifier.classify("https://open.spotify.com/track/abc")?.sourceService, .spotify)
    }

    func testArticlesAndJunkAreNotPlatforms() {
        XCTAssertNil(platform("https://en.wikipedia.org/wiki/Swift"))
        XCTAssertNil(platform("https://www.nytimes.com/2026/01/01/story.html"))
        XCTAssertNil(platform("not a url"))
    }
}
