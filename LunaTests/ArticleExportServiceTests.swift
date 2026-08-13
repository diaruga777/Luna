//
//  ArticleExportServiceTests.swift
//  LunaTests
//

import LunaReadingList
@testable import LunaSend
import LunaStorage
import LunaModels
import UIKit
import XCTest
@testable import Luna

/// Stands in for the app's `ArticleImageDownloader` witness and records whether
/// the export actually asked for a fetch.
private final class FakeExportImagePreparer: ArticleExportImagePreparing {
    private let download: (ArticleContent) -> ArticleContent
    private(set) var ran = false

    init(download: @escaping (ArticleContent) -> ArticleContent) {
        self.download = download
    }

    func preparedContent(
        _ content: ArticleContent, for item: ReadingListItem
    ) async -> ArticleContent {
        ran = true
        return download(content)
    }
}

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

    /// An article saved with image blocks whose pictures haven't downloaded yet
    /// — the state EVERY save is in for a while, and permanently for a save
    /// that came through the share extension.
    private func itemWithUnfetchedImage(url: String) -> ReadingListItem {
        let item = store.add(urlString: url)
        let content = ArticleContent(
            title: "Illustrated",
            blocks: [
                ArticleContent.Block(kind: .paragraph, text: "Body text.", links: []),
                ArticleContent.Block(
                    kind: .image, text: "A photo", links: [],
                    imageURLString: "https://example.com/photo.png", imageFileName: nil),
            ])
        return store.saveContent(content, for: item)
    }

    /// Writes a PNG where the downloader would put it, and returns the content
    /// with the name recorded — a stand-in for a real fetch.
    private func fakeDownload(_ content: ArticleContent) -> ArticleContent {
        var updated = content
        updated.blocks = content.blocks.map { block in
            guard block.kind == .image, let raw = block.imageURLString else { return block }
            var block = block
            let name = "\(ArticleImageFiles.stableBase(forImageURL: raw)).png"
            let image = UIGraphicsImageRenderer(size: CGSize(width: 20, height: 10)).image {
                UIColor.red.setFill()
                $0.fill(CGRect(x: 0, y: 0, width: 20, height: 10))
            }
            try? image.pngData()?.write(to: store.articlesDirectory.appendingPathComponent(name))
            block.imageFileName = name
            return block
        }
        return updated
    }

    /// The export FETCHES the images the article hasn't downloaded yet, instead
    /// of quietly shipping a file with none — and persists the result, so the
    /// work is done once.
    func testWritePreparingImagesFetchesMissingImagesAndPersistsThem() async throws {
        let item = itemWithUnfetchedImage(url: "https://example.com/illustrated")
        let preparer = FakeExportImagePreparer(download: { self.fakeDownload($0) })
        ArticleExportImages.preparer = preparer
        defer { ArticleExportImages.preparer = nil }

        let url = try await ArticleExportService(store: store)
            .writePreparingImages(.epub, for: item)

        XCTAssertTrue(preparer.ran)
        let stored = try XCTUnwrap(store.content(for: item))
        XCTAssertNotNil(
            stored.blocks.first(where: { $0.kind == .image })?.imageFileName,
            "the fetched file name must be persisted, not thrown away")
        // The picture really reached the book.
        let archive = try Data(contentsOf: url)
        XCTAssertTrue(
            String(decoding: archive, as: UTF8.self).contains("<img src=\"images/img-"))
    }

    /// Nothing to fetch ⇒ no seam call and no pointless re-persist.
    func testWritePreparingImagesSkipsWhenEveryImageIsAlreadyLocal() async throws {
        let item = readyItem(title: "Plain", url: "https://example.com/plain")
        let preparer = FakeExportImagePreparer(download: { $0 })
        ArticleExportImages.preparer = preparer
        defer { ArticleExportImages.preparer = nil }

        _ = try await ArticleExportService(store: store).writePreparingImages(.pdf, for: item)
        XCTAssertFalse(preparer.ran, "an article with no image blocks has nothing to prepare")
    }

    /// Extensions install no preparer; the export still works from local files.
    func testWritePreparingImagesWorksWithNoPreparerInstalled() async throws {
        ArticleExportImages.preparer = nil
        let item = itemWithUnfetchedImage(url: "https://example.com/no-seam")
        let url = try await ArticleExportService(store: store)
            .writePreparingImages(.markdown, for: item)
        XCTAssertEqual(url.pathExtension, "md")
    }

    func testDoubleSaveDocumentWaitsForTheFirstInFlightSaveContent() async throws {
        let pending = store.add(urlString: "https://example.com/in-flight")
        Task {
            try? await Task.sleep(nanoseconds: 200_000_000)
            let content = ArticleContent(
                title: "Arrived",
                blocks: [ArticleContent.Block(
                    kind: .paragraph, text: "Now ready.", links: [])])
            _ = self.store.saveContent(content, for: pending)
        }

        let url = try await ArticleExportService(store: store)
            .writePreparingImagesWhenAvailable(.document, for: pending, timeout: 2)
        XCTAssertEqual(url.pathExtension, "docx")
        XCTAssertEqual(try Data(contentsOf: url).prefix(4), Data([0x50, 0x4B, 0x03, 0x04]))
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
            var isDirectory: ObjCBool = false
            XCTAssertTrue(FileManager.default.fileExists(
                atPath: url.path, isDirectory: &isDirectory))
            XCTAssertFalse(isDirectory.boolValue, "every share item must be a regular file")
            let data = try Data(contentsOf: url)
            XCTAssertFalse(data.isEmpty, "\(format)")
            if format == .document || format == .epub {
                // Both DOCX and EPUB are ZIP archives — starts with the local
                // file header signature.
                XCTAssertEqual(data.prefix(4), Data([0x50, 0x4B, 0x03, 0x04]), "\(format)")
            }
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
