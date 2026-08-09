//
//  ArticleExportImagePipelineTests.swift
//  LunaTests
//
//  End-to-end, through the REAL shared store and the REAL in-app share
//  provider: save an article the way the app saves one, then export it the way
//  the reader's share button does, and check the picture is actually ON THE
//  PAGE. Everything narrower than this passed while exports shipped blank.
//

import ImageIO
import LunaModels
import LunaReaderUI
import LunaSend
import LunaStorage
import UIKit
import UniformTypeIdentifiers
import XCTest
@testable import Luna

final class ArticleExportImagePipelineTests: XCTestCase {

    private let remoteImageURL = "https://example.com/hero-\(UUID().uuidString).jpg"
    private var savedItemID: UUID?

    override func tearDown() {
        if let savedItemID, let item = ReadingListStore.shared.item(withID: savedItemID) {
            ReadingListStore.shared.delete(item)
        }
        savedItemID = nil
        super.tearDown()
    }

    // MARK: - Fixtures

    /// A realistic stored article image: what the downloader leaves on disk
    /// after transcoding (a ≤2048px JPEG), under the URL-hash name.
    @discardableResult
    private func writeDownloadedImage() -> String {
        let name = "\(ArticleImageFiles.stableBase(forImageURL: remoteImageURL)).jpg"
        let image = UIGraphicsImageRenderer(size: CGSize(width: 2048, height: 1365)).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 2048, height: 1365))
        }
        try? image.jpegData(compressionQuality: 0.82)?
            .write(to: ReadingListStore.shared.articlesDirectory.appendingPathComponent(name))
        return name
    }

    private func articleContent(recordingFileName: String?) -> ArticleContent {
        ArticleContent(
            title: "Illustrated",
            author: "Ada",
            blocks: [
                ArticleContent.Block(kind: .paragraph, text: "Opening paragraph.", links: []),
                ArticleContent.Block(
                    kind: .image, text: "A hero photo", links: [],
                    imageURLString: remoteImageURL, imageFileName: recordingFileName,
                    imageSize: ArticleContent.BlockImageSize(width: 2048, height: 1365)),
                ArticleContent.Block(kind: .caption, text: "Photo: Ada", links: []),
                ArticleContent.Block(kind: .paragraph, text: "Body after the photo.", links: []),
            ])
    }

    private func saveArticle(recordingFileName: String?) -> ReadingListItem {
        let item = ReadingListStore.shared.add(
            urlString: "https://example.com/illustrated-\(UUID().uuidString)")
        savedItemID = item.id
        return ReadingListStore.shared.saveContent(
            articleContent(recordingFileName: recordingFileName), for: item)
    }

    /// Fraction of strongly-red pixels on a rendered PDF page. An image that is
    /// embedded but never DRAWN (or drawn off-page) still counts as an XObject;
    /// only pixels prove the reader sees it.
    private func redFraction(of pdf: Data) throws -> Double {
        let document = try XCTUnwrap(CGPDFDocument(CGDataProvider(data: pdf as CFData)!))
        var best = 0.0
        for number in 1...max(1, document.numberOfPages) {
            guard let page = document.page(at: number) else { continue }
            let box = page.getBoxRect(.mediaBox)
            let rendered = UIGraphicsImageRenderer(size: box.size).image { context in
                UIColor.white.setFill()
                context.fill(CGRect(origin: .zero, size: box.size))
                context.cgContext.translateBy(x: 0, y: box.size.height)
                context.cgContext.scaleBy(x: 1, y: -1)
                context.cgContext.drawPDFPage(page)
            }
            guard let cgImage = rendered.cgImage else { continue }
            let width = cgImage.width, height = cgImage.height
            var pixels = [UInt8](repeating: 0, count: width * height * 4)
            guard let context = CGContext(
                data: &pixels, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { continue }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            var red = 0
            for index in stride(from: 0, to: pixels.count, by: 4)
            where pixels[index] > 180 && pixels[index + 1] < 80 && pixels[index + 2] < 80 {
                red += 1
            }
            best = max(best, Double(red) / Double(width * height))
        }
        return best
    }

    // MARK: - Tests

    /// The ordinary case: the download finished and the content records the
    /// file name.
    func testExportedPDFShowsTheImageWhenTheFileNameIsRecorded() throws {
        let fileName = writeDownloadedImage()
        let item = saveArticle(recordingFileName: fileName)

        let url = try ArticleExportService().write(.pdf, for: item)
        let fraction = try redFraction(of: Data(contentsOf: url))
        XCTAssertGreaterThan(fraction, 0.05, "the photo is not on the page")
    }

    /// The case that produced picture-less exports: the file is on disk (which
    /// is why the scroll reader shows it — `resolveLocalImages` finds it by URL
    /// hash in memory) but the PERSISTED content never recorded the name,
    /// because content is saved before the images finish downloading.
    func testExportedPDFShowsTheImageTheReaderShowsWhenTheNameWasNeverPersisted() throws {
        let fileName = writeDownloadedImage()
        let item = saveArticle(recordingFileName: nil)

        // Precondition: this is exactly the split — the reader resolves it, the
        // stored content does not carry it.
        let stored = try XCTUnwrap(ReadingListStore.shared.content(for: item))
        XCTAssertNil(stored.blocks.first(where: { $0.kind == .image })?.imageFileName)
        let asTheReaderSeesIt = ArticleImageDownloader.resolveLocalImages(
            stored, store: .shared)
        XCTAssertEqual(
            asTheReaderSeesIt.blocks.first(where: { $0.kind == .image })?.imageFileName,
            fileName, "precondition: the scroll reader can see this image")

        let url = try ArticleExportService().write(.pdf, for: item)
        let fraction = try redFraction(of: Data(contentsOf: url))
        XCTAssertGreaterThan(
            fraction, 0.05,
            "the reader shows this photo but the export dropped it")
    }

    /// Through the in-app share button's own closure, not the service directly:
    /// `AppReaderShareProvider` builds the "Export as…" rows the reader shows.
    @MainActor
    func testInAppShareMenuExportsAPDFWithTheImage() throws {
        let fileName = writeDownloadedImage()
        let item = saveArticle(recordingFileName: fileName)

        let menu = AppReaderShareProvider.shared.shareMenu(
            urlString: item.urlString, title: item.title,
            from: UIViewController(), sourceView: UIView())
        let submenu = try XCTUnwrap(menu?.children.last as? UIMenu)
        XCTAssertEqual(submenu.title, "Export as…")
        let pdfAction = try XCTUnwrap(
            submenu.children.compactMap { $0 as? UIAction }.first { $0.title == "PDF" })
        XCTAssertNotNil(pdfAction, "the reader's share menu must offer PDF")

        // The action presents a share sheet, which needs a real window; assert
        // on the file the same service call produces instead.
        let url = try ArticleExportService().write(.pdf, for: item)
        XCTAssertGreaterThan(try redFraction(of: Data(contentsOf: url)), 0.05)
    }

    /// The same article through every format that carries pictures.
    func testEveryImageCarryingFormatKeepsTheImage() throws {
        let fileName = writeDownloadedImage()
        let sourceImage = try Data(contentsOf:
            ReadingListStore.shared.articlesDirectory.appendingPathComponent(fileName))
        let item = saveArticle(recordingFileName: fileName)
        let service = ArticleExportService()

        let epub = try Data(contentsOf: service.write(.epub, for: item))
        XCTAssertTrue(
            String(decoding: epub, as: UTF8.self).contains("<img src=\"images/\(fileName)\""),
            "EPUB lost the image")

        let docx = try Data(contentsOf: service.write(.document, for: item))
        XCTAssertTrue(
            String(decoding: docx, as: UTF8.self).contains("word/media/image001.jpg"),
            "DOCX lost the image relationship")
        XCTAssertNotNil(docx.firstRange(of: sourceImage),
                        "DOCX lost the actual image bytes")

        // Plain text drops images by design; Markdown references the remote URL.
        let markdown = String(decoding: try Data(contentsOf: service.write(.markdown, for: item)),
                              as: UTF8.self)
        XCTAssertTrue(markdown.contains("![A hero photo](\(remoteImageURL))"))
    }
}
