//
//  SavesSectioningTests.swift
//  LunaTests
//

import LunaReaderUI
import LunaSavesUI
import LunaModels
import XCTest
@testable import Luna

final class SavesSectioningTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_000_000_000)

    /// Builds an article item (renders as reader) with controllable state/age.
    private func article(
        addedDaysAgo: Double = 0,
        readState: SavedItem.ReadState = .unopened,
        state: SavedItem.State = .ready
    ) -> SavedItem {
        var item = SavedItem(urlString: "https://example.com/\(UUID().uuidString)")
        item.dateAdded = now.addingTimeInterval(-addedDaysAgo * 86_400)
        item.readState = readState
        item.state = state
        return item
    }

    /// A non-reader item (a platform post) — used wherever the test only needs
    /// "some item that isn't a reader item", not a specific platform's identity.
    private func platformItem(readState: SavedItem.ReadState = .unopened) -> SavedItem {
        var item = SavedItem(urlString: "https://x.com/x/status/1")
        item.platform = .x
        item.readState = readState
        item.state = .ready
        return item
    }

    /// Builds a price-tracker item with a controllable discount + archived/viewed flag.
    private func priceTracker(
        initial: String = "100", best: String? = nil,
        threshold: Double = 0.10, archived: Bool = false, alertViewed: Bool = false
    ) -> SavedItem {
        var item = SavedItem(urlString: "https://shop.example/\(UUID().uuidString)")
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

    // MARK: - assignSections

    func testFreshUnreadArticleGoesToReading() {
        let buckets = SavesSectioning.assignSections(items: [article(addedDaysAgo: 1)], now: now)
        XCTAssertEqual(buckets.reading.count, 1)
        XCTAssertTrue(buckets.archive.isEmpty)
        XCTAssertTrue(buckets.failed.isEmpty)
    }

    func testReadArticleGoesToArchiveEvenWhenFresh() {
        let buckets = SavesSectioning.assignSections(
            items: [article(addedDaysAgo: 0, readState: .read)], now: now)
        XCTAssertEqual(buckets.archive.count, 1)
        XCTAssertTrue(buckets.reading.isEmpty)
    }

    func testJustFinishedArticleStaysInReadingUntilLifecycleArchive() {
        var pending = article(addedDaysAgo: 0, readState: .read)
        pending.pendingArchiveAt = now
        let buckets = SavesSectioning.assignSections(items: [pending], now: now)
        XCTAssertEqual(buckets.reading.map(\.id), [pending.id])
        XCTAssertTrue(buckets.archive.isEmpty)
    }

    func testExplicitlyArchivedUnreadArticleGoesToArchiveImmediately() {
        var archived = article(addedDaysAgo: 0, readState: .unopened)
        archived.archivedAt = now
        let buckets = SavesSectioning.assignSections(items: [archived], now: now)
        XCTAssertEqual(buckets.archive.map(\.id), [archived.id])
        XCTAssertTrue(buckets.reading.isEmpty)
    }

    func testUnreadButAgedOutGoesToArchive() {
        let buckets = SavesSectioning.assignSections(
            items: [article(addedDaysAgo: 8)], now: now)
        XCTAssertEqual(buckets.archive.count, 1)
        XCTAssertTrue(buckets.reading.isEmpty)
    }

    func testExactlySevenDaysOldStaysInReading() {
        // archiveAge is a strict `>` boundary: exactly 7 days is still Reading.
        let buckets = SavesSectioning.assignSections(
            items: [article(addedDaysAgo: 7)], now: now)
        XCTAssertEqual(buckets.reading.count, 1)
        XCTAssertTrue(buckets.archive.isEmpty)
    }

    func testFailedItemGoesToErrorRegardlessOfAgeOrReadState() {
        let freshFailed = article(addedDaysAgo: 0, readState: .unopened, state: .failed)
        let buckets = SavesSectioning.assignSections(items: [freshFailed], now: now)
        XCTAssertEqual(buckets.failed.count, 1)
        XCTAssertTrue(buckets.reading.isEmpty)
        XCTAssertTrue(buckets.archive.isEmpty)
    }

    func testSectionsPreserveInputOrder() {
        let a = article(addedDaysAgo: 1)
        let b = article(addedDaysAgo: 2)
        let buckets = SavesSectioning.assignSections(items: [a, b], now: now)
        XCTAssertEqual(buckets.reading.map(\.id), [a.id, b.id])
    }

    func testMixedItemsSplitAcrossAllThreeBuckets() {
        let reading = article(addedDaysAgo: 1)
        let archivedByAge = article(addedDaysAgo: 10)
        let archivedByRead = article(addedDaysAgo: 0, readState: .read)
        let failed = article(state: .failed)
        let buckets = SavesSectioning.assignSections(
            items: [reading, archivedByAge, archivedByRead, failed], now: now)
        XCTAssertEqual(buckets.reading.map(\.id), [reading.id])
        XCTAssertEqual(Set(buckets.archive.map(\.id)), [archivedByAge.id, archivedByRead.id])
        XCTAssertEqual(buckets.failed.map(\.id), [failed.id])
    }

    // MARK: - price-tracking section

    func testPriceTrackerGoesToPriceTrackingBucketNotReading() {
        let buckets = SavesSectioning.assignSections(items: [priceTracker()], now: now)
        XCTAssertEqual(buckets.priceTracking.count, 1)
        XCTAssertTrue(buckets.reading.isEmpty)
    }

    func testArchivedTrackerExcludedFromAllBuckets() {
        let buckets = SavesSectioning.assignSections(
            items: [priceTracker(archived: true)], now: now)
        XCTAssertTrue(buckets.priceTracking.isEmpty)
        XCTAssertTrue(buckets.reading.isEmpty)
    }

    func testUnviewedAlertingTrackerFloatsOutOfSection() {
        // A tracker dropped 30% (> 10% threshold) is alerting+unviewed → pulled to the
        // top and excluded from the price-tracking section body.
        let alerting = priceTracker(initial: "100", best: "70")
        let calm = priceTracker(initial: "100", best: "98")
        let buckets = SavesSectioning.assignSections(items: [alerting, calm], now: now)
        XCTAssertEqual(buckets.priceTracking.map(\.id), [calm.id])
        XCTAssertEqual(
            SavesSectioning.topUnviewedAlertingPriceTracker(items: [alerting, calm])?.id,
            alerting.id)
    }

    func testTopUnviewedAlertingPicksGreatestDiscount() {
        let small = priceTracker(initial: "100", best: "85")  // 15% off
        let big = priceTracker(initial: "100", best: "50")    // 50% off
        XCTAssertEqual(
            SavesSectioning.topUnviewedAlertingPriceTracker(items: [small, big])?.id, big.id)
    }

    func testNoUnviewedAlertingTrackerWhenNoneCrossThreshold() {
        let calm = priceTracker(initial: "100", best: "95")
        XCTAssertNil(SavesSectioning.topUnviewedAlertingPriceTracker(items: [calm]))
    }

    func testAtMostOneTrackerFloatsToTop() {
        // Three alerting+unviewed trackers; only the single greatest discount floats.
        let a = priceTracker(initial: "100", best: "70")  // 30% off
        let b = priceTracker(initial: "100", best: "50")  // 50% off — winner
        let c = priceTracker(initial: "100", best: "80")  // 20% off
        let pinned = SavesSectioning.topUnviewedAlertingPriceTracker(items: [a, b, c])
        XCTAssertEqual(pinned?.id, b.id)
        // The other two remain in the price-tracking section body.
        let buckets = SavesSectioning.assignSections(items: [a, b, c], now: now)
        XCTAssertEqual(Set(buckets.priceTracking.map(\.id)), [a.id, c.id])
    }

    func testViewedAlertDoesNotFloatToTop() {
        // An alerting tracker whose alert has been acknowledged stays in the section.
        let viewed = priceTracker(initial: "100", best: "60", alertViewed: true)
        XCTAssertNil(SavesSectioning.topUnviewedAlertingPriceTracker(items: [viewed]))
        let buckets = SavesSectioning.assignSections(items: [viewed], now: now)
        XCTAssertEqual(buckets.priceTracking.map(\.id), [viewed.id])
    }

    func testViewedAlertYieldsTopToUnviewedOne() {
        // A bigger-discount but VIEWED tracker does not pin; a smaller-discount but
        // UNVIEWED one does — the float keys on unviewed, not raw discount.
        let viewedBig = priceTracker(initial: "100", best: "40", alertViewed: true)  // 60% viewed
        let unviewedSmall = priceTracker(initial: "100", best: "80")                 // 20% unviewed
        XCTAssertEqual(
            SavesSectioning.topUnviewedAlertingPriceTracker(
                items: [viewedBig, unviewedSmall])?.id,
            unviewedSmall.id)
    }

    // MARK: - Stored-save kind

    func testStoredSaveKindUsesTheSharedDisplayPrecedence() {
        var failed = article(state: .failed)
        XCTAssertEqual(SavesSectioning.kind(for: failed), .failed)

        var productWinsOverMedia = priceTracker()
        productWinsOverMedia.platform = .youtube
        XCTAssertEqual(SavesSectioning.kind(for: productWinsOverMedia), .product)

        XCTAssertEqual(SavesSectioning.kind(for: platformItem()), .media)
        XCTAssertEqual(SavesSectioning.kind(for: article()), .article)

        // A failure after product/media metadata exists keeps that item's kind.
        failed.priceTracker = PriceTracker(
            productName: "Widget", firstStoreURL: failed.urlString,
            price: 10, currency: "USD")
        XCTAssertEqual(SavesSectioning.kind(for: failed), .product)
    }

    // MARK: - Which app shows which item (`LunaApp.includes`)

    /// The display counterpart to `SurfaceSupport`'s ingest gate. Its mapping
    /// comes from `SavesSectioning.kind(for:)`, so it stays aligned with cards.
    func testCentralAppShowsEveryKind() {
        for item in [article(), platformItem(), priceTracker()] {
            XCTAssertTrue(LunaApp.luna.includes(item))
        }
    }

    func testReaderShowsOnlyItemsThatReadAsText() {
        XCTAssertTrue(LunaApp.reader.includes(article()))
        XCTAssertFalse(LunaApp.reader.includes(platformItem()))
        XCTAssertFalse(LunaApp.reader.includes(priceTracker()))
    }

    func testDownloaderShowsMediaButNeitherArticlesNorTrackers() {
        XCTAssertTrue(LunaApp.downloader.includes(platformItem()))
        XCTAssertFalse(LunaApp.downloader.includes(article()))
        XCTAssertFalse(LunaApp.downloader.includes(priceTracker()))
    }

    func testPriceTrackerShowsOnlyTrackers() {
        XCTAssertTrue(LunaApp.priceTracker.includes(priceTracker()))
        XCTAssertFalse(LunaApp.priceTracker.includes(article()))
        XCTAssertFalse(LunaApp.priceTracker.includes(platformItem()))
    }

    /// A kind-less failed save has no owner, so EVERY app shows it — the app the
    /// user saved the link in is where they expect to see it break.
    func testEveryAppShowsAKindLessFailedSave() {
        var failed = article()
        failed.state = .failed
        for app in LunaApp.allCases {
            XCTAssertTrue(app.includes(failed), "\(app) must show a failed save")
        }
    }

}
