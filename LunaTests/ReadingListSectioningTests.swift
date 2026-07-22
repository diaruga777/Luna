//
//  ReadingListSectioningTests.swift
//  LunaTests
//

import LunaReaderUI
import LunaReadingListUI
import LunaModels
import XCTest
@testable import Luna

final class ReadingListSectioningTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_000_000_000)

    /// Builds an article item (renders as reader) with controllable state/age.
    private func article(
        addedDaysAgo: Double = 0,
        readState: ReadingListItem.ReadState = .unopened,
        state: ReadingListItem.State = .ready
    ) -> ReadingListItem {
        var item = ReadingListItem(urlString: "https://example.com/\(UUID().uuidString)")
        item.dateAdded = now.addingTimeInterval(-addedDaysAgo * 86_400)
        item.readState = readState
        item.state = state
        return item
    }

    /// A non-reader item (a platform post) — used wherever the test only needs
    /// "some item that isn't a reader item", not a specific platform's identity.
    private func platformItem(readState: ReadingListItem.ReadState = .unopened) -> ReadingListItem {
        var item = ReadingListItem(urlString: "https://x.com/x/status/1")
        item.platform = .x
        item.readState = readState
        item.state = .ready
        return item
    }

    /// Builds a price-tracker item with a controllable discount + archived/viewed flag.
    private func priceTracker(
        initial: String = "100", best: String? = nil,
        threshold: Double = 0.10, archived: Bool = false, alertViewed: Bool = false
    ) -> ReadingListItem {
        var item = ReadingListItem(urlString: "https://shop.example/\(UUID().uuidString)")
        guard let initialPrice = Decimal(string: initial) else {
            fatalError("invalid test price literal: \(initial)")
        }
        var tracker = PriceTracker(
            productName: "Widget", firstStoreURL: item.urlString,
            price: initialPrice, currency: "USD", alertThresholdFraction: threshold)
        if let best, let bestPrice = Decimal(string: best) {
            tracker.setPrice(bestPrice, currency: "USD", urlString: item.urlString, at: now)
        }
        tracker.isArchived = archived
        if alertViewed { tracker.markAlertViewed(at: now) }
        item.priceTracker = tracker
        item.state = .ready
        return item
    }

    // MARK: - rendersAsReader

    func testArticleRendersAsReader() {
        XCTAssertTrue(ReadingListSectioning.rendersAsReader(article()))
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

    func testJustFinishedArticleStaysInReadingUntilLifecycleArchive() {
        var pending = article(addedDaysAgo: 0, readState: .read)
        pending.pendingArchiveAt = now
        let buckets = ReadingListSectioning.assignSections(items: [pending], now: now)
        XCTAssertEqual(buckets.reading.map(\.id), [pending.id])
        XCTAssertTrue(buckets.archive.isEmpty)
    }

    func testExplicitlyArchivedUnreadArticleGoesToArchiveImmediately() {
        var archived = article(addedDaysAgo: 0, readState: .unopened)
        archived.archivedAt = now
        let buckets = ReadingListSectioning.assignSections(items: [archived], now: now)
        XCTAssertEqual(buckets.archive.map(\.id), [archived.id])
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

    func testUnviewedAlertingTrackerFloatsOutOfSection() {
        // A tracker dropped 30% (> 10% threshold) is alerting+unviewed → pulled to the
        // top and excluded from the price-tracking section body.
        let alerting = priceTracker(initial: "100", best: "70")
        let calm = priceTracker(initial: "100", best: "98")
        let buckets = ReadingListSectioning.assignSections(items: [alerting, calm], now: now)
        XCTAssertEqual(buckets.priceTracking.map(\.id), [calm.id])
        XCTAssertEqual(
            ReadingListSectioning.topUnviewedAlertingPriceTracker(items: [alerting, calm])?.id,
            alerting.id)
    }

    func testTopUnviewedAlertingPicksGreatestDiscount() {
        let small = priceTracker(initial: "100", best: "85")  // 15% off
        let big = priceTracker(initial: "100", best: "50")    // 50% off
        XCTAssertEqual(
            ReadingListSectioning.topUnviewedAlertingPriceTracker(items: [small, big])?.id, big.id)
    }

    func testNoUnviewedAlertingTrackerWhenNoneCrossThreshold() {
        let calm = priceTracker(initial: "100", best: "95")
        XCTAssertNil(ReadingListSectioning.topUnviewedAlertingPriceTracker(items: [calm]))
    }

    func testAtMostOneTrackerFloatsToTop() {
        // Three alerting+unviewed trackers; only the single greatest discount floats.
        let a = priceTracker(initial: "100", best: "70")  // 30% off
        let b = priceTracker(initial: "100", best: "50")  // 50% off — winner
        let c = priceTracker(initial: "100", best: "80")  // 20% off
        let pinned = ReadingListSectioning.topUnviewedAlertingPriceTracker(items: [a, b, c])
        XCTAssertEqual(pinned?.id, b.id)
        // The other two remain in the price-tracking section body.
        let buckets = ReadingListSectioning.assignSections(items: [a, b, c], now: now)
        XCTAssertEqual(Set(buckets.priceTracking.map(\.id)), [a.id, c.id])
    }

    func testViewedAlertDoesNotFloatToTop() {
        // An alerting tracker whose alert has been acknowledged stays in the section.
        let viewed = priceTracker(initial: "100", best: "60", alertViewed: true)
        XCTAssertNil(ReadingListSectioning.topUnviewedAlertingPriceTracker(items: [viewed]))
        let buckets = ReadingListSectioning.assignSections(items: [viewed], now: now)
        XCTAssertEqual(buckets.priceTracking.map(\.id), [viewed.id])
    }

    func testViewedAlertYieldsTopToUnviewedOne() {
        // A bigger-discount but VIEWED tracker does not pin; a smaller-discount but
        // UNVIEWED one does — the float keys on unviewed, not raw discount.
        let viewedBig = priceTracker(initial: "100", best: "40", alertViewed: true)  // 60% viewed
        let unviewedSmall = priceTracker(initial: "100", best: "80")                 // 20% unviewed
        XCTAssertEqual(
            ReadingListSectioning.topUnviewedAlertingPriceTracker(
                items: [viewedBig, unviewedSmall])?.id,
            unviewedSmall.id)
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
        XCTAssertFalse(ReadingListSectioning.shouldShowFilter(items: [platformItem(), platformItem()]))
    }

    func testFilterShownWithMixOfReaderAndMedia() {
        XCTAssertTrue(ReadingListSectioning.shouldShowFilter(items: [article(), platformItem()]))
    }

    func testFilterHiddenWhenEmpty() {
        XCTAssertFalse(ReadingListSectioning.shouldShowFilter(items: []))
    }

    // MARK: - ListFilter.includes

    func testListFilterAllIncludesEverything() {
        XCTAssertTrue(ReadingListSectioning.ListFilter.all.includes(article()))
        XCTAssertTrue(ReadingListSectioning.ListFilter.all.includes(platformItem()))
    }

    func testListFilterArticlesOnlyIncludesReaders() {
        XCTAssertTrue(ReadingListSectioning.ListFilter.articles.includes(article()))
        XCTAssertFalse(ReadingListSectioning.ListFilter.articles.includes(platformItem()))
    }

    func testListFilterMediaExcludesReaders() {
        XCTAssertFalse(ReadingListSectioning.ListFilter.mediaAndLinks.includes(article()))
        XCTAssertTrue(ReadingListSectioning.ListFilter.mediaAndLinks.includes(platformItem()))
    }

    // MARK: - Section ordering / identity

    func testSectionRawValuesAreStable() {
        // Persisted in the collapsed-sections key — must not drift.
        XCTAssertEqual(ReadingListSectioning.Section.reading.rawValue, 0)
        XCTAssertEqual(ReadingListSectioning.Section.archive.rawValue, 2)
        XCTAssertEqual(ReadingListSectioning.Section.error.rawValue, 3)
        XCTAssertEqual(ReadingListSectioning.Section.pasteboard.rawValue, 4)
        XCTAssertEqual(ReadingListSectioning.Section.priceTracking.rawValue, 5)
        XCTAssertEqual(ReadingListSectioning.Section.priceAlert.rawValue, 6)
    }

    func testDisplayOrderPutsPriceTrackingBelowReading() {
        // Price tracking sits BELOW Reading; the floating price-alert row is the very
        // top of the whole list (ahead of the pasteboard suggestion).
        XCTAssertEqual(
            ReadingListSectioning.displayOrder,
            [.priceAlert, .pasteboard, .reading, .priceTracking, .archive, .error])
        let order = ReadingListSectioning.displayOrder
        guard let readingIndex = order.firstIndex(of: .reading),
              let priceIndex = order.firstIndex(of: .priceTracking),
              let alertIndex = order.firstIndex(of: .priceAlert) else {
            XCTFail("expected reading, priceTracking, priceAlert in display order"); return
        }
        XCTAssertLessThan(readingIndex, priceIndex, "price tracking must be below reading")
        XCTAssertEqual(alertIndex, 0, "the floated price alert must be the very top section")
    }

    func testOnlyArchiveAndErrorAreCollapsible() {
        XCTAssertFalse(ReadingListSectioning.Section.reading.isCollapsible)
        XCTAssertFalse(ReadingListSectioning.Section.pasteboard.isCollapsible)
        XCTAssertFalse(ReadingListSectioning.Section.priceTracking.isCollapsible)
        XCTAssertFalse(ReadingListSectioning.Section.priceAlert.isCollapsible)
        XCTAssertTrue(ReadingListSectioning.Section.archive.isCollapsible)
        XCTAssertTrue(ReadingListSectioning.Section.error.isCollapsible)
    }
}
