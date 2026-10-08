//
//  ArticleDocumentBuilderTests.swift
//  LunaTests
//

import ImageIO
import LunaModels
import LunaSend
import UIKit
import UniformTypeIdentifiers
import XCTest

/// The Markdown / plain-text / PDF / DOCX serializers behind the "Export as…"
/// formats and the double-save "View immediately" action.
final class ArticleDocumentBuilderTests: XCTestCase {

    private var scratch: URL!

    override func setUp() {
        super.setUp()
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArticleDoc-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: scratch)
        super.tearDown()
    }

    private func content(_ blocks: [ArticleContent.Block],
                         title: String = "Title", author: String? = "Ada") -> ArticleContent {
        ArticleContent(title: title, author: author, blocks: blocks)
    }

    private func block(_ kind: ArticleContent.Block.Kind, _ text: String,
                       links: [ArticleContent.Link] = []) -> ArticleContent.Block {
        ArticleContent.Block(kind: kind, text: text, links: links)
    }

    /// Writes a real image into the scratch images directory and returns an
    /// image block pointing at it. Defaults to a 2x2 PNG.
    private func imageBlock(alt: String, fileName: String = "pic.png",
                            remote: String? = "https://example.com/pic.png",
                            data: Data? = nil) -> ArticleContent.Block {
        let bytes = data ?? UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }.pngData()!
        try? bytes.write(to: scratch.appendingPathComponent(fileName))
        return ArticleContent.Block(
            kind: .image, text: alt, links: [],
            imageURLString: remote, imageFileName: fileName)
    }

    /// An image block with NO recorded `imageFileName`, whose file sits on disk
    /// under an unrelated generated name — the state content is in
    /// between "saved" and "images finished downloading".
    private func hashNamedImageBlock(remote: String) -> ArticleContent.Block {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 30)).image { context in
            UIColor.blue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 40, height: 30))
        }
        let name = ArticleImageFiles.newFileName(fileExtension: "png")
        try? image.pngData()?.write(to: scratch.appendingPathComponent(name))
        return ArticleContent.Block(
            kind: .image, text: "Unrecorded", links: [],
            imageURLString: remote, imageFileName: nil)
    }

    private func animatedGIFData(frames: Int) -> Data {
        let output = NSMutableData()
        let destination = CGImageDestinationCreateWithData(
            output, UTType.gif.identifier as CFString, frames, nil)!
        for index in 0..<frames {
            let frame = UIGraphicsImageRenderer(size: CGSize(width: 30, height: 20)).image { context in
                (index % 2 == 0 ? UIColor.green : UIColor.blue).setFill()
                context.fill(CGRect(x: 0, y: 0, width: 30, height: 20))
            }
            CGImageDestinationAddImage(destination, frame.cgImage!, [
                kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.1]
            ] as CFDictionary)
        }
        CGImageDestinationFinalize(destination)
        return output as Data
    }

    private func encodedImage(as type: UTType) -> Data? {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 60, height: 40)).image { context in
            UIColor.orange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 60, height: 40))
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, type.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image.cgImage!, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    // MARK: - Markdown

    func testMarkdownHeaderCarriesTitleAuthorAndSource() {
        let markdown = ArticleMarkdownBuilder().build(
            content: content([block(.paragraph, "Hello.")]),
            sourceURLString: "https://example.com/a")
        XCTAssertTrue(markdown.hasPrefix("# Title\n\n*Ada*"), markdown)
        XCTAssertTrue(markdown.contains("[https://example.com/a](https://example.com/a)"))
        XCTAssertTrue(markdown.contains("\n---\n"))
    }

    func testMarkdownRendersEachBlockKind() {
        let markdown = ArticleMarkdownBuilder().build(
            content: content([
                block(.heading, "Section"),
                block(.paragraph, "Body."),
                block(.quote, "Quoted."),
                block(.listItem, "Point."),
                imageBlock(alt: "A photo"),
            ]),
            sourceURLString: "https://example.com/a")
        XCTAssertTrue(markdown.contains("## Section"))
        XCTAssertTrue(markdown.contains("\nBody.\n"))
        XCTAssertTrue(markdown.contains("> Quoted."))
        XCTAssertTrue(markdown.contains("- Point."))
        // Images reference the REMOTE url: a local file reference would dangle
        // the moment the .md leaves Luna's container.
        XCTAssertTrue(markdown.contains("![A photo](https://example.com/pic.png)"))
    }

    func testMarkdownDropsImageWithoutRemoteURL() {
        let markdown = ArticleMarkdownBuilder().build(
            content: content([imageBlock(alt: "Local only", remote: nil)]),
            sourceURLString: "https://example.com/a")
        XCTAssertFalse(markdown.contains("Local only"))
    }

    func testMarkdownRendersInlineLinksAndLeavesInPageAnchorsPlain() {
        let text = "See the docs and the map."
        let docs = ArticleContent.Link(
            start: (text as NSString).range(of: "docs").location, length: 4,
            urlString: "https://example.com/docs")
        let map = ArticleContent.Link(
            start: (text as NSString).range(of: "map").location, length: 3,
            urlString: "https://example.com/a#map", anchorID: "map")
        let markdown = ArticleMarkdownBuilder().build(
            content: content([block(.paragraph, text, links: [map, docs])]),
            sourceURLString: "https://example.com/a")

        XCTAssertTrue(markdown.contains("[docs](https://example.com/docs)"), markdown)
        // The in-page jump has no destination in a standalone file.
        XCTAssertFalse(markdown.contains("[map]"))
        XCTAssertTrue(markdown.contains("and the map."))
    }

    func testMarkdownEscapesInlineMarkers() {
        let markdown = ArticleMarkdownBuilder().build(
            content: content([block(.paragraph, "a * b _c_ [d] `e`")], author: nil),
            sourceURLString: "")
        XCTAssertTrue(markdown.contains(#"a \* b \_c\_ \[d\] \`e\`"#), markdown)
    }

    /// A URL with parentheses would close the `(...)` destination early.
    func testMarkdownWrapsAwkwardURLInAngleBrackets() {
        let text = "link"
        let link = ArticleContent.Link(
            start: 0, length: 4, urlString: "https://example.com/a_(b)")
        let markdown = ArticleMarkdownBuilder().build(
            content: content([block(.paragraph, text, links: [link])]),
            sourceURLString: "")
        XCTAssertTrue(markdown.contains("[link](<https://example.com/a_(b)>)"), markdown)
    }

    /// Extraction can hand back a link range past the end of the text; it must not
    /// trap or truncate the prose.
    func testMarkdownIgnoresOutOfBoundsLinkRange() {
        let link = ArticleContent.Link(start: 3, length: 99, urlString: "https://example.com/x")
        let markdown = ArticleMarkdownBuilder().build(
            content: content([block(.paragraph, "Short.", links: [link])]),
            sourceURLString: "")
        XCTAssertTrue(markdown.contains("Short."))
        XCTAssertFalse(markdown.contains("example.com/x"))
    }

    // MARK: - Plain text

    func testPlainTextHasNoMarkupAndNoInlineURLs() {
        let text = "See the docs."
        let link = ArticleContent.Link(
            start: (text as NSString).range(of: "docs").location, length: 4,
            urlString: "https://example.com/docs")
        let plain = ArticlePlainTextBuilder().build(
            content: content([
                block(.heading, "Section"),
                block(.paragraph, text, links: [link]),
                block(.quote, "Quoted."),
                block(.listItem, "Point."),
                imageBlock(alt: "A photo"),
            ]),
            sourceURLString: "https://example.com/a")

        XCTAssertTrue(plain.hasPrefix("Title\n\nby Ada\n\nhttps://example.com/a"), plain)
        XCTAssertTrue(plain.contains("SECTION"))
        XCTAssertTrue(plain.contains("See the docs."))
        // Body prose stays clean — inline destinations are the Markdown export's job.
        XCTAssertFalse(plain.contains("example.com/docs"))
        XCTAssertTrue(plain.contains("    Quoted."))
        XCTAssertTrue(plain.contains("  • Point."))
        XCTAssertTrue(plain.contains("[Image: A photo]"))
        XCTAssertFalse(plain.contains("*"))
        XCTAssertFalse(plain.contains("#"))
    }

    func testPlainTextUsesBareImagePlaceholderWithoutAltText() {
        let plain = ArticlePlainTextBuilder().build(
            content: content([imageBlock(alt: "  ")]),
            sourceURLString: "")
        XCTAssertTrue(plain.contains("[Image]"))
    }

    func testPlainTextOmitsAbsentAuthorAndSource() {
        let plain = ArticlePlainTextBuilder().build(
            content: content([block(.paragraph, "Body.")], author: nil),
            sourceURLString: "")
        XCTAssertTrue(plain.hasPrefix("Title\n\n="), plain)
    }

    // MARK: - PDF

    func testPDFIsAValidSinglePageDocument() throws {
        let data = ArticlePDFBuilder().build(
            content: content([block(.paragraph, "Body.")]),
            sourceURLString: "https://example.com/a",
            imagesDirectory: scratch)
        XCTAssertEqual(String(decoding: data.prefix(4), as: UTF8.self), "%PDF")

        let document = try XCTUnwrap(CGPDFDocument(CGDataProvider(data: data as CFData)!))
        XCTAssertEqual(document.numberOfPages, 1)
        let page = try XCTUnwrap(document.page(at: 1))
        // US Letter at 72dpi.
        XCTAssertEqual(page.getBoxRect(.mediaBox).size, CGSize(width: 612, height: 792))
    }

    /// A long article has to paginate rather than clip at one page.
    func testPDFPaginatesLongContent() throws {
        let paragraph = String(repeating: "Lorem ipsum dolor sit amet. ", count: 40)
        let blocks = (0..<40).map { _ in block(.paragraph, paragraph) }
        let data = ArticlePDFBuilder().build(
            content: content(blocks), sourceURLString: "https://example.com/a",
            imagesDirectory: scratch)
        let document = try XCTUnwrap(CGPDFDocument(CGDataProvider(data: data as CFData)!))
        XCTAssertGreaterThan(document.numberOfPages, 1)
    }

    /// Counts real `/Subtype /Image` XObjects across every page. A byte-count
    /// comparison cannot tell an embedded picture from an empty line where one
    /// should have been.
    private func pdfImageCount(_ data: Data) throws -> Int {
        let document = try XCTUnwrap(CGPDFDocument(CGDataProvider(data: data as CFData)!))
        var total = 0
        for number in 1...max(1, document.numberOfPages) {
            guard let page = document.page(at: number), let dict = page.dictionary
            else { continue }
            var resources: CGPDFDictionaryRef?
            guard CGPDFDictionaryGetDictionary(dict, "Resources", &resources),
                  let resources else { continue }
            var xobjects: CGPDFDictionaryRef?
            guard CGPDFDictionaryGetDictionary(resources, "XObject", &xobjects),
                  let xobjects else { continue }
            CGPDFDictionaryApplyBlock(xobjects, { _, value, _ in
                var stream: CGPDFStreamRef?
                guard CGPDFObjectGetValue(value, .stream, &stream), let stream,
                      let streamDict = CGPDFStreamGetDictionary(stream) else { return true }
                var subtype: UnsafePointer<Int8>?
                if CGPDFDictionaryGetName(streamDict, "Subtype", &subtype), let subtype,
                   String(cString: subtype) == "Image" { total += 1 }
                return true
            }, nil)
        }
        return total
    }

    /// The downloaded image really lands in the PDF as an image XObject; a block
    /// whose file is missing is skipped rather than failing the export.
    func testPDFEmbedsDownloadedImageAndSkipsMissingOne() throws {
        let present = ArticlePDFBuilder().build(
            content: content([imageBlock(alt: "A photo")]),
            sourceURLString: "", imagesDirectory: scratch)
        let missing = ArticlePDFBuilder().build(
            content: content([ArticleContent.Block(
                kind: .image, text: "A photo", links: [], imageFileName: "gone.png")]),
            sourceURLString: "", imagesDirectory: scratch)

        XCTAssertEqual(try pdfImageCount(present), 1)
        XCTAssertEqual(String(decoding: missing.prefix(4), as: UTF8.self), "%PDF")
        XCTAssertEqual(try pdfImageCount(missing), 0)
    }

    /// An unrecorded image cannot be found by deriving a path from its URL.
    func testPDFDoesNotGuessAnImagePathWhenFileNameIsUnrecorded() throws {
        let block = hashNamedImageBlock(remote: "https://example.com/unrecorded.png")
        XCTAssertNil(block.imageFileName, "precondition: content recorded no file name")
        let data = ArticlePDFBuilder().build(
            content: content([block]), sourceURLString: "", imagesDirectory: scratch)
        XCTAssertEqual(try pdfImageCount(data), 0)
    }

    /// PDF has no animation, so a GIF contributes its first frame rather than
    /// being dropped.
    func testPDFEmbedsAnimatedGIFAsAStill() throws {
        let block = imageBlock(
            alt: "Loop", fileName: "loop.gif", data: animatedGIFData(frames: 4))
        let data = ArticlePDFBuilder().build(
            content: content([block]), sourceURLString: "", imagesDirectory: scratch)
        XCTAssertEqual(try pdfImageCount(data), 1)
    }

    /// Every format the downloader can leave on disk has to survive into the
    /// PDF — a stored HEIC/AVIF/WebP that silently vanishes is the same bug in
    /// a different coat.
    func testPDFEmbedsEveryStoredImageFormat() throws {
        for (ext, type) in [("jpg", UTType.jpeg), ("png", .png), ("heic", .heic),
                            ("img", UTType.jpeg)] {
            guard let bytes = encodedImage(as: type) else {
                XCTFail("could not encode \(ext)"); continue
            }
            let block = imageBlock(alt: ext, fileName: "photo.\(ext)", data: bytes)
            let data = ArticlePDFBuilder().build(
                content: content([block]), sourceURLString: "", imagesDirectory: scratch)
            XCTAssertEqual(try pdfImageCount(data), 1, "\(ext) was dropped")
        }
    }

    /// The share sheet builds off the main thread, so layout must not require it.
    func testPDFBuildsOffMainThread() {
        let expectation = expectation(description: "built")
        DispatchQueue.global(qos: .userInitiated).async {
            let data = ArticlePDFBuilder().build(
                content: self.content([self.block(.paragraph, "Body.")]),
                sourceURLString: "https://example.com/a",
                imagesDirectory: self.scratch)
            XCTAssertEqual(String(decoding: data.prefix(4), as: UTF8.self), "%PDF")
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 10)
    }

    // MARK: - Word document (DOCX)

    private func docx(
        _ blocks: [ArticleContent.Block],
        sourceURLString: String = "https://example.com/a"
    ) -> Data {
        ArticleDOCXBuilder().build(
            content: content(blocks), sourceURLString: sourceURLString,
            imagesDirectory: scratch)
    }

    /// `ZipArchiveWriter` stores entries, so a tiny local-header reader is enough
    /// to inspect DOCX parts without adding a ZIP dependency to the tests.
    private func zipEntry(_ path: String, in archive: Data) -> Data? {
        let bytes = [UInt8](archive)
        func u16(_ offset: Int) -> Int {
            Int(bytes[offset]) | (Int(bytes[offset + 1]) << 8)
        }
        func u32(_ offset: Int) -> Int {
            u16(offset) | (u16(offset + 2) << 16)
        }
        var offset = 0
        while offset + 30 <= bytes.count,
              Array(bytes[offset..<(offset + 4)]) == [0x50, 0x4B, 0x03, 0x04] {
            let size = u32(offset + 18)
            let nameLength = u16(offset + 26)
            let extraLength = u16(offset + 28)
            let nameStart = offset + 30
            let dataStart = nameStart + nameLength + extraLength
            guard dataStart + size <= bytes.count else { return nil }
            let name = String(decoding: bytes[nameStart..<(nameStart + nameLength)], as: UTF8.self)
            if name == path { return Data(bytes[dataStart..<(dataStart + size)]) }
            offset = dataStart + size
        }
        return nil
    }

    func testDOCXIsARegularZipWithRequiredPartsAndLiveLinks() throws {
        let data = docx([block(
            .paragraph, "See the docs here.",
            links: [ArticleContent.Link(
                start: 8, length: 4, urlString: "https://example.com/docs")])])
        XCTAssertEqual(data.prefix(4), Data([0x50, 0x4B, 0x03, 0x04]))
        let document = String(decoding: try XCTUnwrap(
            zipEntry("word/document.xml", in: data)), as: UTF8.self)
        let relationships = String(decoding: try XCTUnwrap(
            zipEntry("word/_rels/document.xml.rels", in: data)), as: UTF8.self)
        XCTAssertTrue(document.contains("Title"), document)
        XCTAssertTrue(document.contains("Ada"), document)
        XCTAssertTrue(document.contains("<w:hyperlink r:id="), document)
        XCTAssertTrue(relationships.contains("https://example.com/docs"), relationships)
        let contentTypes = try XCTUnwrap(zipEntry("[Content_Types].xml", in: data))
        let rootRelationships = try XCTUnwrap(zipEntry("_rels/.rels", in: data))
        for xml in [Data(document.utf8), Data(relationships.utf8),
                    contentTypes, rootRelationships] {
            let parser = XMLParser(data: xml)
            XCTAssertTrue(parser.parse(), parser.parserError?.localizedDescription ?? "invalid XML")
        }
    }

    func testDOCXBundlesReadableBytesAndUsesDeclaredDisplaySize() throws {
        let sourceBytes = try XCTUnwrap(encodedImage(as: .jpeg))
        var image = imageBlock(
            alt: "Photo", fileName: "source-photo.jpg", data: sourceBytes)
        image.imageSize = ArticleContent.BlockImageSize(width: 120, height: 80)
        let data = docx([image])
        try FileManager.default.removeItem(
            at: scratch.appendingPathComponent("source-photo.jpg"))

        let bundled = try XCTUnwrap(zipEntry("word/media/image001.jpg", in: data))
        XCTAssertEqual(bundled, sourceBytes)
        XCTAssertNotNil(UIImage(data: bundled))
        let document = String(decoding: try XCTUnwrap(
            zipEntry("word/document.xml", in: data)), as: UTF8.self)
        XCTAssertTrue(document.contains("cx=\"1143000\" cy=\"762000\""), document)
        XCTAssertFalse(document.contains(scratch.path), document)
    }

    func testDOCXCapsOversizedDeclaredImageToThreeAndAHalfInches() throws {
        let sourceBytes = try XCTUnwrap(encodedImage(as: .jpeg))
        var image = imageBlock(alt: "Large", fileName: "large.jpg", data: sourceBytes)
        image.imageSize = ArticleContent.BlockImageSize(width: 2_000, height: 1_000)
        let document = String(decoding: try XCTUnwrap(zipEntry(
            "word/document.xml", in: docx([image]))), as: UTF8.self)
        // 336 CSS px × 9,525 EMU = 3.5 inches; aspect remains 2:1.
        XCTAssertTrue(document.contains("cx=\"3200400\" cy=\"1600200\""), document)
    }

    func testDOCXTranscodesUnsupportedImageAndKeepsMissingPlaceholder() throws {
        let heic = try XCTUnwrap(encodedImage(as: .heic))
        let converted = docx([
            imageBlock(alt: "Shot", fileName: "shot.heic", data: heic),
        ])
        XCTAssertNotNil(zipEntry("word/media/image001.png", in: converted))

        let missing = docx([ArticleContent.Block(
            kind: .image, text: "A chart", links: [],
            imageURLString: "https://example.com/gone.png", imageFileName: nil)])
        XCTAssertNil(zipEntry("word/media/image001.png", in: missing))
        let document = String(decoding: try XCTUnwrap(
            zipEntry("word/document.xml", in: missing)), as: UTF8.self)
        XCTAssertTrue(document.contains("[A chart]"), document)
    }

    func testDOCXDoesNotGuessAnImagePathWhenFileNameWasNotRecorded() {
        let data = docx([
            hashNamedImageBlock(remote: "https://example.com/docx-unrecorded.png"),
        ])
        XCTAssertNil(zipEntry("word/media/image001.png", in: data))
    }

    // MARK: - Format descriptors

    func testBothEpubOptionsUseTheEpubExtension() {
        let extensions = ArticleExportFormat.allCases.map(\.fileExtension)
        XCTAssertEqual(extensions, ["epub", "epub", "pdf", "md", "txt", "docx"])
        XCTAssertEqual(Set(extensions).count, extensions.count - 1)
    }

    /// The share menu is a SUBSET of the serializers: it offers the same Word
    /// document the double save's App Intent returns
    /// (claudedocs/double-save.md), and `.markdown` stays a serializer that no
    /// menu item reaches.
    func testShareMenuOffersTheDocumentAndOmitsMarkdown() {
        XCTAssertEqual(
            ArticleExportFormat.shareMenuFormats, [.epub, .compactEpub, .pdf, .document, .plainText])
        XCTAssertFalse(ArticleExportFormat.shareMenuFormats.contains(.markdown))
    }

    func testFileNameSanitizesAndAppliesExtension() {
        XCTAssertEqual(
            ArticleSendCoordinator.fileName(forTitle: "A/B:C?", extension: "md"),
            "A B C.md")
        XCTAssertEqual(
            ArticleSendCoordinator.fileName(forTitle: "   ", extension: "txt"),
            "Article.txt")
        // The EPUB spelling stays a thin alias of the general form.
        XCTAssertEqual(
            ArticleSendCoordinator.epubFileName(forTitle: "Book"),
            ArticleSendCoordinator.fileName(forTitle: "Book", extension: "epub"))
    }
}
