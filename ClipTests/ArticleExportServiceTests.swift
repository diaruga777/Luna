//
//  ArticleExportServiceTests.swift
//  ClipTests
//

import ClipStorage
import ClipModels
import XCTest
import UniformTypeIdentifiers
@testable import Clip

final class ArticleExportServiceTests: XCTestCase {

    private var scratch: URL!
    private var store: ReadingListStore!

    override func setUp() {
        super.setUp()
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArticleExport-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        store = ReadingListStore(containerURL: scratch)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: scratch)
        super.tearDown()
    }

    private func readyItem(title: String, url: String) -> ReadingListItem {
        let item = store.add(urlString: url)
        let content = ArticleContent(
            title: title,
            blocks: [ArticleContent.Block(kind: .paragraph, text: "Body text.", links: [])])
        return store.saveContent(content, for: item)
    }

    func testWriteEPUBProducesValidZipFileWithSanitizedName() throws {
        let item = readyItem(title: "Hello: World?", url: "https://example.com/a")
        let url = try ArticleExportService(store: store).writeEPUB(for: item)

        XCTAssertEqual(url.pathExtension, "epub")
        let data = try Data(contentsOf: url)
        XCTAssertFalse(data.isEmpty)
        // EPUB is a ZIP archive — starts with the local file header signature.
        XCTAssertEqual(Array(data.prefix(4)), [0x50, 0x4B, 0x03, 0x04])
        // Disallowed filename characters are stripped.
        XCTAssertFalse(url.lastPathComponent.contains(":"))
        XCTAssertFalse(url.lastPathComponent.contains("?"))
    }

    func testItemProviderAdvertisesEPUBType() throws {
        let item = readyItem(title: "Doc", url: "https://example.com/b")
        let provider = try ArticleExportService(store: store).itemProvider(for: item)
        XCTAssertTrue(provider.hasItemConformingToTypeIdentifier(UTType.epub.identifier))
    }

    func testWriteEPUBThrowsWithoutContent() {
        let pending = store.add(urlString: "https://example.com/c") // no content saved
        XCTAssertThrowsError(try ArticleExportService(store: store).writeEPUB(for: pending)) { error in
            XCTAssertEqual(error as? ArticleExportService.ExportError, .noContent)
        }
    }
}
