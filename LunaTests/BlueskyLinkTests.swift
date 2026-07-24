//
//  BlueskyLinkTests.swift
//  LunaTests
//

import LunaPlatforms
import LunaURLClassification
import XCTest
@testable import Luna

final class BlueskyLinkTests: XCTestCase {

    func testParsesProfilePostURL() {
        let post = BlueskyLink.post(from: "https://bsky.app/profile/alice.bsky.social/post/3kxyz")
        XCTAssertEqual(post?.author, "alice.bsky.social")
        XCTAssertEqual(post?.rkey, "3kxyz")
    }

    func testRejectsForeignAndMalformed() {
        XCTAssertNil(BlueskyLink.post(from: "https://example.com/profile/a/post/b"))
        XCTAssertNil(BlueskyLink.post(from: "https://bsky.app/profile/alice"))
        XCTAssertNil(BlueskyLink.post(from: "https://bsky.app/settings"))
    }

    func testWebURLFromATURI() {
        let url = BlueskyLink.webURL(
            fromATURI: "at://did:plc:abc123/app.bsky.feed.post/3kxyz",
            authorHandle: "alice.bsky.social")
        XCTAssertEqual(url, "https://bsky.app/profile/alice.bsky.social/post/3kxyz")
    }

    func testCanonicalWebURL() {
        XCTAssertEqual(
            BlueskyLink.webURL(author: "bob.bsky.social", rkey: "abc"),
            "https://bsky.app/profile/bob.bsky.social/post/abc")
    }

    func testRegistryClassifiesBluesky() {
        let match = PlatformRegistry.shared.detect("https://bsky.app/profile/a.bsky.social/post/xyz")
        XCTAssertEqual(match?.platform, .bluesky)
        XCTAssertEqual(match?.itemID, "xyz")
    }
}
