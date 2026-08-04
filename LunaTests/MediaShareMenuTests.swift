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
        for row in rows { row.action() }
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
