//
//  ReadingListGroupBuilderTests.swift
//  LunaTests
//
//  ReadingListGroupBuilder was extracted from ReadingListViewController's reload
//  path as a pure function of its inputs (Wave 3C). These tests exercise the
//  grouping/filtering/floating-alert logic directly, without a view controller,
//  store, or simulator.
//

import LunaModels
import LunaReadingListUI
import XCTest
@testable import Luna

final class ReadingListGroupBuilderTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_000_000_000)

    private func article(readState: ReadingListItem.ReadState = .unopened) -> ReadingListItem {
        var item = ReadingListItem(urlString: "https://example.com/\(UUID().uuidString)")
        item.dateAdded = now
        item.readState = readState
        item.state = .ready
        return item
    }

    private func platformItem() -> ReadingListItem {
        var item = ReadingListItem(urlString: "https://x.com/x/status/\(UUID().uuidString)")
        item.platform = .x
        item.dateAdded = now
        item.state = .ready
        return item
    }

    private func priceTracker(best: String? = nil) -> ReadingListItem {
        var item = ReadingListItem(urlString: "https://shop.example/\(UUID().uuidString)")
        var tracker = PriceTracker(
            productName: "Widget", firstStoreURL: item.urlString,
            price: 100, currency: "USD", alertThresholdFraction: 0.10)
        if let best, let bestPrice = Decimal(string: best) {
            tracker.setPrice(bestPrice, currency: "USD", urlString: item.urlString, at: now)
        }
        item.priceTracker = tracker
        item.state = .ready
        return item
    }

    private func buildGroups(
        items: [ReadingListItem],
        filter: ReadingListSectioning.ListFilter = .all,
        surface: AppSurface? = nil,
        pasteboardRow: ReadingListItem? = nil
    ) -> [(section: ReadingListSectioning.Section, items: [ReadingListItem])] {
        ReadingListGroupBuilder.buildGroups(
            items: items, filter: filter, surface: surface, pasteboardRow: pasteboardRow, now: now)
    }

    // MARK: - Empty sections are dropped, present ones follow displayOrder

    func testEmptySectionsAreOmitted() {
        let groups = buildGroups(items: [article()])
        XCTAssertEqual(groups.map(\.section), [.reading])
    }

    func testNonEmptySectionsFollowDisplayOrder() {
        let groups = buildGroups(items: [
            article(),
            article(readState: .read),
            priceTracker(),
        ])
        // displayOrder is [.priceAlert, .pasteboard, .reading, .priceTracking, .archive, .error];
        // only the non-empty ones (reading, priceTracking, archive) survive, in that order.
        XCTAssertEqual(groups.map(\.section), [.reading, .priceTracking, .archive])
    }

    func testNoItemsProducesNoGroups() {
        XCTAssertTrue(buildGroups(items: []).isEmpty)
    }

    // MARK: - Filter (combined list, surface nil)

    func testFilterRestrictsToArticlesWhenSurfaceIsNil() {
        let groups = buildGroups(items: [article(), platformItem()], filter: .articles)
        XCTAssertEqual(groups.map(\.section), [.reading])
        XCTAssertEqual(groups.first?.items.count, 1)
    }

    func testFilterAllIncludesEveryKind() {
        let groups = buildGroups(items: [article(), platformItem(), priceTracker()], filter: .all)
        let sections = Set(groups.map(\.section))
        XCTAssertTrue(sections.contains(.reading))
        XCTAssertTrue(sections.contains(.priceTracking))
    }

    // MARK: - Surface overrides the filter entirely

    func testSurfaceIgnoresTheFilterParameter() {
        // Even though `filter` asks for media-only, a concrete `.reader` surface
        // restricts to its own category regardless.
        let groups = buildGroups(
            items: [article(), platformItem()], filter: .mediaAndLinks, surface: .reader)
        XCTAssertEqual(groups.map(\.section), [.reading])
        XCTAssertEqual(groups.first?.items.count, 1)
    }

    func testDownloaderSurfaceShowsOnlyMediaAndLinks() {
        let media = platformItem()
        let groups = buildGroups(items: [article(), media], surface: .downloader)
        // The article is filtered out before assignSections ever sees it; the
        // platform item lands in Reading (unread, unaged) under this surface.
        let allShown = groups.flatMap(\.items)
        XCTAssertEqual(allShown.map(\.id), [media.id])
        XCTAssertTrue(allShown.allSatisfy { $0.contentPlatform != nil })
    }

    func testPriceTrackerSurfaceShowsOnlyTrackers() {
        let groups = buildGroups(items: [article(), platformItem(), priceTracker()], surface: .priceTracker)
        let allShown = groups.flatMap(\.items)
        XCTAssertTrue(allShown.allSatisfy { $0.isPriceTracker })
        XCTAssertEqual(allShown.count, 1)
    }

    // MARK: - Pasteboard suggestion row

    func testPasteboardRowRendersAsItsOwnSection() {
        let suggestion = article()
        let groups = buildGroups(items: [], pasteboardRow: suggestion)
        XCTAssertEqual(groups.map(\.section), [.pasteboard])
        XCTAssertEqual(groups.first?.items.map(\.id), [suggestion.id])
    }

    func testNoPasteboardRowMeansNoPasteboardSection() {
        let groups = buildGroups(items: [article()], pasteboardRow: nil)
        XCTAssertFalse(groups.map(\.section).contains(.pasteboard))
    }

    // MARK: - The floating, unviewed-alerting price tracker

    func testUnviewedAlertingTrackerGetsItsOwnTopSection() {
        let alerting = priceTracker(best: "50") // 50% off, well past the 10% threshold
        let groups = buildGroups(items: [alerting])
        XCTAssertEqual(groups.first?.section, .priceAlert)
        XCTAssertEqual(groups.first?.items.map(\.id), [alerting.id])
        // Excluded from the price-tracking section body itself.
        XCTAssertFalse(groups.contains { $0.section == .priceTracking })
    }

    func testCalmTrackerStaysInThePriceTrackingSection() {
        let calm = priceTracker() // no drop at all
        let groups = buildGroups(items: [calm])
        XCTAssertEqual(groups.map(\.section), [.priceTracking])
    }

    func testPriceAlertOutranksPasteboardAtTheTop() {
        let alerting = priceTracker(best: "50")
        let suggestion = article()
        let groups = buildGroups(items: [alerting], pasteboardRow: suggestion)
        XCTAssertEqual(groups.map(\.section), [.priceAlert, .pasteboard])
    }
}
