//
//  CardKindStyleTests.swift
//  LunaTests
//

import LunaDesignSystem
import LunaMediaDownload
import LunaModels
import LunaStorage
import XCTest
@testable import Luna

/// A card's SHAPE is a property of what it shows, not of the screen it is on.
///
/// These four values — fit, edge fade, scrub-preview autoplay, in-card paging —
/// used to be deck-level `CardCarouselStyle` fields, so the one deck that mixes
/// kinds had to pick ONE answer for all of them. It picked the article's: the
/// central app stretched every media card to the reader's `.aspectFromBottom`,
/// dissolved its video edges over the reader's 28pt fade, and previewed it as a
/// still. The same download in the Downloader was 9:16, hard-clipped, and
/// played under the finger.
///
/// So the test that matters is not "a media card is 9:16" — it is that a media
/// card and an article card IN THE SAME DECK get different answers.
@MainActor
final class CardKindStyleTests: XCTestCase {

    private var installed: (CardKindPresenting?, CardKindPresenting?, CardKindPresenting?)!

    override func setUp() {
        super.setUp()
        installed = (CardKindPresenters.article, CardKindPresenters.media,
                     CardKindPresenters.product)
        SavedMediaDeckFixtures.emptySharedMediaStore()
        ReadingListStore.shared.seedForTesting(items: [], contents: [:])
    }

    override func tearDown() {
        SavedMediaDeckFixtures.emptySharedMediaStore()
        ReadingListStore.shared.seedForTesting(items: [], contents: [:])
        (CardKindPresenters.article, CardKindPresenters.media,
         CardKindPresenters.product) = installed
        super.tearDown()
    }

    // MARK: - The point: one deck, two shapes

    func testAMediaCardAndAnArticleCardInOneDeckGetDifferentShapes() throws {
        CardKindPresenters.article = ArticleCardPresenter()
        CardKindPresenters.media = MediaCardPresenter()

        let article = ReadingListItem(urlString: "https://example.com/piece")
        SavedMediaDeckFixtures.seedMedia(count: 1, prefix: "clip")
        let media = try XCTUnwrap(SavedMediaStore.shared.items().first)
        let mediaRow = mediaItem(for: media)

        let articleStyle = try style(for: article)
        let mediaStyle = try style(for: mediaRow)

        XCTAssertEqual(
            articleStyle.fit, .aspectFromBottom,
            "a reader card grows up into the header clearance")
        XCTAssertEqual(
            mediaStyle.fit, .aspectCentered,
            "a video is 9:16 and letterboxing it into a reader's frame is the bug")
        XCTAssertGreaterThan(
            articleStyle.contentEdgeFadeHeight, 0,
            "scrolled text must dissolve at the card's edges")
        XCTAssertEqual(
            mediaStyle.contentEdgeFadeHeight, 0,
            "dissolving a video's own edges is the central app's old reader fade")
        XCTAssertTrue(
            mediaStyle.autoplaysScrubPreview,
            "the Downloader played the centered preview; every app now does")
        XCTAssertFalse(
            articleStyle.autoplaysScrubPreview,
            "a reader preview mounts but does not play")
    }

    /// The veto that keeps a horizontal drag from meaning two things at once.
    /// A PLAYING card was already exempt from paging everywhere — the carousel
    /// vetoes it for playable content — but a DOWNLOADING media card is not
    /// playable yet, so it paged in the central app (whose deck paged on in-card
    /// swipes for its readers) and stayed put in the Downloader.
    func testADownloadingMediaCardNeverPagesOnAnInCardSwipe() throws {
        CardKindPresenters.media = MediaCardPresenter()
        SavedMediaDeckFixtures.seedMedia(count: 1, prefix: "downloading")
        let media = try XCTUnwrap(SavedMediaStore.shared.items().first)
        XCTAssertEqual(
            media.storageState, .undownloaded,
            "fixture precondition: this row has no file yet, so its card is not playable")

        XCTAssertFalse(
            try style(for: mediaItem(for: media)).pagesOnInCardSwipes,
            "a media card's width belongs to its timeline in every app, downloaded or not")
    }

    func testAProductCardFillsItsRoomAndPages() throws {
        CardKindPresenters.product = ProductCardPresenter()
        var item = ReadingListItem(urlString: "https://shop.example/widget")
        item.priceTracker = PriceTracker(
            productName: "Widget",
            firstStoreURL: "https://shop.example/widget",
            price: 10,
            currency: "USD")

        let style = try style(for: item)
        XCTAssertEqual(style.fit, .fill, "the editor is a column of controls, not a picture")
        XCTAssertEqual(style.contentEdgeFadeHeight, 0)
        XCTAssertTrue(style.pagesOnInCardSwipes, "nothing in the editor scrubs")
    }

    // MARK: -

    private func style(for item: ReadingListItem) throws -> CardCarouselCardStyle {
        try XCTUnwrap(CardKindPresenters.presenter(for: item)).cardStyle(for: item)
    }

    /// The reading-list row behind a media save — carrying a platform, which is
    /// what routes it to the media presenter. (An UNBACKED media row carries no
    /// platform and reaches its presenter another way: the deck records the
    /// presenter that contributed it and bypasses the registry entirely.)
    private func mediaItem(for media: SavedMediaItem) -> ReadingListItem {
        var item = ReadingListItem(urlString: media.sourceURLString, id: media.id)
        item.platform = media.platform ?? .youtube
        return item
    }
}
