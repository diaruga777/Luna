//
//  PlatformRecognizerTests.swift
//  ClipTests
//

import ClipURLClassification
import ClipModels
import XCTest
@testable import Clip

/// Data-driven sweep of `PlatformRecognizer.recognize` over a large table of real
/// example URLs (YouTube / X / Instagram / TikTok / Facebook / Reddit / Bluesky /
/// Spotify / Apple) with their expected platform + itemID, plus negatives. This is
/// where the "YouTube wrongly text-extracted" bug class is permanently pinned:
/// every surface calls this one recognizer.
final class PlatformRecognizerTests: XCTestCase {

    /// One positive expectation: a URL → its platform, optional id, optional service.
    private struct Positive {
        let url: String
        let platform: ContentPlatform
        let itemID: String?
        let service: MusicProvider?
        let kind: PlatformKind
    }

    func testRecognizesPlatformURLs() {
        let cases: [Positive] = [
            // YouTube — video.
            .init(url: "https://www.youtube.com/watch?v=dQw4w9WgXcQ", platform: .youtube, itemID: "dQw4w9WgXcQ", service: nil, kind: .video),
            .init(url: "https://youtu.be/dQw4w9WgXcQ", platform: .youtube, itemID: "dQw4w9WgXcQ", service: nil, kind: .video),
            .init(url: "https://m.youtube.com/watch?v=dQw4w9WgXcQ", platform: .youtube, itemID: "dQw4w9WgXcQ", service: nil, kind: .video),
            .init(url: "https://music.youtube.com/watch?v=dQw4w9WgXcQ", platform: .youtube, itemID: "dQw4w9WgXcQ", service: nil, kind: .video),
            .init(url: "https://www.youtube.com/shorts/abcdefghijk", platform: .youtube, itemID: "abcdefghijk", service: nil, kind: .video),
            .init(url: "https://www.youtube.com/live/abcdefghijk", platform: .youtube, itemID: "abcdefghijk", service: nil, kind: .video),
            .init(url: "https://www.youtube-nocookie.com/embed/abcdefghijk", platform: .youtube, itemID: "abcdefghijk", service: nil, kind: .video),
            .init(url: "https://youtu.be/dQw4w9WgXcQ?si=trackparam", platform: .youtube, itemID: "dQw4w9WgXcQ", service: nil, kind: .video),

            // X / Twitter — social.
            .init(url: "https://x.com/jack/status/20", platform: .x, itemID: "20", service: nil, kind: .social),
            .init(url: "https://twitter.com/u/status/1234567890123456789", platform: .x, itemID: "1234567890123456789", service: nil, kind: .social),
            .init(url: "https://mobile.twitter.com/u/status/20", platform: .x, itemID: "20", service: nil, kind: .social),
            .init(url: "https://x.com/u/statuses/20", platform: .x, itemID: "20", service: nil, kind: .social),
            .init(url: "https://x.com/u/status/20?s=46&t=abc", platform: .x, itemID: "20", service: nil, kind: .social),
            .init(url: "https://x.com/jack", platform: .x, itemID: nil, service: nil, kind: .social),

            // Instagram — social.
            .init(url: "https://www.instagram.com/reel/Cx/", platform: .instagram, itemID: "Cx", service: nil, kind: .social),
            .init(url: "https://instagram.com/p/AbC/", platform: .instagram, itemID: "AbC", service: nil, kind: .social),
            .init(url: "https://instagr.am/p/AbC/", platform: .instagram, itemID: "AbC", service: nil, kind: .social),
            .init(url: "https://www.instagram.com/tv/Xyz/", platform: .instagram, itemID: "Xyz", service: nil, kind: .social),
            .init(url: "https://www.instagram.com/reels/Xyz/", platform: .instagram, itemID: "Xyz", service: nil, kind: .social),
            .init(url: "https://instagram.com/someuser", platform: .instagram, itemID: nil, service: nil, kind: .social),

            // TikTok — video.
            .init(url: "https://www.tiktok.com/@u/video/7212345678901234567", platform: .tiktok, itemID: "7212345678901234567", service: nil, kind: .video),
            .init(url: "https://vm.tiktok.com/ZMabc/", platform: .tiktok, itemID: nil, service: nil, kind: .video),
            .init(url: "https://vt.tiktok.com/ZSabc/", platform: .tiktok, itemID: nil, service: nil, kind: .video),

            // Facebook — video.
            .init(url: "https://www.facebook.com/watch/?v=123", platform: .facebook, itemID: "123", service: nil, kind: .video),
            .init(url: "https://facebook.com/reel/456", platform: .facebook, itemID: "456", service: nil, kind: .video),
            .init(url: "https://www.facebook.com/u/videos/789", platform: .facebook, itemID: "789", service: nil, kind: .video),
            .init(url: "https://fb.watch/abcdef/", platform: .facebook, itemID: nil, service: nil, kind: .video),

            // Reddit — social.
            .init(url: "https://www.reddit.com/r/swift/comments/abc123/title/", platform: .reddit, itemID: "abc123", service: nil, kind: .social),
            .init(url: "https://old.reddit.com/r/swift/comments/abc123/t/", platform: .reddit, itemID: "abc123", service: nil, kind: .social),
            .init(url: "https://redd.it/abc123", platform: .reddit, itemID: "abc123", service: nil, kind: .social),

            // Bluesky — social.
            .init(url: "https://bsky.app/profile/alice.bsky.social/post/3kabc", platform: .bluesky, itemID: "3kabc", service: nil, kind: .social),
            .init(url: "https://bsky.app/profile/did:plc:xyz/post/3kabc", platform: .bluesky, itemID: "3kabc", service: nil, kind: .social),

            // Spotify — audio (music vs podcast split).
            .init(url: "https://open.spotify.com/track/abc", platform: .music, itemID: "abc", service: .spotify, kind: .audio),
            .init(url: "https://open.spotify.com/album/xyz", platform: .music, itemID: "xyz", service: .spotify, kind: .audio),
            .init(url: "https://open.spotify.com/artist/qrs", platform: .music, itemID: "qrs", service: .spotify, kind: .audio),
            .init(url: "https://open.spotify.com/episode/xyz", platform: .podcast, itemID: "xyz", service: .spotify, kind: .audio),
            .init(url: "https://open.spotify.com/show/sho", platform: .podcast, itemID: "sho", service: .spotify, kind: .audio),

            // Apple — audio.
            .init(url: "https://music.apple.com/us/album/x/1?i=2", platform: .music, itemID: "2", service: .apple, kind: .audio),
            .init(url: "https://podcasts.apple.com/us/podcast/x/id1?i=2", platform: .podcast, itemID: "2", service: .apple, kind: .audio),
        ]

        for expected in cases {
            guard let recognized = PlatformRecognizer.recognize(expected.url) else {
                return XCTFail("expected to recognize \(expected.url)")
            }
            XCTAssertEqual(recognized.platform, expected.platform, "platform for \(expected.url)")
            XCTAssertEqual(recognized.itemID, expected.itemID, "itemID for \(expected.url)")
            XCTAssertEqual(recognized.service, expected.service, "service for \(expected.url)")
            XCTAssertEqual(recognized.kind, expected.kind, "kind for \(expected.url)")
        }
    }

    func testNegativesAreNotRecognized() {
        let negatives = [
            "https://en.wikipedia.org/wiki/Swift",
            "https://www.nytimes.com/2026/01/01/story.html",
            "https://www.youtube.com/@channel",            // no video id
            "https://www.youtube.com/feed/subscriptions",  // not a video
            "https://example.com/u/status/20",             // status path on wrong host
            "https://example.com/@u/video/1",              // video path on wrong host
            "https://example.com/r/swift/comments/x/y",    // reddit-shaped wrong host
            "https://bsky.app/profile/alice",              // profile, no post
            "not a url",
            "mailto:x@y.com",
            "clipdoc://abc-123",
        ]
        for input in negatives {
            XCTAssertNil(PlatformRecognizer.recognize(input), "must not recognize \(input)")
        }
    }

    /// The single platform row in `Classifier`'s table is gated on the union of
    /// every rule's hosts; this proves adding a rule extends that gate automatically.
    func testPlatformHostsGateDerivedFromRules() {
        XCTAssertTrue(Classifier.platformHosts.contains("youtube.com"))
        XCTAssertTrue(Classifier.platformHosts.contains("spotify.com"))
        XCTAssertTrue(Classifier.platformHosts.contains("bsky.app"))
    }
}
