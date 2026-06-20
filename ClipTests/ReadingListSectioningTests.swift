//
//  ReadingListSectioningTests.swift
//  ClipTests
//

import XCTest
@testable import Clip

final class ReadingListSectioningTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_000_000_000)

    /// Builds an article item (renders as reader) with controllable state/age.
    private func article(
        addedDaysAgo: Double = 0,
        readState: ReadingListItem.ReadState = .unopened,
        state: ReadingListItem.State = .ready,
        bumpDaysAgo: Double? = nil
    ) -> ReadingListItem {
        var item = ReadingListItem(urlString: "https://example.com/\(UUID().uuidString)")
        item.dateAdded = now.addingTimeInterval(-addedDaysAgo * 86_400)
        item.readState = readState
        item.state = state
        if let bumpDaysAgo { item.bumpDate = now.addingTimeInterval(-bumpDaysAgo * 86_400) }
        return item
    }

    private func youtube(readState: ReadingListItem.ReadState = .unopened) -> ReadingListItem {
        var item = ReadingListItem(urlString: "https://youtu.be/\(UUID().uuidString)")
        item.youtubeVideoID = "abc123"
        item.readState = readState
        item.state = .ready
        return item
    }

    private func platformItem(readState: ReadingListItem.ReadState = .unopened) -> ReadingListItem {
        var item = ReadingListItem(urlString: "https://x.com/x/status/1")
        item.platform = .x
        item.readState = readState
        item.state = .ready
        return item
    }

    /// Builds a price-tracker item with a controllable discount + archived flag.
    private func priceTracker(
        initial: String = "100", best: String? = nil,
        threshold: Double = 0.10, archived: Bool = false
    ) -> ReadingListItem {
        var item = ReadingListItem(urlString: "https://shop.example/\(UUID().uuidString)")
        var tracker = PriceTracker(
            productName: "Widget", firstStoreURL: item.urlString,
            price: Decimal(string: initial)!, currency: "USD", alertThresholdFraction: threshold)
        if let best {
            tracker.setPrice(Decimal(string: best)!, currency: "USD",
                             urlString: item.urlString, at: now)
        }
        tracker.isArchived = archived
        item.priceTracker = tracker
        item.state = .ready
        return item
    }

    // MARK: - rendersAsReader

    func testArticleRendersAsReader() {
        XCTAssertTrue(ReadingListSectioning.rendersAsReader(article()))
    }

    func testYouTubeDoesNotRenderAsReader() {
        XCTAssertFalse(ReadingListSectioning.rendersAsReader(youtube()))
    }

    func testPlatformItemDoesNotRenderAsReader() {
        XCTAssertFalse(ReadingListSectioning.rendersAsReader(platformItem()))
    }

    // MARK: - assignSections

    func testFreshUnreadArticleGoesToReading() {
        let buckets = ReadingListSectioning.assignSections(items: [article(addedDaysAgo: 1)], now: now)
        XCTAssertEqual(buckets.reading.count, 1)
        XCTAssertTrue(buckets.archive.isEmpty)
        XCTAssertTrue(buckets.failed.isEmpty)
    }

    func testReadArticleGoesToArchiveEvenWhenFresh() {
        let buckets = ReadingListSectioning.assignSections(
            items: [article(addedDaysAgo: 0, readState: .read)], now: now)
        XCTAssertEqual(buckets.archive.count, 1)
        XCTAssertTrue(buckets.reading.isEmpty)
    }

    func testUnreadButAgedOutGoesToArchive() {
        let buckets = ReadingListSectioning.assignSections(
            items: [article(addedDaysAgo: 8)], now: now)
        XCTAssertEqual(buckets.archive.count, 1)
        XCTAssertTrue(buckets.reading.isEmpty)
    }

    func testExactlySevenDaysOldStaysInReading() {
        // archiveAge is a strict `>` boundary: exactly 7 days is still Reading.
        let buckets = ReadingListSectioning.assignSections(
            items: [article(addedDaysAgo: 7)], now: now)
        XCTAssertEqual(buckets.reading.count, 1)
        XCTAssertTrue(buckets.archive.isEmpty)
    }

    func testFailedItemGoesToErrorRegardlessOfAgeOrReadState() {
        let freshFailed = article(addedDaysAgo: 0, readState: .unopened, state: .failed)
        let buckets = ReadingListSectioning.assignSections(items: [freshFailed], now: now)
        XCTAssertEqual(buckets.failed.count, 1)
        XCTAssertTrue(buckets.reading.isEmpty)
        XCTAssertTrue(buckets.archive.isEmpty)
    }

    func testSectionsPreserveInputOrder() {
        let a = article(addedDaysAgo: 1)
        let b = article(addedDaysAgo: 2)
        let buckets = ReadingListSectioning.assignSections(items: [a, b], now: now)
        XCTAssertEqual(buckets.reading.map(\.id), [a.id, b.id])
    }

    func testMixedItemsSplitAcrossAllThreeBuckets() {
        let reading = article(addedDaysAgo: 1)
        let archivedByAge = article(addedDaysAgo: 10)
        let archivedByRead = article(addedDaysAgo: 0, readState: .read)
        let failed = article(state: .failed)
        let buckets = ReadingListSectioning.assignSections(
            items: [reading, archivedByAge, archivedByRead, failed], now: now)
        XCTAssertEqual(buckets.reading.map(\.id), [reading.id])
        XCTAssertEqual(Set(buckets.archive.map(\.id)), [archivedByAge.id, archivedByRead.id])
        XCTAssertEqual(buckets.failed.map(\.id), [failed.id])
    }

    // MARK: - price-tracking section

    func testPriceTrackerGoesToPriceTrackingBucketNotReading() {
        let buckets = ReadingListSectioning.assignSections(items: [priceTracker()], now: now)
        XCTAssertEqual(buckets.priceTracking.count, 1)
        XCTAssertTrue(buckets.reading.isEmpty)
    }

    func testArchivedTrackerExcludedFromAllBuckets() {
        let buckets = ReadingListSectioning.assignSections(
            items: [priceTracker(archived: true)], now: now)
        XCTAssertTrue(buckets.priceTracking.isEmpty)
        XCTAssertTrue(buckets.reading.isEmpty)
    }

    func testAlertingTrackerFloatsOutOfSection() {
        // A tracker dropped 30% (> 10% threshold) is alerting → pulled to the top
        // and excluded from the price-tracking section body.
        let alerting = priceTracker(initial: "100", best: "70")
        let calm = priceTracker(initial: "100", best: "98")
        let buckets = ReadingListSectioning.assignSections(items: [alerting, calm], now: now)
        XCTAssertEqual(buckets.priceTracking.map(\.id), [calm.id])
        XCTAssertEqual(ReadingListSectioning.topAlertingPriceTracker(items: [alerting, calm])?.id,
                       alerting.id)
    }

    func testTopAlertingPicksGreatestDiscount() {
        let small = priceTracker(initial: "100", best: "85")  // 15% off
        let big = priceTracker(initial: "100", best: "50")    // 50% off
        XCTAssertEqual(
            ReadingListSectioning.topAlertingPriceTracker(items: [small, big])?.id, big.id)
    }

    func testNoAlertingTrackerWhenNoneCrossThreshold() {
        let calm = priceTracker(initial: "100", best: "95")
        XCTAssertNil(ReadingListSectioning.topAlertingPriceTracker(items: [calm]))
    }

    func testHasPriceTrackersIgnoresArchived() {
        XCTAssertFalse(ReadingListSectioning.hasPriceTrackers(items: [priceTracker(archived: true)]))
        XCTAssertTrue(ReadingListSectioning.hasPriceTrackers(items: [priceTracker()]))
    }

    func testPriceFilterSegmentIncludesOnlyTrackers() {
        XCTAssertTrue(ReadingListSectioning.ListFilter.priceTrackers.includes(priceTracker()))
        XCTAssertFalse(ReadingListSectioning.ListFilter.priceTrackers.includes(article()))
        XCTAssertFalse(ReadingListSectioning.ListFilter.mediaAndLinks.includes(priceTracker()))
    }

    func testFilterShownWithReaderAndPriceTracker() {
        XCTAssertTrue(ReadingListSectioning.shouldShowFilter(items: [article(), priceTracker()]))
    }

    func testFilterHiddenWithOnlyPriceTrackers() {
        XCTAssertFalse(ReadingListSectioning.shouldShowFilter(
            items: [priceTracker(), priceTracker()]))
    }

    // MARK: - shouldShowFilter

    func testFilterHiddenWhenOnlyArticles() {
        XCTAssertFalse(ReadingListSectioning.shouldShowFilter(items: [article(), article()]))
    }

    func testFilterHiddenWhenOnlyMedia() {
        XCTAssertFalse(ReadingListSectioning.shouldShowFilter(items: [youtube(), platformItem()]))
    }

    func testFilterShownWithMixOfReaderAndMedia() {
        XCTAssertTrue(ReadingListSectioning.shouldShowFilter(items: [article(), youtube()]))
    }

    func testFilterHiddenWhenEmpty() {
        XCTAssertFalse(ReadingListSectioning.shouldShowFilter(items: []))
    }

    // MARK: - ListFilter.includes

    func testListFilterAllIncludesEverything() {
        XCTAssertTrue(ReadingListSectioning.ListFilter.all.includes(article()))
        XCTAssertTrue(ReadingListSectioning.ListFilter.all.includes(youtube()))
    }

    func testListFilterArticlesOnlyIncludesReaders() {
        XCTAssertTrue(ReadingListSectioning.ListFilter.articles.includes(article()))
        XCTAssertFalse(ReadingListSectioning.ListFilter.articles.includes(youtube()))
    }

    func testListFilterMediaExcludesReaders() {
        XCTAssertFalse(ReadingListSectioning.ListFilter.mediaAndLinks.includes(article()))
        XCTAssertTrue(ReadingListSectioning.ListFilter.mediaAndLinks.includes(platformItem()))
    }

    // MARK: - catchUpQueue

    func testCatchUpExcludesRead() {
        let queue = ReadingListSectioning.catchUpQueue(items: [article(readState: .read)])
        XCTAssertTrue(queue.isEmpty)
    }

    func testCatchUpIncludesUnopenedAndOpened() {
        let queue = ReadingListSectioning.catchUpQueue(
            items: [article(readState: .unopened), article(readState: .opened)])
        XCTAssertEqual(queue.count, 2)
    }

    func testCatchUpExcludesPendingArticle() {
        // A reader item whose content isn't ready (still pending) doesn't qualify.
        let queue = ReadingListSectioning.catchUpQueue(items: [article(state: .pending)])
        XCTAssertTrue(queue.isEmpty)
    }

    func testCatchUpIncludesLockedArticle() {
        let queue = ReadingListSectioning.catchUpQueue(items: [article(state: .needsCaptcha)])
        XCTAssertEqual(queue.count, 1)
    }

    func testCatchUpExcludesFailedArticle() {
        let queue = ReadingListSectioning.catchUpQueue(items: [article(state: .failed)])
        XCTAssertTrue(queue.isEmpty)
    }

    func testCatchUpIncludesNonReaderRegardlessOfState() {
        // Non-readers (video/links) always qualify when unread.
        var pendingVideo = youtube()
        pendingVideo.state = .pending
        let queue = ReadingListSectioning.catchUpQueue(items: [pendingVideo])
        XCTAssertEqual(queue.count, 1)
    }

    func testCatchUpSortsOldestFirstByDateAdded() {
        let newer = article(addedDaysAgo: 1)
        let older = article(addedDaysAgo: 5)
        let queue = ReadingListSectioning.catchUpQueue(items: [newer, older])
        XCTAssertEqual(queue.map(\.id), [older.id, newer.id])
    }

    func testCatchUpUsesBumpDateOverDateAdded() {
        // `older` by save date, but bumped recently → sorts after the un-bumped item.
        let unbumped = article(addedDaysAgo: 2)
        let bumpedRecently = article(addedDaysAgo: 10, bumpDaysAgo: 0)
        let queue = ReadingListSectioning.catchUpQueue(items: [bumpedRecently, unbumped])
        XCTAssertEqual(queue.map(\.id), [unbumped.id, bumpedRecently.id])
    }

    // MARK: - shouldShowCatchUpDot

    func testDotHiddenBelowThresholdWithNoLockedSave() {
        let items = (0..<9).map { _ in article() }
        XCTAssertFalse(ReadingListSectioning.shouldShowCatchUpDot(items: items))
    }

    func testDotShownAtThreshold() {
        let items = (0..<10).map { _ in article() }
        XCTAssertTrue(ReadingListSectioning.shouldShowCatchUpDot(items: items))
    }

    func testDotShownForLockedSaveBelowThreshold() {
        XCTAssertTrue(ReadingListSectioning.shouldShowCatchUpDot(items: [article(state: .needsCaptcha)]))
    }

    func testDotIgnoresReadItemsTowardThreshold() {
        let read = (0..<20).map { _ in article(readState: .read) }
        XCTAssertFalse(ReadingListSectioning.shouldShowCatchUpDot(items: read))
    }

    func testDotIgnoresReadLockedSave() {
        // A locked save that's already been marked read doesn't trigger the dot.
        let item = article(readState: .read, state: .needsCaptcha)
        XCTAssertFalse(ReadingListSectioning.shouldShowCatchUpDot(items: [item]))
    }

    // MARK: - Section ordering / identity

    func testSectionRawValuesAreStable() {
        // Persisted in the collapsed-sections key — must not drift.
        XCTAssertEqual(ReadingListSectioning.Section.reading.rawValue, 0)
        XCTAssertEqual(ReadingListSectioning.Section.archive.rawValue, 2)
        XCTAssertEqual(ReadingListSectioning.Section.error.rawValue, 3)
        XCTAssertEqual(ReadingListSectioning.Section.pasteboard.rawValue, 4)
    }

    func testDisplayOrderPutsPasteboardFirstAndErrorLast() {
        XCTAssertEqual(
            ReadingListSectioning.displayOrder,
            [.pasteboard, .priceTracking, .reading, .archive, .error])
    }

    func testOnlyArchiveAndErrorAreCollapsible() {
        XCTAssertFalse(ReadingListSectioning.Section.reading.isCollapsible)
        XCTAssertFalse(ReadingListSectioning.Section.pasteboard.isCollapsible)
        XCTAssertTrue(ReadingListSectioning.Section.archive.isCollapsible)
        XCTAssertTrue(ReadingListSectioning.Section.error.isCollapsible)
    }
}
