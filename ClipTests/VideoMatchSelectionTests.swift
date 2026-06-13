//
//  VideoMatchSelectionTests.swift
//  ClipTests
//

import XCTest
@testable import Clip

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
}
