//
//  SavedMediaCardOrderingTests.swift
//  LunaTests
//

import LunaMediaDownload
import XCTest
@testable import Luna

final class SavedMediaCardOrderingTests: XCTestCase {
    func testOrdersDownloaderCardsNewestFirstFromLeftToRight() {
        let oldest = item(id: UUID(), dateSaved: Date(timeIntervalSince1970: 100))
        let newest = item(id: UUID(), dateSaved: Date(timeIntervalSince1970: 300))
        let middle = item(id: UUID(), dateSaved: Date(timeIntervalSince1970: 200))

        let ordered = SavedMediaCardOrdering.newestFirst([oldest, newest, middle])

        XCTAssertEqual(ordered.map(\.id), [newest.id, middle.id, oldest.id])
    }

    private func item(id: UUID, dateSaved: Date) -> SavedMediaItem {
        SavedMediaItem(
            id: id,
            sourceURLString: "https://example.com/\(id)",
            title: nil,
            dateSaved: dateSaved,
            kind: .video,
            storageState: .undownloaded,
            thumbnailFileName: nil)
    }
}
