//
//  ReadingListSubtitleTests.swift
//  ClipTests
//

import ClipReadingListUI
import ClipSend
import ClipModels
import XCTest
@testable import Clip

final class ReadingListSubtitleTests: XCTestCase {

    private func item(
        wordCount: Int? = nil,
        readState: ReadingListItem.ReadState = .unopened,
        progress: Double? = nil,
        state: ReadingListItem.State = .ready,
        youtube: Bool = false
    ) -> ReadingListItem {
        var item = ReadingListItem(urlString: "https://example.com/a")
        item.wordCount = wordCount
        item.readState = readState
        item.readingProgress = progress
        item.state = state
        if youtube { item.youtubeVideoID = "abc" }
        return item
    }

    private func parts(
        _ item: ReadingListItem,
        leadingLabel: String = "example.com",
        date: String = "Jan 1, 2024",
        showReadingTime: Bool = true,
        showReadingProgress: Bool = true
    ) -> [String] {
        ReadingListSubtitle.parts(
            for: item, leadingLabel: leadingLabel, formattedDate: date,
            showReadingTime: showReadingTime, showReadingProgress: showReadingProgress)
    }

    // MARK: - readingTimeMinutes

    func testReadingTimeNilWhenNoWordCount() {
        XCTAssertNil(ReadingListSubtitle.readingTimeMinutes(wordCount: nil))
    }

    func testReadingTimeNilWhenZeroWords() {
        XCTAssertNil(ReadingListSubtitle.readingTimeMinutes(wordCount: 0))
    }

    func testReadingTimeFlooredAtOneMinute() {
        // 10 words / 220 wpm rounds up to 1.
        XCTAssertEqual(ReadingListSubtitle.readingTimeMinutes(wordCount: 10), 1)
    }

    func testReadingTimeRoundsUp() {
        // 221 words / 220 = 1.004 → ceil → 2.
        XCTAssertEqual(ReadingListSubtitle.readingTimeMinutes(wordCount: 221), 2)
    }

    func testReadingTimeExactMultiple() {
        XCTAssertEqual(ReadingListSubtitle.readingTimeMinutes(wordCount: 440), 2)
        XCTAssertEqual(ReadingListSubtitle.readingTimeMinutes(wordCount: 2200), 10)
    }

    // MARK: - parts ordering & content

    func testStartsWithLeadingLabelAndDate() {
        let result = parts(item(), leadingLabel: "nytimes.com", date: "Mar 3, 2024")
        XCTAssertEqual(result[0], "nytimes.com")
        XCTAssertEqual(result[1], "Mar 3, 2024")
    }

    func testIncludesReadingTimeWhenEnabled() {
        XCTAssertTrue(parts(item(wordCount: 660)).contains("3 min"))
    }

    func testOmitsReadingTimeWhenDisabled() {
        XCTAssertFalse(parts(item(wordCount: 660), showReadingTime: false).contains("3 min"))
    }

    func testOmitsReadingTimeForYouTube() {
        XCTAssertFalse(parts(item(wordCount: 660, youtube: true)).contains { $0.hasSuffix("min") })
    }

    func testIncludesProgressPercentWhenInProgress() {
        XCTAssertTrue(parts(item(progress: 0.42)).contains("42%"))
    }

    func testOmitsProgressBelowOnePercent() {
        XCTAssertFalse(parts(item(progress: 0.005)).contains { $0.hasSuffix("%") })
    }

    func testOmitsProgressWhenRead() {
        XCTAssertFalse(
            parts(item(readState: .read, progress: 0.5)).contains { $0.hasSuffix("%") })
    }

    func testOmitsProgressWhenDisabled() {
        XCTAssertFalse(
            parts(item(progress: 0.42), showReadingProgress: false).contains("42%"))
    }

    // MARK: - lifecycle status

    func testPendingShowsDownloading() {
        XCTAssertEqual(parts(item(state: .pending)).last, "downloading…")
    }

    func testFailedShowsRetry() {
        XCTAssertEqual(parts(item(state: .failed)).last, "pull to retry")
    }

    func testNeedsCaptchaShowsUnlock() {
        XCTAssertEqual(parts(item(state: .needsCaptcha)).last, "tap to unlock")
    }

    func testReadyAddsNoLifecyclePart() {
        let result = parts(item(state: .ready))
        XCTAssertFalse(result.contains("downloading…"))
        XCTAssertFalse(result.contains("pull to retry"))
        XCTAssertFalse(result.contains("tap to unlock"))
    }

    // MARK: - send status

    func testSentDestinationShownByName() {
        var i = item()
        i.sendStates[ArticleDestinationID.kindle] = .sent
        XCTAssertTrue(parts(i).contains("sent to Kindle"))
    }

    func testFailedSendShown() {
        var i = item()
        i.sendStates[ArticleDestinationID.boox] = .failed
        XCTAssertTrue(parts(i).contains("Boox send failed"))
    }

    func testQueuedSendShown() {
        var i = item()
        i.sendStates[ArticleDestinationID.kindle] = .queued
        XCTAssertTrue(parts(i).contains("sending to Kindle…"))
    }

    func testMultipleSendStatusesSortedByDestinationID() {
        var i = item()
        i.sendStates[ArticleDestinationID.kindle] = .sent
        i.sendStates[ArticleDestinationID.boox] = .failed
        let result = parts(i)
        let booxIndex = result.firstIndex(of: "Boox send failed")
        let kindleIndex = result.firstIndex(of: "sent to Kindle")
        XCTAssertNotNil(booxIndex)
        XCTAssertNotNil(kindleIndex)
        // "boox" < "kindle" alphabetically.
        XCTAssertLessThan(booxIndex!, kindleIndex!)
    }

    func testUnknownDestinationFallsBackToRawID() {
        var i = item()
        i.sendStates["remarkable"] = .sent
        XCTAssertTrue(parts(i).contains("sent to remarkable"))
    }
}
