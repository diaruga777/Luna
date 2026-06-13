//
//  YouTubeURLTests.swift
//  ClipTests
//

import XCTest
@testable import Clip

final class YouTubeURLTests: XCTestCase {

    func testRecognizedShapes() {
        let id = "dQw4w9WgXcQ"
        let urls = [
            "https://www.youtube.com/watch?v=\(id)",
            "https://youtube.com/watch?v=\(id)&t=43s",
            "https://m.youtube.com/watch?v=\(id)",
            "https://music.youtube.com/watch?v=\(id)",
            "https://youtu.be/\(id)",
            "https://youtu.be/\(id)?si=share-junk",
            "https://www.youtube.com/shorts/\(id)",
            "https://www.youtube.com/embed/\(id)",
            "https://www.youtube.com/live/\(id)",
            "https://www.youtube.com/v/\(id)",
        ]
        for url in urls {
            XCTAssertEqual(YouTubeURL.videoID(from: url), id, "failed: \(url)")
        }
    }

    func testRejectedShapes() {
        let urls = [
            "https://example.com/watch?v=dQw4w9WgXcQ",
            "https://www.youtube.com/",
            "https://www.youtube.com/channel/UC123",
            "https://www.youtube.com/watch",
            "https://www.youtube.com/watch?v=tooShort",
            "https://www.youtube.com/watch?v=way-too-long-to-be-an-id",
            "https://youtu.be/",
            "not a url",
            "https://notyoutube.com/watch?v=dQw4w9WgXcQ",
        ]
        for url in urls {
            XCTAssertNil(YouTubeURL.videoID(from: url), "should reject: \(url)")
        }
    }

    func testHelpers() {
        XCTAssertEqual(
            YouTubeURL.watchURLString(videoID: "dQw4w9WgXcQ"),
            "https://www.youtube.com/watch?v=dQw4w9WgXcQ")
        XCTAssertEqual(
            YouTubeURL.appURL(videoID: "dQw4w9WgXcQ")?.scheme, "youtube")
        XCTAssertEqual(
            YouTubeURL.thumbnailURL(videoID: "dQw4w9WgXcQ")?.host, "img.youtube.com")
    }
}
