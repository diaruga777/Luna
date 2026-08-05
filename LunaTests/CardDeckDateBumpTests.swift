//
//  CardDeckDateBumpTests.swift
//  LunaTests
//

import LunaMediaDownload
import LunaModels
import LunaStorage
import XCTest
@testable import Luna

/// Every deck sorts on `bumpDate ?? dateAdded` and nothing else
/// (`CardDeckOrderingTests`), so the ONLY way a save moves is something stamping
/// that date. Exactly three things do, and these are them.
///
/// A kind that forgets its bump fails invisibly — the save just comes back from
/// the archive buried wherever it originally sat — which is why each kind is
/// pinned separately rather than trusting the shared call site.
@MainActor
final class CardDeckDateBumpTests: XCTestCase {

    private var store: ReadingListStore { .shared }

    /// The registry is PROCESS-wide and installed once at launch by
    /// `KindWiring+Luna`. Swapping an entry for the duration of a test is fine;
    /// leaving it swapped is not — every later deck suite reads it, and a nil
    /// entry silently costs those decks their cards rather than failing here.
    private var installed: (CardKindPresenting?, CardKindPresenting?, CardKindPresenting?)!

    override func setUp() {
        super.setUp()
        installed = (CardKindPresenters.article, CardKindPresenters.media,
                     CardKindPresenters.product)
        SavedMediaDeckFixtures.emptySharedMediaStore()
        store.seedForTesting(items: [], contents: [:])
    }

    override func tearDown() {
        SavedMediaDeckFixtures.emptySharedMediaStore()
        store.seedForTesting(items: [], contents: [:])
        (CardKindPresenters.article, CardKindPresenters.media,
         CardKindPresenters.product) = installed
        super.tearDown()
    }

    // MARK: - Unarchive bumps, for every kind

    func testUnarchivingAnArticleBumpsItsSortDate() throws {
        let item = seed(urlString: "https://example.com/article")
        CardKindPresenters.article = ArticleCardPresenter()
        let presenter = try XCTUnwrap(CardKindPresenters.presenter(for: item))

        presenter.setArchived(true, for: item)
        presenter.setArchived(false, for: item)

        assertBumped(item, "an unarchived article must come back to the front")
    }

    func testUnarchivingAProductBumpsItsSortDateAndClearsTheTrackerFlag() throws {
        var item = seed(urlString: "https://shop.example/widget")
        item.priceTracker = PriceTracker(
            productName: "Widget", firstStoreURL: item.urlString,
            price: Decimal(10), currency: "USD")
        store.seedForTesting(items: [item], contents: [:])
        CardKindPresenters.product = ProductCardPresenter()
        let presenter = try XCTUnwrap(CardKindPresenters.presenter(for: item))

        presenter.setArchived(true, for: item)
        presenter.setArchived(false, for: item)

        assertBumped(item, "an unarchived product must come back to the front")
        // The mirrored half: archived-ness lives on the tracker as well as the
        // row, and both must move together or the deck and the tray disagree.
        XCTAssertEqual(store.item(withID: item.id)?.priceTracker?.isArchived, false)
    }

    func testUnarchivingAMediaSaveBumpsItsSortDateAndClearsTheMediaRow() throws {
        let urlString = "https://media.example.com/clip"
        var item = seed(urlString: urlString)
        item.platform = .reddit
        store.seedForTesting(items: [item], contents: [:])
        let media = try XCTUnwrap(try? SavedMediaStore.shared.ensureUndownloaded(
            id: UUID(), sourceURLString: urlString, title: "Clip",
            kind: .video, dateSaved: Date()))
        CardKindPresenters.media = MediaCardPresenter()
        let presenter = try XCTUnwrap(CardKindPresenters.presenter(for: item))

        presenter.setArchived(true, for: item)
        presenter.setArchived(false, for: item)

        assertBumped(item, "an unarchived media save must come back to the front")
        XCTAssertEqual(
            SavedMediaStore.shared.items().first(where: { $0.id == media.id })?.isArchived,
            false,
            "the media row's own flag must clear with the reading-list row's")
    }

    // MARK: - Helpers

    /// Backdated well past any plausible test runtime, so "bumped" is
    /// unambiguous rather than a sub-second comparison.
    private func seed(urlString: String) -> ReadingListItem {
        var item = ReadingListItem(urlString: urlString)
        item.dateAdded = Date().addingTimeInterval(-40 * 86_400)
        item.state = .ready
        store.seedForTesting(items: [item], contents: [:])
        return item
    }

    private func assertBumped(
        _ item: ReadingListItem, _ message: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        guard let fresh = store.item(withID: item.id) else {
            return XCTFail("row vanished: \(message)", file: file, line: line)
        }
        guard let bump = fresh.bumpDate else {
            return XCTFail("no bump date: \(message)", file: file, line: line)
        }
        XCTAssertGreaterThan(
            bump, fresh.dateAdded,
            "\(message) — the bump must outrank the original save date",
            file: file, line: line)
    }
}
