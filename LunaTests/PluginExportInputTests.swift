//
//  PluginExportInputTests.swift
//  LunaTests
//

import Foundation
import LunaEpub
import LunaReaderUI
import LunaSend
import LunaModels
import LunaPluginExport
import LunaPluginKit
import LunaStorage
import UIKit
import XCTest

/// What an `export` hook is actually handed, per kind and format
/// (`claudedocs/plans/plugin-platform.md` §9.1).
///
/// Every case runs the SHIPPED producer against a scratch saves store and a
/// scratch plugin file store, so a handle a test resolves is one the plugin
/// could have read.
final class PluginExportInputTests: XCTestCase {

    private var containerURL: URL!
    private var store: SavesStore!
    private var scratch: PluginScratchStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        containerURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("plugin-export-input-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: containerURL, withIntermediateDirectories: true)
        store = SavesStore(containerURL: containerURL)
        scratch = PluginScratchStore(
            rootURL: containerURL.appendingPathComponent("scratch"))
        _ = scratch.openScratchGeneration(pluginID: "test.plugin", generationID: "one")
    }

    override func tearDown() {
        scratch?.closeScratchGeneration(pluginID: "test.plugin", generationID: "one")
        try? FileManager.default.removeItem(at: containerURL)
        containerURL = nil
        store = nil
        scratch = nil
        super.tearDown()
    }

    // MARK: - Fixtures

    private func readyArticle() -> SavedItem {
        let item = store.add(urlString: "https://example.com/article")
        return store.saveContent(
            ArticleContent(
                title: "An Article",
                blocks: [ArticleContent.Block(kind: .paragraph, text: "Words.", links: [])]),
            for: item)
    }

    /// A save whose one image is already on disk, named the way the article
    /// image downloader names one — `saveContent` drops a name the store
    /// cannot take ownership of.
    private func readyArticleWithAnImage() throws -> (item: SavedItem, imageName: String) {
        let item = store.add(urlString: "https://example.com/illustrated")
        let name = ArticleImageFiles.newFileName(fileExtension: "png")
        let pixel = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
        try XCTUnwrap(pixel.pngData()).write(
            to: store.articlesDirectory.appendingPathComponent(name))
        let saved = store.saveContent(
            ArticleContent(
                title: "An Article",
                blocks: [
                    ArticleContent.Block(kind: .paragraph, text: "Words.", links: []),
                    ArticleContent.Block(
                        kind: .image, text: "Alt", links: [],
                        imageURLString: "https://example.com/photo.png", imageFileName: name),
                ]),
            for: item)
        let stored = try XCTUnwrap(store.content(for: saved))
        XCTAssertEqual(
            stored.blocks.first(where: { $0.kind == .image })?.imageFileName, name,
            "the fixture's image must survive the content write")
        return (saved, name)
    }

    private func produce(
        _ item: SavedItem, format: PluginExportInputFormat,
        options: PluginExportSummary? = nil,
        mediaFiles: (any PluginExportMediaFileLocating)? = nil
    ) async throws -> PluginExportInput {
        let producer = PluginExportInputProducer(store: store, mediaFiles: mediaFiles)
        return try await producer.makeInput(
            saveID: item.id, format: format,
            options: options ?? PluginExportFixtures.export(input: format.rawValue),
            auto: false, scratch: scratch, pluginID: "test.plugin", generation: "one")
    }

    private func data(of handle: PluginExportFileHandle) throws -> Data {
        let url = try XCTUnwrap(scratch.fileURL(for: handle.descriptor))
        return try Data(contentsOf: url)
    }

    private func json(of input: PluginExportInput) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(input), as: UTF8.self)
    }

    // MARK: - Article

    /// Any plugin can request the same compact banner as the in-app export.
    func testCompactEpubProfileReplacesOriginalWithBoundedBanner() async throws {
        let (item, imageName) = try readyArticleWithAnImage()

        let standard = try await produce(
            item, format: .epub, options: PluginExportFixtures.export(epubProfile: "standard"))
        let compact = try await produce(
            item, format: .epub, options: PluginExportFixtures.export(epubProfile: "compact"))

        let standardBytes = try data(of: try XCTUnwrap(standard.file))
        let compactBytes = try data(of: try XCTUnwrap(compact.file))
        XCTAssertTrue(
            Self.contains(standardBytes, imageName),
            "the standard profile embeds the article's image")
        XCTAssertFalse(
            Self.contains(compactBytes, imageName),
            "the compact profile never embeds the original image")
        let archive = try XCTUnwrap(ZipArchiveReader(data: compactBytes))
        XCTAssertLessThanOrEqual(try XCTUnwrap(archive.data(at: "OEBPS/images/banner.png")).count, 8192)
        let sharedURL = try ArticleExportService(store: store).write(.compactEpub, for: item)
        let shared = try XCTUnwrap(ZipArchiveReader(data: Data(contentsOf: sharedURL)))
        XCTAssertEqual(shared.data(at: "OEBPS/images/banner.png"), archive.data(at: "OEBPS/images/banner.png"))
        XCTAssertEqual(shared.text(at: "OEBPS/chapter.xhtml"), archive.text(at: "OEBPS/chapter.xhtml"))
        XCTAssertEqual(standard.file?.mime, "application/epub+zip")
        XCTAssertTrue(standard.file?.name.hasSuffix(".epub") == true)
    }

    /// `images: false` is a request for a book with no pictures, so it drops
    /// the one already on disk rather than only skipping the download.
    func testEpubImagesFalseDropsTheArticleImage() async throws {
        let (item, imageName) = try readyArticleWithAnImage()

        let input = try await produce(
            item, format: .epub,
            options: PluginExportFixtures.export(epubProfile: "standard", epubImages: false))

        let archive = try XCTUnwrap(ZipArchiveReader(data: data(of: XCTUnwrap(input.file))))
        XCTAssertFalse(archive.paths.contains { $0.hasPrefix("OEBPS/images/") })
        XCTAssertFalse(try XCTUnwrap(archive.text(at: "OEBPS/chapter.xhtml")).contains("<img"))
        let compact = try await produce(item, format: .epub,
            options: PluginExportFixtures.export(epubProfile: "compact", epubImages: false))
        XCTAssertFalse(try XCTUnwrap(ZipArchiveReader(data: data(of: XCTUnwrap(compact.file))))
            .paths.contains { $0.hasPrefix("OEBPS/images/") })
    }

    func testImportedEpubBecomesReadableAndExportsThroughAnExternalPlugin() async throws {
        let (source, _) = try readyArticleWithAnImage()
        let url = try ArticleExportService(store: store).write(.epub, for: source)
        let imported = try XCTUnwrap(store.addImportedDocument(sourceURL: url, source: .manual))
        await ArticleIngestHandler().ingestDocument(imported, store: store)
        let ready = try XCTUnwrap(store.item(withID: imported.id))
        XCTAssertEqual(ready.state, .ready)
        XCTAssertEqual(ready.documentType, "epub")
        XCTAssertEqual(PluginExportInputProducer.kind(of: ready), .article)
        XCTAssertTrue(try XCTUnwrap(store.content(for: ready)).blocks.contains { $0.text == "Words." })
        let input = try await produce(ready, format: .epub,
            options: PluginExportFixtures.export(epubProfile: "compact"))
        let archive = try XCTUnwrap(ZipArchiveReader(data: data(of: XCTUnwrap(input.file))))
        XCTAssertNotNil(archive.data(at: "OEBPS/images/banner.png"))
        XCTAssertTrue(try XCTUnwrap(archive.text(at: "OEBPS/chapter.xhtml")).contains("Words."))
    }

    func testTextFormatsCarryTextAndNoFile() async throws {
        let item = readyArticle()

        let markdown = try await produce(item, format: .markdown)
        let plain = try await produce(item, format: .text)

        XCTAssertNil(markdown.file)
        XCTAssertNil(plain.file)
        XCTAssertTrue(markdown.text?.contains("An Article") == true, markdown.text ?? "nil")
        XCTAssertTrue(plain.text?.contains("Words.") == true, plain.text ?? "nil")
    }

    func testHTMLFormatCarriesTheReaderSourceHTML() async throws {
        let item = readyArticle()
        store.saveReaderSourceHTML("<html><body>original</body></html>", for: item.id)

        let input = try await produce(item, format: .html)

        XCTAssertEqual(input.text, "<html><body>original</body></html>")
    }

    func testArticleJSONCarriesTheExtractedContent() async throws {
        let item = readyArticle()

        let input = try await produce(item, format: .json)
        let text = try json(of: input)

        XCTAssertTrue(text.contains("\"title\":\"An Article\""), text)
        XCTAssertTrue(text.contains("Words."), text)
        XCTAssertTrue(text.contains("\"kind\":\"article\""), text)
    }

    func testAnArticleWithNoContentRefuses() async throws {
        let item = store.add(urlString: "https://example.com/pending")

        do {
            _ = try await produce(item, format: .markdown)
            XCTFail("a save with no extracted content has nothing to export")
        } catch {
            XCTAssertEqual(error as? PluginExportInputError, .noContent)
        }
    }

    // MARK: - Media

    /// A media save is one the pipeline recognized as a platform item; that is
    /// the shape `kind(of:)` reads, the same way each card deck does.
    private func mediaSave() throws -> SavedItem {
        let item = store.add(urlString: "https://videos.example.com/clip")
        return try XCTUnwrap(store.savePlatformMetadata(
            platform: .youtube, platformItemID: "abc", title: "A Clip",
            thumbnailFileName: nil, for: item.id))
    }

    func testMediaFileInputHandsTheDownloadedFileThroughAHandle() async throws {
        let item = try mediaSave()
        let fileURL = containerURL.appendingPathComponent("clip.mp4")
        try Data("video-bytes".utf8).write(to: fileURL)
        let locator = StubMediaFileLocator(url: fileURL)

        let input = try await produce(item, format: .file, mediaFiles: locator)

        let handle = try XCTUnwrap(input.file)
        XCTAssertEqual(handle.name, "clip.mp4")
        XCTAssertEqual(try data(of: handle), Data("video-bytes".utf8))
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: fileURL.path),
            "the library's own file is linked, never moved")
    }

    func testMediaFileInputRefusesWhenNothingIsDownloaded() async throws {
        let item = try mediaSave()

        do {
            _ = try await produce(
                item, format: .file, mediaFiles: StubMediaFileLocator(url: nil))
            XCTFail("a media save with no file has no file to export")
        } catch {
            XCTAssertEqual(error as? PluginExportInputError, .noContent)
        }
    }

    /// An article save cannot be handed the media `file` format. The manifest
    /// parser refuses such a declaration; the producer refuses it too, because
    /// a wiring fault must not produce a silent empty export.
    func testAnUnavailableKindAndFormatPairRefuses() async throws {
        let item = readyArticle()

        do {
            _ = try await produce(item, format: .file)
            XCTFail("an article has no downloaded file")
        } catch {
            XCTAssertEqual(
                error as? PluginExportInputError,
                .formatUnavailable(kind: .article, format: .file))
        }
    }

    // MARK: - Product

    func testProductJSONCarriesStoresAndPricePoints() async throws {
        let item = store.add(urlString: "https://shop.example.com/p")
        var tracker = PriceTracker(
            productName: "Widget", firstStoreURL: "https://shop.example.com/p",
            price: 9, currency: "USD", brand: nil, productID: nil)
        tracker.upsertStore(PriceTrackerStore(
            urlString: "https://other.example.com/p", lastPrice: 7, currency: "USD",
            priceHistory: [PriceDaySnapshot(
                dayStart: Date(timeIntervalSince1970: 1_700_000_000), lowestPrice: 7,
                currency: "USD", fxRate: nil)]))
        _ = store.savePriceTracker(tracker, for: item.id)
        let fresh = try XCTUnwrap(store.item(withID: item.id))

        let input = try await produce(fresh, format: .json)
        let text = try json(of: input)

        XCTAssertEqual(input.kind, .product)
        XCTAssertTrue(text.contains("other.example.com"), text)
        XCTAssertTrue(text.contains("\"lowestPrice\""), text)
        XCTAssertTrue(
            text.contains("2023-11-14") || text.contains("2023-11-15"),
            "a date reaches a plugin as ISO-8601: \(text)")
    }

    // MARK: - Envelope

    func testTheInputNamesTheSaveTheFormatAndTheCaptureSource() async throws {
        let item = store.add(urlString: "https://example.com/article", source: .shareSheet)
        let ready = store.saveContent(
            ArticleContent(
                title: "An Article",
                blocks: [ArticleContent.Block(kind: .paragraph, text: "Words.", links: [])]),
            for: item)

        let producer = PluginExportInputProducer(store: store)
        let input = try await producer.makeInput(
            saveID: ready.id, format: .url, options: PluginExportFixtures.export(input: "url"),
            auto: true, queuedRemaining: 3, scratch: scratch, pluginID: "test.plugin",
            generation: "one")

        XCTAssertEqual(input.saveID, ready.id)
        XCTAssertEqual(input.url, "https://example.com/article")
        XCTAssertEqual(input.title, "An Article")
        XCTAssertEqual(input.format, .url)
        XCTAssertTrue(input.auto)
        XCTAssertEqual(input.queuedRemaining, 3)
        XCTAssertEqual(input.source, CaptureSource.shareSheet.rawValue)
    }

    // MARK: - Helpers

    private static func contains(_ data: Data, _ text: String) -> Bool {
        data.range(of: Data(text.utf8)) != nil
    }
}

private final class StubMediaFileLocator: PluginExportMediaFileLocating {
    private let url: URL?
    init(url: URL?) { self.url = url }
    func mediaFileURL(forSaveID saveID: UUID) -> URL? { url }
}
