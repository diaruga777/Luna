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

/// How a card PRESENTS its content is a property of what it shows; how big it
/// is is not.
///
/// Presentation values — edge fade and in-card paging —
/// stay per-kind. A deck-level value would force the one deck that mixes
/// kinds to pick a single answer for all of them: the central app would
/// dissolve every media card's video edges over the reader's 28pt fade and
/// preview it as a still, while the same download in the Downloader is
/// hard-clipped and plays under the finger.
///
/// Geometry goes the other way: every kind shares one card frame. A per-kind
/// `fit`/`topOverflow` would make an article card, a video card, and a
/// product card three different rectangles at three different centers in one
/// deck, so paging between kinds would resize and re-center the card
/// underneath the transition. The geometry test is that no kind can state
/// its own frame.
@MainActor
final class CardKindStyleTests: XCTestCase {

    private var installed: (CardKindPresenting?, CardKindPresenting?, CardKindPresenting?)!

    override func setUp() {
        super.setUp()
        installed = (CardKindPresenters.article, CardKindPresenters.media,
                     CardKindPresenters.product)
        SavedMediaDeckFixtures.emptySharedMediaStore()
        SavesStore.shared.seedForTesting(items: [], contents: [:])
    }

    override func tearDown() {
        SavedMediaDeckFixtures.emptySharedMediaStore()
        SavesStore.shared.seedForTesting(items: [], contents: [:])
        (CardKindPresenters.article, CardKindPresenters.media,
         CardKindPresenters.product) = installed
        super.tearDown()
    }

    func testOnlyMediaUsesPosterOnlyScrubPreviews() {
        XCTAssertTrue(ArticleCardPresenter().showsContentWhileScrubbing)
        XCTAssertTrue(ProductCardPresenter().showsContentWhileScrubbing)
        XCTAssertFalse(MediaCardPresenter().showsContentWhileScrubbing)
        let host = CardCarouselHostViewController()
        XCTAssertTrue(host.carousel(host.carousel, showsContentWhileScrubbingCardAt: 0))
    }

    // MARK: - The point: one deck, one frame, two presentations

    func testEveryCardPagesFromItsNonControlSurfaceByDefault() {
        XCTAssertTrue(
            CardCarouselCardStyle().pagesOnInCardSwipes,
            "a card kind only opts out by reserving a specific control rectangle")
    }

    func testAMediaCardAndAnArticleCardInOneDeckDifferOnlyInPresentation() throws {
        CardKindPresenters.article = ArticleCardPresenter()
        CardKindPresenters.media = MediaCardPresenter()

        let article = SavedItem(urlString: "https://example.com/piece")
        SavedMediaDeckFixtures.seedMedia(count: 1, prefix: "clip")
        let media = try XCTUnwrap(SavedMediaStore.shared.items().first)
        let mediaRow = mediaItem(for: media)

        let articleStyle = try style(for: article)
        let mediaStyle = try style(for: mediaRow)

        XCTAssertGreaterThan(
            articleStyle.contentEdgeFadeHeight, 0,
            "scrolled text must dissolve at the card's edges")
        XCTAssertEqual(
            mediaStyle.contentEdgeFadeHeight, 0,
            "dissolving a video's own edges is the central app's old reader fade")
    }

    /// A card always pages from its broad surface, regardless of whether its
    /// media file is available yet. Narrow controls (the playback scrubber and
    /// embedded player) reserve their own rectangles at gesture time.
    func testADownloadingMediaCardPagesOutsideItsSpecificControls() throws {
        CardKindPresenters.media = MediaCardPresenter()
        SavedMediaDeckFixtures.seedMedia(count: 1, prefix: "downloading")
        let media = try XCTUnwrap(SavedMediaStore.shared.items().first)
        XCTAssertEqual(
            media.storageState, .undownloaded,
            "fixture precondition: this row has no file yet, so its card is not playable")

        XCTAssertTrue(
            try style(for: mediaItem(for: media)).pagesOnInCardSwipes,
            "an undownloaded card has no timeline and pages like every other card")
    }

    func testAProductCardScrollsInsideTheOneCardFrameAndPages() throws {
        CardKindPresenters.product = ProductCardPresenter()
        var item = SavedItem(urlString: "https://shop.example/widget")
        item.priceTracker = PriceTracker(
            productName: "Widget",
            firstStoreURL: "https://shop.example/widget",
            price: 10,
            currency: "USD")

        let style = try style(for: item)
        XCTAssertEqual(style.contentEdgeFadeHeight, 0)
        XCTAssertTrue(style.pagesOnInCardSwipes, "nothing in the editor scrubs")
    }

    // MARK: -

    private func style(for item: SavedItem) throws -> CardCarouselCardStyle {
        try XCTUnwrap(CardKindPresenters.presenter(for: item)).cardStyle(for: item)
    }

    /// The save row behind a media save — carrying a platform, which is
    /// what routes it to the media presenter. (An UNBACKED media row carries no
    /// platform and reaches its presenter another way: the deck records the
    /// presenter that contributed it and bypasses the registry entirely.)
    private func mediaItem(for media: SavedMediaItem) -> SavedItem {
        var item = SavedItem(urlString: media.sourceURLString, id: media.id)
        item.platform = media.platform ?? .youtube
        return item
    }
}
