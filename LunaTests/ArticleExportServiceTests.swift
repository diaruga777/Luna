//
//  ArticleExportServiceTests.swift
//  LunaTests
//

import LunaReadingList
import LunaSend
import LunaStorage
import LunaModels
import XCTest
import UniformTypeIdentifiers
@testable import Luna

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

    // MARK: - Every format

    /// Each format writes a non-empty file under its own extension, off the one
    /// shared sanitized stem.
    func testEveryFormatWritesItsOwnExtension() throws {
        let item = readyItem(title: "Hello: World?", url: "https://example.com/d")
        let service = ArticleExportService(store: store)
        var stems: Set<String> = []
        for format in ArticleExportFormat.allCases {
            let url = try service.write(format, for: item)
            XCTAssertEqual(url.pathExtension, format.fileExtension, "\(format)")
            XCTAssertFalse(try Data(contentsOf: url).isEmpty, "\(format)")
            XCTAssertFalse(url.lastPathComponent.contains(":"), "\(format)")
            stems.insert(url.deletingPathExtension().lastPathComponent)
        }
        XCTAssertEqual(stems.count, 1, "every format shares one file stem")
    }

    func testPDFExportProducesPDFBytes() throws {
        let item = readyItem(title: "Doc", url: "https://example.com/e")
        let url = try ArticleExportService(store: store).write(.pdf, for: item)
        let data = try Data(contentsOf: url)
        XCTAssertEqual(String(decoding: data.prefix(4), as: UTF8.self), "%PDF")
    }

    func testMarkdownExportIsUTF8MarkdownWithSource() throws {
        let item = readyItem(title: "Doc", url: "https://example.com/f")
        let url = try ArticleExportService(store: store).write(.markdown, for: item)
        let text = try XCTUnwrap(String(data: try Data(contentsOf: url), encoding: .utf8))
        XCTAssertTrue(text.hasPrefix("# Doc"))
        XCTAssertTrue(text.contains("https://example.com/f"))
        XCTAssertTrue(text.contains("Body text."))
    }

    func testPlainTextExportCarriesNoMarkup() throws {
        let item = readyItem(title: "Doc", url: "https://example.com/g")
        let url = try ArticleExportService(store: store).write(.plainText, for: item)
        let text = try XCTUnwrap(String(data: try Data(contentsOf: url), encoding: .utf8))
        XCTAssertTrue(text.hasPrefix("Doc\n"))
        XCTAssertFalse(text.contains("# "))
        XCTAssertTrue(text.contains("Body text."))
    }

    func testItemProviderAdvertisesRequestedFormatType() throws {
        let item = readyItem(title: "Doc", url: "https://example.com/h")
        let service = ArticleExportService(store: store)
        XCTAssertTrue(try service.itemProvider(.pdf, for: item)
            .hasItemConformingToTypeIdentifier(UTType.pdf.identifier))
        XCTAssertTrue(try service.itemProvider(.plainText, for: item)
            .hasItemConformingToTypeIdentifier(UTType.plainText.identifier))
    }

    /// A still-locked or media item has no stored content, so NO format can be
    /// exported — one gate covers all four.
    func testEveryFormatThrowsWithoutContent() {
        let pending = store.add(urlString: "https://example.com/i")
        let service = ArticleExportService(store: store)
        for format in ArticleExportFormat.allCases {
            XCTAssertThrowsError(try service.write(format, for: pending), "\(format)") { error in
                XCTAssertEqual(error as? ArticleExportService.ExportError, .noContent)
            }
        }
    }
}
