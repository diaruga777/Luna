import AppIntents
import LunaModels
import LunaMediaDownload
import LunaStorage
import XCTest
@testable import Luna

final class SavedItemAutomationTests: XCTestCase {
    func testSavedItemTypesUseStoredClassification() {
        var item = SavedItem(seed: "types", urlString: "https://example.com/item", title: "Item", dateAdded: Date())
        XCTAssertTrue(SavedItemKind.article.matches(item))
        item.documentType = "pdf"
        XCTAssertTrue(SavedItemKind.article.matches(item))
        item.platform = .youtube
        XCTAssertTrue(SavedItemKind.media.matches(item))
        XCTAssertFalse(SavedItemKind.article.matches(item))
        item.state = .link
        XCTAssertTrue(SavedItemKind.link.matches(item))
        XCTAssertFalse(SavedItemKind.media.matches(item))
    }

    func testShoppingPricePreservesMissingValueAndCurrency() {
        let neverChecked = ShoppingItemPriceEntity(PriceTrackerStore(urlString: "https://shop.example/item", lastPrice: nil, currency: "AUD"))
        XCTAssertNil(neverChecked.price)
        XCTAssertNil(neverChecked.lastChecked)
        XCTAssertEqual(neverChecked.currency, "AUD")
        let date = Date(timeIntervalSince1970: 12345)
        let checked = ShoppingItemPriceEntity(PriceTrackerStore(urlString: "https://shop.example/item", lastPrice: Decimal(string: "19.95"), currency: "USD", lastRefreshed: date))
        XCTAssertEqual(checked.price, 19.95)
        XCTAssertEqual(checked.currency, "USD")
        XCTAssertEqual(checked.lastChecked, date)
        XCTAssertEqual(checked.storeURL, "https://shop.example/item")
    }

    func testVideoExportResolvesOwnedVideoAndRejectsUnavailableOrDeletedSaves() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SavesStore(containerURL: root), mediaStore = SavedMediaStore(containerURL: root)
        let item = store.reserveSaveAttempt(urlString: "https://example.com/clip", at: Date()).item
        _ = try mediaStore.ensureUndownloaded(id: item.id, sourceURLString: item.urlString, title: "Clip")
        do {
            _ = try await SavedItemVideoExport.video(saveID: item.id, store: store, mediaStore: mediaStore) { _ in XCTFail("Undownloaded media must not export"); return nil }
            XCTFail("Expected unavailable video")
        } catch { XCTAssertEqual(error as? SavedItemVideoExport.Failure, .notDownloaded) }
        let source = root.appendingPathComponent("clip.mp4")
        try Data("video bytes".utf8).write(to: source)
        _ = try await mediaStore.addDownloadedFile(source, kind: .video, sourceURLString: item.urlString, title: "Clip")
        let result = try await SavedItemVideoExport.video(saveID: item.id, store: store, mediaStore: mediaStore) { media in
            XCTAssertEqual(media.id, item.id)
            XCTAssertEqual(media.kind, .video)
            return DownloadedMedia(fileURL: source, kind: .video)
        }
        XCTAssertEqual(result.fileURL, source)
        do {
            _ = try await SavedItemVideoExport.video(saveID: item.id, store: store, mediaStore: mediaStore) { _ in nil }
            XCTFail("A failed export must report an error")
        } catch { XCTAssertEqual(error as? SavedItemVideoExport.Failure, .unavailable) }
        store.delete(item)
        do {
            _ = try await SavedItemVideoExport.video(saveID: item.id, store: store, mediaStore: mediaStore) { _ in XCTFail("Deleted media must not export"); return nil }
            XCTFail("Deleted save must not resolve")
        } catch { XCTAssertEqual(error as? SavedItemVideoExport.Failure, .missing) }
    }
}
