import LunaDesignSystem
import LunaMediaDownload
import LunaModels
import LunaStorage
import UIKit
import XCTest
@testable import Luna

@MainActor
final class MediaDeckScalingTests: XCTestCase {
    func testSnapshotReadStatementCountDoesNotGrowPerVideo() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MediaDeckScaling-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let saves = SavesStore(containerURL: directory)
        let media = SavedMediaStore(containerURL: directory)
        let previousPresenter = CardKindPresenters.media
        let previousRetention = MediaRetentionSettings.option
        defer {
            CardKindPresenters.media = previousPresenter
            MediaRetentionSettings.option = previousRetention
            try? FileManager.default.removeItem(at: directory)
        }
        MediaRetentionSettings.option = .never
        CardKindPresenters.media = MediaCardPresenter(store: media, saves: saves)
        let host = CardCarouselHostViewController()
        var configuration = CardDeckConfiguration()
        configuration.showsSavesWithoutKindContent = true
        let provider = KindDeckProvider(host: host, configuration: configuration, store: saves)

        func readCount(for count: Int) throws -> Int {
            let items = (0..<count).map { index -> SavedItem in
                var item = SavedItem(urlString: "https://www.tiktok.com/@scale/video/\(index)")
                item.platform = .tiktok
                item.state = .ready
                return item
            }
            saves.seedForTesting(items: items, contents: [:])
            try saves.replaceMediaItems(items.map {
                SavedMediaItem(id: $0.id, sourceURLString: $0.urlString,
                    title: nil, dateSaved: $0.dateAdded, kind: .video,
                    storageState: .undownloaded, thumbnailFileName: nil)
            })
            let before = saves.readStatementCountForTesting
            let snapshot = provider.deckPreparedSnapshot()
            XCTAssertEqual(snapshot.slots.count, count)
            provider.deckDidSettleReload()
            return saves.readStatementCountForTesting - before
        }
        let one = try readCount(for: 1)
        let hundred = try readCount(for: 100)
        XCTAssertLessThanOrEqual(hundred, one + 2,
            "A reload should read media in bulk, not issue SQL for each video")

        // A later reload must observe another connection's edits.
        let first = try XCTUnwrap(saves.items().first)
        let sibling = SavesStore(containerURL: directory)
        try sibling.mutateMediaItems { rows in
            rows[rows.firstIndex(where: { $0.id == first.id })!].archivedAt = Date()
        }
        let changed = provider.deckPreparedSnapshot()
        XCTAssertTrue(changed.offstageIDs.contains(first.id))
        XCTAssertEqual(changed.slots.count, 99)
        provider.deckDidSettleReload()
    }
}
