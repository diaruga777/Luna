//
//  MediaShareMenuTests.swift
//  LunaTests
//
//  The media decks' trailing share circle offers a MENU in the reader pill's
//  shape: Copy link and Share link over the original saved URL, then — only
//  once Luna actually holds the file — a share row named for what the file IS
//  (video / GIF / image / audio). These tests pin the row set per storage
//  state and kind, and that each row fires its own verb.
//

import LunaModels
import UIKit
import XCTest
@testable import Luna
@testable import LunaMediaDownload

final class MediaShareMenuTests: XCTestCase {

    private func makeItem(
        kind: MediaAsset.Kind?, storageState: SavedMediaItem.StorageState
    ) -> SavedMediaItem {
        SavedMediaItem(
            id: UUID(), sourceURLString: "https://x.com/luna/status/424242",
            title: "Clip", dateSaved: Date(), kind: kind,
            storageState: storageState, thumbnailFileName: nil)
    }

    private func rowTitles(
        kind: MediaAsset.Kind?, storageState: SavedMediaItem.StorageState
    ) -> [String] {
        MediaItemActions.shareMenuRows(
            for: makeItem(kind: kind, storageState: storageState),
            copyLink: {}, shareLink: {}, shareFile: {}
        ).map(\.title)
    }

    /// An undownloaded row has no file to offer, but its link still shares.
    func testUndownloadedOffersOnlyTheLinkVerbs() {
        XCTAssertEqual(
            rowTitles(kind: nil, storageState: .undownloaded),
            ["Copy link", "Share link"])
    }

    /// The file row is named for what the file is, whichever store it lives in.
    func testDownloadedFileRowIsNamedForItsKind() {
        XCTAssertEqual(
            rowTitles(kind: .video, storageState: .localFile(fileName: "a.mp4")),
            ["Copy link", "Share link", "Share video"])
        XCTAssertEqual(
            rowTitles(kind: .gif, storageState: .localFile(fileName: "a.gif")),
            ["Copy link", "Share link", "Share GIF"])
        XCTAssertEqual(
            rowTitles(kind: .audio, storageState: .localFile(fileName: "a.m4a")),
            ["Copy link", "Share link", "Share audio"])
        XCTAssertEqual(
            rowTitles(kind: .image, storageState: .localFile(fileName: "a.jpg")),
            ["Copy link", "Share link", "Share image"])
        XCTAssertEqual(
            rowTitles(
                kind: .video,
                storageState: .photosReference(
                    localIdentifier: "asset", pendingLocalFileName: nil,
                    pendingThumbnailFileName: nil)),
            ["Copy link", "Share link", "Share video"])
    }

    /// A row whose kind never resolved renders as an image card, so its share
    /// row says the same rather than a vague "media".
    func testNilKindSharesAsImage() {
        XCTAssertEqual(
            rowTitles(kind: nil, storageState: .localFile(fileName: "a.bin")),
            ["Copy link", "Share link", "Share image"])
    }

    /// Each row fires its own verb and nobody else's.
    func testRowsInvokeTheirOwnActions() {
        var fired: [String] = []
        let rows = MediaItemActions.shareMenuRows(
            for: makeItem(kind: .video, storageState: .localFile(fileName: "a.mp4")),
            copyLink: { fired.append("copy") },
            shareLink: { fired.append("link") },
            shareFile: { fired.append("file") })
        for row in rows {
            guard case .tap(let action) = row.behavior else { continue }
            action()
        }
        XCTAssertEqual(fired, ["copy", "link", "file"])
    }

    /// The menu mirrors the rows one-to-one — no submenus in the media ladder.
    @MainActor
    func testMenuMirrorsRowsInOrder() {
        let item = makeItem(kind: .gif, storageState: .localFile(fileName: "a.gif"))
        let menu = MediaItemActions.shareMenu(
            for: item, presenter: UIViewController(), sourceView: nil, shareFile: {})
        XCTAssertEqual(
            menu.children.map(\.title),
            ["Copy link", "Share link", "Share GIF"])
        XCTAssertTrue(menu.children.allSatisfy { $0 is UIAction })
    }
}

/// Every deck that shows media reaches this ladder through the ONE media
/// presenter, so a media save's pill offers exactly the same thing in the
/// central app as on the Downloader's own circle — and a save that isn't this
/// kind's offers nothing, which is what keeps its pill hidden.
final class AllKindsShareMenuTests: XCTestCase {

    /// A bare deck host: `CardPresenterHost` is what a presenter is handed, and
    /// the base class is the whole of that conformance.
    @MainActor
    private func makeHost() -> CardPresenterHost { CardCarouselHostViewController() }


    override func setUp() {
        super.setUp()
        SavedMediaDeckFixtures.emptySharedMediaStore()
    }

    override func tearDown() {
        SavedMediaDeckFixtures.emptySharedMediaStore()
        super.tearDown()
    }

    @MainActor
    func testMediaSaveOffersTheLadderOverItsOriginalURL() throws {
        let url = "https://x.com/luna/status/91919"
        _ = try SavedMediaStore.shared.ensureUndownloaded(
            id: UUID(), sourceURLString: url, title: "Clip",
            kind: .video, dateSaved: Date())
        let item = ReadingListItem(
            seed: "allkinds-share", urlString: url, title: "Clip",
            dateAdded: Date(), state: .ready, platform: .x)

        let menu = MediaCardPresenter().shareMenu(
            for: item, host: makeHost(), sourceView: UIView())

        XCTAssertEqual(
            menu?.children.map(\.title), ["Copy link", "Share link"],
            "an undownloaded media save shares its link, not a file it doesn't hold")
    }

    @MainActor
    func testNonPlatformSaveOffersNoMenu() {
        let item = ReadingListItem(
            seed: "allkinds-share-article",
            urlString: "https://example.com/article", title: "Article",
            dateAdded: Date(), state: .ready)

        XCTAssertNil(MediaCardPresenter().shareMenu(
            for: item, host: makeHost(), sourceView: UIView()))
    }

    /// A platform save Luna never fetched media for is still a LINK — its card
    /// is a link and nothing else — so the pill offers the two link verbs
    /// rather than hiding.
    @MainActor
    func testPlatformSaveWithoutAMediaRowSharesItsLinkAlone() {
        let item = ReadingListItem(
            seed: "allkinds-share-link-only",
            urlString: "https://x.com/luna/status/272727", title: "Post",
            dateAdded: Date(), state: .ready, platform: .x)

        let menu = MediaCardPresenter().shareMenu(
            for: item, host: makeHost(), sourceView: UIView())

        XCTAssertEqual(menu?.children.map(\.title), ["Copy link", "Share link"])
    }
}

/// The Downloader deck's trailing circle carries that menu — and it now shows
/// for EVERY media card, undownloaded ones included, because the link is
/// shareable before the file exists.
final class SavedMediaDeckShareChromeTests: XCTestCase {

    override func setUp() {
        super.setUp()
        UIView.setAnimationsEnabled(false)
        SavedMediaDeckFixtures.emptySharedMediaStore()
    }

    override func tearDown() {
        SavedMediaDeckFixtures.emptySharedMediaStore()
        super.tearDown()
    }

    @MainActor
    func testTrailingCircleIsAMenuOverTheCenteredCard() {
        SavedMediaDeckFixtures.seedMedia(count: 1, prefix: "share-chrome")

        let deck = MediaCardDeck.makeRoot()
        let window = UITestSupport.host(UINavigationController(rootViewController: deck))
        deck.view.layoutIfNeeded()
        deck.carousel.reloadData(centeringAt: deck.cardOffset)
        deck.refreshTrailingBottomButton()

        XCTAssertTrue(deck.trailingBottomButton.showsMenuAsPrimaryAction)
        XCTAssertFalse(
            deck.trailingBottomButton.isHidden,
            "an undownloaded row's link is shareable, so the circle shows")
        XCTAssertEqual(
            deck.shareMenuForTesting?.children.map(\.title),
            ["Copy link", "Share link"],
            "no file yet, so the menu is the link verbs alone")
        _ = window
    }

    @MainActor
    func testUtilCardOffersNoShareMenu() {
        SavedMediaDeckFixtures.seedMedia(count: 1, prefix: "share-chrome-util")

        let deck = MediaCardDeck.makeRoot()
        let window = UITestSupport.host(UINavigationController(rootViewController: deck))
        deck.view.layoutIfNeeded()
        deck.carousel.reloadData(centeringAt: deck.utilCardIndex)
        deck.refreshTrailingBottomButton()

        XCTAssertNil(deck.shareMenuForTesting)
        XCTAssertTrue(
            deck.trailingBottomButton.isHidden,
            "the util card has no link to offer, so the circle hides")
        _ = window
    }
}
