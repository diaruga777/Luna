//
//  ArticleMatcherTests.swift
//  LunaTests
//

import LunaIntents
import LunaModels
import XCTest

final class ArticleMatcherTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_750_000_000) // a Wednesday

    /// Fixed to UTC so day-boundary math in the "yesterday" test is stable
    /// regardless of the machine's local time zone.
    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func article(
        _ seed: String, title: String, urlString: String? = nil,
        ageDays: Double = 1, readState: SavedItem.ReadState = .unopened,
        state: SavedItem.State = .ready, platform: ContentPlatform? = nil
    ) -> SavedItem {
        SavedItem(
            seed: seed, urlString: urlString ?? "https://example.com/\(seed)", title: title,
            dateAdded: now.addingTimeInterval(-ageDays * 24 * 60 * 60),
            state: state, readState: readState, platform: platform)
    }

    // MARK: - Readability exclusion

    func testSearchExcludesVideosAndProducts() {
        let readable = article("readable", title: "Boston skyline")
        let video = article("video", title: "Boston skyline video", platform: .tiktok)
        let pending = article("pending", title: "Boston skyline pending", state: .pending)
        let results = ArticleMatcher.search(query: "boston", in: [readable, video, pending], now: now)
        XCTAssertEqual(results.map(\.id), [readable.id])
    }

    func testSuggestedExcludesNonReadable() {
        let readable = article("readable", title: "A")
        let video = article("video", title: "B", platform: .instagram)
        XCTAssertEqual(ArticleMatcher.suggested(in: [readable, video]).map(\.id), [readable.id])
    }

    // MARK: - Title matching ("about Boston")

    func testSearchMatchesTitleTokens() {
        let boston = article("boston", title: "The Boston Marathon returns", ageDays: 1)
        let chicago = article("chicago", title: "Chicago's new skyline", ageDays: 1)
        let results = ArticleMatcher.search(query: "about Boston", in: [boston, chicago], now: now)
        XCTAssertEqual(results.first?.id, boston.id)
        XCTAssertFalse(results.contains { $0.id == chicago.id })
    }

    // MARK: - Source matching ("from The Atlantic")

    func testSearchMatchesSourceHostAndHumanName() {
        let atlantic = article(
            "atlantic", title: "A deep dive", urlString: "https://www.theatlantic.com/politics/a", ageDays: 3)
        let other = article("other", title: "A deep dive too", urlString: "https://example.com/b", ageDays: 1)
        let results = ArticleMatcher.search(query: "from The Atlantic", in: [atlantic, other], now: now)
        XCTAssertEqual(results.first?.id, atlantic.id, "source match should outrank a newer, title-only match")
    }

    func testSourceMatchOutranksIncidentalTitleOverlap() {
        // "the" appears in both a title ("The Verge...") and as part of "the
        // atlantic" — the full "atlantic" token match should still win.
        let atlantic = article(
            "atlantic", title: "Piece one", urlString: "https://theatlantic.com/a", ageDays: 5)
        let verge = article(
            "verge", title: "The Verge covers phones", urlString: "https://theverge.com/b", ageDays: 1)
        let results = ArticleMatcher.search(query: "from the atlantic", in: [atlantic, verge], now: now)
        XCTAssertEqual(results.first?.id, atlantic.id)
    }

    // MARK: - Recency ranking / "latest ... from X"

    func testTiedScoresBreakByRecency() {
        let older = article(
            "older", title: "Older Atlantic piece", urlString: "https://theatlantic.com/older", ageDays: 10)
        let newer = article(
            "newer", title: "Newer Atlantic piece", urlString: "https://theatlantic.com/newer", ageDays: 1)
        let results = ArticleMatcher.search(query: "from the atlantic", in: [older, newer], now: now)
        XCTAssertEqual(results.first?.id, newer.id, "latest matching article should rank first")
    }

    // MARK: - Relative-date filtering ("from yesterday")

    func testSearchFiltersByYesterday() {
        let yesterday = article("yesterday", title: "Yesterday's piece", ageDays: 1)
        let today = article("today", title: "Today's piece", ageDays: 0)
        let lastWeek = article("lastweek", title: "Last week's piece", ageDays: 8)
        let results = ArticleMatcher.search(
            query: "yesterday", in: [yesterday, today, lastWeek], now: now, calendar: utcCalendar)
        XCTAssertEqual(results.map(\.id), [yesterday.id])
    }

    func testSearchWithNoMatchesReturnsEmpty() {
        let item = article("a", title: "Something else entirely")
        XCTAssertTrue(ArticleMatcher.search(query: "nonexistentword", in: [item], now: now).isEmpty)
    }

    // MARK: - latestUnread

    func testLatestUnreadPicksNewestUnopenedReadable() {
        let older = article("older", title: "A", ageDays: 5)
        let newer = article("newer", title: "B", ageDays: 1)
        let opened = article("opened", title: "C", ageDays: 0.1, readState: .opened)
        XCTAssertEqual(ArticleMatcher.latestUnread(in: [older, newer, opened])?.id, newer.id)
    }

    func testLatestUnreadNilWhenNoneUnread() {
        let opened = article("opened", title: "A", readState: .read)
        XCTAssertNil(ArticleMatcher.latestUnread(in: [opened]))
    }

    func testLatestUnreadExcludesNonReadable() {
        let video = article("video", title: "A", ageDays: 1, platform: .tiktok)
        let article1 = article("article", title: "B", ageDays: 5)
        XCTAssertEqual(ArticleMatcher.latestUnread(in: [video, article1])?.id, article1.id)
    }

    // MARK: - suggested

    func testSuggestedOrdersNewestFirstAndLimits() {
        let items = (0..<15).map { article("s\($0)", title: "T\($0)", ageDays: Double($0)) }
        let suggested = ArticleMatcher.suggested(in: items, limit: 10)
        XCTAssertEqual(suggested.count, 10)
        XCTAssertEqual(suggested.first?.id, items[0].id)
        XCTAssertEqual(suggested.last?.id, items[9].id)
    }

    func testSuggestedExcludesOpened() {
        let unopened = article("unopened", title: "A")
        let opened = article("opened", title: "B", readState: .opened)
        XCTAssertEqual(ArticleMatcher.suggested(in: [unopened, opened]).map(\.id), [unopened.id])
    }
}
