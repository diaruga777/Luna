//
//  AudioQueueRuleTests.swift
//  LunaTests
//

import LunaModels
import LunaAudioPlayback
import XCTest
@testable import Luna

/// The autoplay queue rule (`AudioQueueRule.nextCandidate` in the app shell):
/// top-most unopened, readable Reader-surface article in the reading list's
/// own displayed order, excluding the currently playing item.
final class AudioQueueRuleTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_750_000_000)

    private func fresh(_ seed: String,
                       readState: ReadingListItem.ReadState = .unopened,
                       state: ReadingListItem.State = .ready,
                       platform: ContentPlatform? = nil,
                       ageDays: Double = 1) -> ReadingListItem {
        ReadingListItem(
            seed: seed, urlString: "https://example.com/\(seed)", title: seed,
            dateAdded: now.addingTimeInterval(-ageDays * 24 * 60 * 60),
            state: state, readState: readState, platform: platform)
    }

    private func readableContent(_ title: String = "t") -> ArticleContent {
        ArticleContent(title: title, blocks: [
            ArticleContent.Block(kind: .paragraph, text: "Some real body text.", links: []),
        ])
    }

    private func pick(
        _ items: [ReadingListItem],
        excluding excludedItemID: UUID? = nil,
        contents: [UUID: ArticleContent]? = nil
    ) -> ReadingListItem? {
        let contentByID = contents ?? Dictionary(
            uniqueKeysWithValues: items.map { ($0.id, readableContent()) })
        return AudioQueueRule.nextCandidate(
            items: items, now: now, excludedItemID: excludedItemID,
            content: { contentByID[$0.id] })?.item
    }

    // MARK: - Basic pick & ordering

    func testPicksTopMostUnopenedReadableArticle() {
        let first = fresh("first")
        let second = fresh("second")
        XCTAssertEqual(pick([first, second])?.id, first.id, "list order is respected")
    }

    func testEmptyListYieldsNil() {
        XCTAssertNil(pick([]))
    }

    func testOpenedItemsAreNeverAutoQueued() {
        let opened = fresh("opened", readState: .opened)
        let unopened = fresh("unopened")
        XCTAssertEqual(pick([opened, unopened])?.id, unopened.id,
                       "opened-but-unfinished items are skipped (explicit product decision)")
    }

    func testReadItemsAreSkipped() {
        let read = fresh("read", readState: .read)
        XCTAssertNil(pick([read]))
    }

    func testExcludedItemIsSkipped() {
        let playing = fresh("playing")
        let next = fresh("next")
        XCTAssertEqual(pick([playing, next], excluding: playing.id)?.id, next.id)
    }

    // MARK: - Surface filter

    func testMediaItemsAreSkipped() {
        let video = fresh("video", platform: .tiktok)
        let article = fresh("article")
        XCTAssertEqual(pick([video, article])?.id, article.id,
                       "platform/media items are not Reader-surface articles")
    }

    func testPriceTrackersAreSkipped() {
        var trackerItem = fresh("tracker")
        trackerItem.priceTracker = PriceTracker(
            productName: "Widget",
            stores: [PriceTrackerStore(urlString: "https://shop.example.com/w", lastPrice: 10, currency: "USD")])
        let article = fresh("article")
        XCTAssertEqual(pick([trackerItem, article])?.id, article.id)
    }

    // MARK: - Readability

    func testPendingItemsAreSkipped() {
        let pending = fresh("pending", state: .pending)
        XCTAssertNil(pick([pending]))
    }

    func testPaywalledCaptchaStubsAreSkipped() {
        let locked = fresh("locked", state: .needsCaptcha)
        XCTAssertNil(pick([locked]))
    }

    func testItemsWithoutStoredContentAreSkippedInFavorOfTheNextReadableOne() {
        let missing = fresh("missing")
        let readable = fresh("readable")
        let picked = pick(
            [missing, readable],
            contents: [readable.id: readableContent()])
        XCTAssertEqual(picked?.id, readable.id)
    }

    func testContentWithOnlyEmptyTextBlocksIsNotReadable() {
        let imageOnly = fresh("imageOnly")
        let picked = pick(
            [imageOnly],
            contents: [imageOnly.id: ArticleContent(title: "t", blocks: [
                ArticleContent.Block(kind: .image, text: "", links: []),
            ])])
        XCTAssertNil(picked)
    }

    // MARK: - Section ordering (the displayed order, not raw store order)

    func testFreshReadingItemsComeBeforeAgedOutArchiveItems() {
        // An unopened item older than the archive window displays in the
        // Archive section, BELOW the Reading section — so a fresh unopened
        // item later in raw store order still wins.
        let agedOut = fresh("agedOut", ageDays: 30)
        let freshItem = fresh("fresh", ageDays: 1)
        XCTAssertEqual(pick([agedOut, freshItem])?.id, freshItem.id)
    }

    func testAgedOutUnopenedItemIsStillQueuedWhenNothingFresherExists() {
        let agedOut = fresh("agedOut", ageDays: 30)
        XCTAssertEqual(pick([agedOut])?.id, agedOut.id,
                       "the Archive section is part of the displayed order and still qualifies")
    }

    func testCandidateCarriesTheLoadedContent() {
        let item = fresh("carrier")
        let content = readableContent("Carried Along")
        let candidate = AudioQueueRule.nextCandidate(
            items: [item], now: now, excludedItemID: nil, content: { _ in content })
        XCTAssertEqual(candidate?.content.title, "Carried Along",
                       "the candidate bundles the content so the center never re-hits the store")
    }
}
