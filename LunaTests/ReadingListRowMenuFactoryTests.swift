//
//  ReadingListRowMenuFactoryTests.swift
//  LunaTests
//
//  ReadingListRowMenuFactory was extracted from ReadingListViewController's
//  rowMenu(for:at:) (Wave 3C) as a pure function from an item + its
//  environment facts to a UIMenu. These tests assert the action SET per item
//  shape, not the closures' wiring (each closure is just forwarded verbatim).
//

import LunaModels
import UIKit
import XCTest
@testable import Luna

final class ReadingListRowMenuFactoryTests: XCTestCase {

    private func titles(_ menu: UIMenu) -> [String] {
        menu.children.compactMap { ($0 as? UIAction)?.title }
    }

    private func actions(
        isInReadingSection: Bool = false,
        isKindleConfigured: Bool = false
    ) -> RowMenuActions {
        RowMenuActions(
            isInReadingSection: isInReadingSection,
            isKindleConfigured: isKindleConfigured,
            sendToFriend: {}, sendToKindle: {}, shareEbook: {}, shareLink: {}, copyLink: {},
            saveMediaToPhotos: {}, bumpToTop: {}, toggleTrackerArchived: {}, unarchive: {},
            delete: {}, editList: {})
    }

    private func article(
        urlString: String = "https://example.com/story",
        readState: ReadingListItem.ReadState = .unopened,
        state: ReadingListItem.State = .ready
    ) -> ReadingListItem {
        var item = ReadingListItem(urlString: urlString)
        item.readState = readState
        item.state = state
        return item
    }

    // MARK: - Price trackers get a focused menu, independent of every other flag

    func testPriceTrackerMenuTitleIsTheProductName() {
        var item = article(urlString: "https://shop.example/widget")
        item.priceTracker = PriceTracker(
            productName: "Acme Widget", firstStoreURL: item.urlString, price: 10, currency: "USD")
        let menu = ReadingListRowMenuFactory.menu(for: item, actions: actions())
        XCTAssertEqual(menu.title, "Acme Widget")
    }

    func testActiveTrackerOffersArchiveNotUnarchive() {
        var item = article(urlString: "https://shop.example/widget")
        var tracker = PriceTracker(
            productName: "Widget", firstStoreURL: item.urlString, price: 10, currency: "USD")
        tracker.isArchived = false
        item.priceTracker = tracker
        let menu = ReadingListRowMenuFactory.menu(for: item, actions: actions())
        XCTAssertEqual(titles(menu), ["Send to Friend…", "Archive Tracker", "Delete"])
    }

    func testArchivedTrackerOffersUnarchive() {
        var item = article(urlString: "https://shop.example/widget")
        var tracker = PriceTracker(
            productName: "Widget", firstStoreURL: item.urlString, price: 10, currency: "USD")
        tracker.isArchived = true
        item.priceTracker = tracker
        let menu = ReadingListRowMenuFactory.menu(for: item, actions: actions())
        XCTAssertEqual(titles(menu), ["Send to Friend…", "Unarchive Tracker", "Delete"])
    }

    // MARK: - A shareable article (real web URL)

    func testShareableArticleOffersLinkActionsButNoEbook() {
        let item = article()
        let menu = ReadingListRowMenuFactory.menu(for: item, actions: actions())
        let result = titles(menu)
        XCTAssertTrue(result.contains("Share Link…"))
        XCTAssertTrue(result.contains("Copy Link"))
        XCTAssertTrue(result.contains("Send to Friend…"), "a real web URL can share to friends")
        XCTAssertFalse(result.contains("Share eBook…"), "a shareable article never offers the eBook fallback")
        XCTAssertEqual(result.last, "Edit List", "Edit List is always the trailing action")
    }

    func testReadingSectionOffersBumpToTop() {
        let menu = ReadingListRowMenuFactory.menu(
            for: article(), actions: actions(isInReadingSection: true))
        XCTAssertEqual(titles(menu).first, "Bump to Top")
    }

    func testNonReadingSectionOmitsBumpToTop() {
        let menu = ReadingListRowMenuFactory.menu(
            for: article(), actions: actions(isInReadingSection: false))
        XCTAssertFalse(titles(menu).contains("Bump to Top"))
    }

    func testKindleConfiguredOffersSendToKindle() {
        let menu = ReadingListRowMenuFactory.menu(
            for: article(), actions: actions(isKindleConfigured: true))
        XCTAssertTrue(titles(menu).contains("Send to Kindle"))
    }

    func testKindleNotConfiguredOmitsSendToKindle() {
        let menu = ReadingListRowMenuFactory.menu(
            for: article(), actions: actions(isKindleConfigured: false))
        XCTAssertFalse(titles(menu).contains("Send to Kindle"))
    }

    func testReadArticleOffersUnarchive() {
        let menu = ReadingListRowMenuFactory.menu(
            for: article(readState: .read), actions: actions())
        XCTAssertTrue(titles(menu).contains("Unarchive"))
    }

    func testUnreadArticleOmitsUnarchive() {
        let menu = ReadingListRowMenuFactory.menu(
            for: article(readState: .unopened), actions: actions())
        XCTAssertFalse(titles(menu).contains("Unarchive"))
    }

    // MARK: - A non-shareable text save (synthetic URL — document/email import)

    func testNonShareableReadyArticleOffersEbookNotLinkActions() {
        let item = article(urlString: "lunadoc://ABC123", state: .ready)
        let menu = ReadingListRowMenuFactory.menu(
            for: item, actions: actions(isKindleConfigured: true))
        let result = titles(menu)
        XCTAssertTrue(result.contains("Share eBook…"))
        XCTAssertFalse(result.contains("Share Link…"))
        XCTAssertFalse(result.contains("Copy Link"))
        XCTAssertFalse(result.contains("Send to Friend…"), "a synthetic URL can't share to friends")
        XCTAssertTrue(result.contains("Send to Kindle"), "ereader sends are independent of shareability")
    }

    func testNonShareablePendingArticleOmitsEbook() {
        // The eBook fallback only appears once the article is actually ready.
        let item = article(urlString: "lunadoc://ABC123", state: .pending)
        let menu = ReadingListRowMenuFactory.menu(for: item, actions: actions())
        XCTAssertFalse(titles(menu).contains("Share eBook…"))
    }

    // MARK: - A platform (video/social) item

    func testPlatformItemOmitsEreaderActions() {
        var item = article(urlString: "https://x.com/x/status/1")
        item.platform = .x
        let menu = ReadingListRowMenuFactory.menu(
            for: item, actions: actions(isKindleConfigured: true))
        let result = titles(menu)
        XCTAssertFalse(result.contains("Send to Kindle"), "ereader sends are article-only")
        XCTAssertFalse(result.contains("Share eBook…"))
        XCTAssertTrue(result.contains("Share Link…"), "a platform post still has a real, shareable URL")
    }

    func testDownloadablePlatformOffersSaveToPhotos() {
        var item = article(urlString: "https://x.com/x/status/1")
        item.platform = .x
        let menu = ReadingListRowMenuFactory.menu(for: item, actions: actions())
        XCTAssertTrue(titles(menu).contains("Save to Photos"))
    }

    // MARK: - Delete + Edit List are always present, in order

    func testDeleteAlwaysPrecedesEditList() {
        let menu = ReadingListRowMenuFactory.menu(for: article(), actions: actions())
        let result = titles(menu)
        guard let deleteIndex = result.firstIndex(of: "Delete"),
              let editIndex = result.firstIndex(of: "Edit List") else {
            return XCTFail("expected both Delete and Edit List")
        }
        XCTAssertEqual(editIndex, result.count - 1)
        XCTAssertLessThan(deleteIndex, editIndex)
    }
}
