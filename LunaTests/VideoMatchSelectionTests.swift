//
//  VideoMatchSelectionTests.swift
//  LunaTests
//

import LunaYouTubeAPI
import XCTest
@testable import Luna

final class VideoMatchSelectionTests: XCTestCase {

    private let candidates = [
        YouTubeSearchResult(videoID: "aaaaaaaaaaa", title: "Swift Concurrency Explained — Part 2"),
        YouTubeSearchResult(videoID: "bbbbbbbbbbb", title: "Swift Concurrency Explained"),
        YouTubeSearchResult(videoID: "ccccccccccc", title: "Totally Different Video"),
    ]

    func testExactMatchBeatsEarlierPrefixMatch() {
        let match = VideoMatchSelection.bestMatch(
            title: "swift concurrency explained", candidates: candidates)
        XCTAssertEqual(match?.videoID, "bbbbbbbbbbb")
    }

    func testPrefixMatchWhenNoExact() {
        let match = VideoMatchSelection.bestMatch(
            title: "Swift Concurrency", candidates: candidates)
        XCTAssertEqual(match?.videoID, "aaaaaaaaaaa")
    }

    func testFallsBackToTopResult() {
        let match = VideoMatchSelection.bestMatch(
            title: "Unrelated Query", candidates: candidates)
        XCTAssertEqual(match?.videoID, "aaaaaaaaaaa")
    }

    func testEmptyCandidates() {
        XCTAssertNil(VideoMatchSelection.bestMatch(title: "anything", candidates: []))
    }

    func testIgnoresPunctuationAndCase() {
        let match = VideoMatchSelection.bestMatch(
            title: "swift concurrency explained!!!", candidates: candidates)
        XCTAssertEqual(match?.videoID, "bbbbbbbbbbb")
    }

    func testSubstringMatch() {
        let match = VideoMatchSelection.bestMatch(
            title: "concurrency explained", candidates: candidates)
        // Not a prefix of any candidate, but contained in both a and b → first (a).
        XCTAssertEqual(match?.videoID, "aaaaaaaaaaa")
    }

    func testAllWordsPresentOutOfOrder() {
        let match = VideoMatchSelection.bestMatch(
            title: "explained part concurrency", candidates: candidates)
        XCTAssertEqual(match?.videoID, "aaaaaaaaaaa")
    }
}
