//
//  NonTextualContentTests.swift
//  ClipTests
//

import XCTest
@testable import Clip

/// Covers the pure derivations on `NonTextualContent` (embed/preview URLs,
/// labels, and the YouTube-vs-platform branch of `detect`). The underlying URL
/// classification is `PlatformClassifier`'s job (tested separately).
final class NonTextualContentTests: XCTestCase {

    // MARK: - detect

    func testDetectReturnsNilForPlainArticle() {
        XCTAssertNil(NonTextualContent.detect(urlString: "https://example.com/some-article"))
    }

    func testDetectClassifiesYouTubeAsYouTubeCase() {
        guard let content = NonTextualContent.detect(urlString: "https://youtu.be/dQw4w9WgXcQ")
        else { return XCTFail("expected a classification") }
        guard case .youTube(let videoID) = content else {
            return XCTFail("expected .youTube, got \(content)")
        }
        XCTAssertEqual(videoID, "dQw4w9WgXcQ")
        XCTAssertEqual(content.platform, .youtube)
    }

    // MARK: - embedURL

    func testYouTubeEmbedURLUsesEmbedPathWithPlaybackParams() {
        let content = NonTextualContent.youTube(videoID: "abc123")
        guard let url = content.embedURL else { return XCTFail("expected embed URL") }
        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(url.host, "www.youtube.com")
        XCTAssertEqual(url.path, "/embed/abc123")
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let asDict = Dictionary(uniqueKeysWithValues: query.map { ($0.name, $0.value) })
        XCTAssertEqual(asDict["playsinline"], "1")
        XCTAssertEqual(asDict["autoplay"], "1")
        XCTAssertEqual(asDict["rel"], "0")
    }

    func testNonYouTubePlatformHasNoEmbedURL() {
        let content = NonTextualContent.platform(.reddit, itemID: "xyz")
        XCTAssertNil(content.embedURL)
    }

    // MARK: - staticPreviewImageURL

    func testYouTubePreviewImageURL() {
        let content = NonTextualContent.youTube(videoID: "abc123")
        XCTAssertEqual(
            content.staticPreviewImageURL?.absoluteString,
            "https://img.youtube.com/vi/abc123/hqdefault.jpg")
    }

    func testNonYouTubePlatformHasNoPreviewImage() {
        XCTAssertNil(NonTextualContent.platform(.x, itemID: nil).staticPreviewImageURL)
    }

    // MARK: - labels & referer

    func testPlatformPropertyAndKindLabel() {
        XCTAssertEqual(NonTextualContent.platform(.reddit, itemID: nil).platform, .reddit)
        XCTAssertEqual(NonTextualContent.platform(.reddit, itemID: nil).kindLabel, "Reddit")
        XCTAssertEqual(NonTextualContent.youTube(videoID: "x").kindLabel, "YouTube")
    }

    func testEmbedRefererIsNonEmpty() {
        // YouTube rejects embeds without a referer (error 153).
        XCTAssertFalse(NonTextualContent.youTube(videoID: "x").embedReferer.isEmpty)
    }

    // MARK: - Equatable

    func testEquatable() {
        XCTAssertEqual(
            NonTextualContent.youTube(videoID: "a"),
            NonTextualContent.youTube(videoID: "a"))
        XCTAssertNotEqual(
            NonTextualContent.youTube(videoID: "a"),
            NonTextualContent.youTube(videoID: "b"))
        XCTAssertNotEqual(
            NonTextualContent.platform(.x, itemID: "1"),
            NonTextualContent.platform(.reddit, itemID: "1"))
    }
}
