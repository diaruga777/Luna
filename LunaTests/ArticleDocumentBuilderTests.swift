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

/// The Markdown / plain-text / PDF / RTFD serializers behind the "Export as…"
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
    /// under the URL-hash name the downloader uses — the state content is in
    /// between "saved" and "images finished downloading".
    private func hashNamedImageBlock(remote: String) -> ArticleContent.Block {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 30)).image { context in
            UIColor.blue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 40, height: 30))
        }
        let name = "\(ArticleImageFiles.stableBase(forImageURL: remote)).png"
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

    /// Counts real `/Subtype /Image` XObjects across every page. Comparing byte
    /// counts (what this used to do) cannot tell an embedded picture from an
    /// empty line where one should have been.
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

    /// The regression this whole path exists for: content is persisted BEFORE
    /// its images finish downloading, so an image block routinely has no
    /// `imageFileName` while the file is already on disk under its URL hash.
    /// Trusting the recorded name alone is what shipped picture-less exports.
    func testPDFEmbedsImageResolvedByURLHashWhenFileNameIsUnrecorded() throws {
        let block = hashNamedImageBlock(remote: "https://example.com/unrecorded.png")
        XCTAssertNil(block.imageFileName, "precondition: content recorded no file name")
        let data = ArticlePDFBuilder().build(
            content: content([block]), sourceURLString: "", imagesDirectory: scratch)
        XCTAssertEqual(try pdfImageCount(data), 1)
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

    // MARK: - Rich Text with Attachments (RTFD)

    private func rtfd(_ blocks: [ArticleContent.Block],
                      sourceURLString: String = "https://example.com/a") -> FileWrapper {
        ArticleRTFBuilder().build(
            content: content(blocks), sourceURLString: sourceURLString,
            imagesDirectory: scratch)
    }

    private func rtf(_ blocks: [ArticleContent.Block],
                     sourceURLString: String = "https://example.com/a") -> String {
        let data = rtfd(blocks, sourceURLString: sourceURLString)
            .fileWrappers?["TXT.rtf"]?.regularFileContents ?? Data()
        return String(data: data, encoding: .ascii) ?? ""
    }

    private func bundledImages(in wrapper: FileWrapper) -> [String: Data] {
        (wrapper.fileWrappers ?? [:]).reduce(into: [:]) { result, entry in
            guard entry.key != "TXT.rtf", let bytes = entry.value.regularFileContents
            else { return }
            result[entry.key] = bytes
        }
    }

    func testRTFDContainsAWellFormedAsciiRTFBody() {
        let text = rtf([block(.paragraph, "Hello.")])
        XCTAssertTrue(text.hasPrefix("{\\rtf1\\ansi"), String(text.prefix(40)))
        XCTAssertTrue(text.hasSuffix("}"))
        // Every brace is balanced, or no reader will open the file at all.
        XCTAssertEqual(
            text.filter { $0 == "{" }.count, text.filter { $0 == "}" }.count)
    }

    func testRTFHeaderCarriesTitleAuthorAndSource() {
        let text = rtf([block(.paragraph, "Hello.")])
        XCTAssertTrue(text.contains("Title"), text)
        XCTAssertTrue(text.contains("Ada"), text)
        XCTAssertTrue(text.contains("HYPERLINK \"https://example.com/a\""), text)
    }

    /// Unlike PDF and plain text, RTF keeps link DESTINATIONS live.
    func testRTFRendersInlineLinksAsHyperlinkFields() {
        let text = rtf([block(
            .paragraph, "See the docs here.",
            links: [ArticleContent.Link(start: 8, length: 4, urlString: "https://example.com/d")])])
        XCTAssertTrue(
            text.contains("{\\field{\\*\\fldinst{HYPERLINK \"https://example.com/d\"}}"), text)
        XCTAssertTrue(text.contains("docs"), text)
    }

    /// An in-page `#chapter` jump has no destination in a standalone file.
    func testRTFSkipsInPageAnchorLinks() {
        let text = rtf([block(
            .paragraph, "Jump to part two.",
            links: [ArticleContent.Link(
                start: 8, length: 4, urlString: "#two", anchorID: "two")])])
        XCTAssertFalse(text.contains("HYPERLINK \"#two\""), text)
    }

    /// RTF's body is 7-bit ASCII, so prose outside it must survive as `\uN?`
    /// escapes rather than being dropped or corrupting the encode.
    func testRTFEscapesControlCharactersAndNonASCII() {
        let text = rtf([block(.paragraph, "Braces {a} and a backslash \\ and “curly” — em.")])
        XCTAssertTrue(text.contains("\\{a\\}"), text)
        XCTAssertTrue(text.contains("\\\\ and"), text)
        // U+201C “ and U+2014 —
        XCTAssertTrue(text.contains("\\u8220?"), text)
        XCTAssertTrue(text.contains("\\u8212?"), text)
    }

    /// Same regression as the PDF: the file is on disk under its URL hash while
    /// the content recorded no name. RTFD must copy those bytes into the package.
    func testRTFDBundlesImageResolvedByURLHashWhenFileNameIsUnrecorded() {
        let wrapper = rtfd([
            hashNamedImageBlock(remote: "https://example.com/rtf-unrecorded.png"),
        ])
        XCTAssertEqual(bundledImages(in: wrapper).count, 1)
        XCTAssertTrue(rtf([
            hashNamedImageBlock(remote: "https://example.com/rtf-unrecorded-2.png"),
        ]).contains("\\NeXTGraphic LunaImage-001.png"))
    }

    /// RTFD uses a PNG still for an animated GIF rather than dropping it.
    func testRTFDBundlesAnimatedGIFAsAPNGStill() {
        let wrapper = rtfd([imageBlock(
            alt: "Loop", fileName: "loop.gif", data: animatedGIFData(frames: 4))])
        let image = bundledImages(in: wrapper)
        XCTAssertEqual(Array(image.keys), ["LunaImage-001.png"])
        XCTAssertNotNil(image.values.first.flatMap(UIImage.init(data:)))
        XCTAssertFalse(
            String(data: wrapper.fileWrappers?["TXT.rtf"]?.regularFileContents ?? Data(),
                   encoding: .ascii)?.contains("[Loop]") ?? true,
            "fell back to the text placeholder")
    }

    /// A stored HEIC must transcode into the package, not vanish.
    func testRTFDBundlesHEICAsAPNGStill() throws {
        let bytes = try XCTUnwrap(encodedImage(as: .heic))
        let wrapper = rtfd([imageBlock(alt: "Shot", fileName: "shot.heic", data: bytes)])
        XCTAssertEqual(Array(bundledImages(in: wrapper).keys), ["LunaImage-001.png"])
    }

    func testRTFDBundlesDownloadedImageAndPlaceholdersAMissingOne() throws {
        let embedded = rtfd([imageBlock(alt: "A chart")])
        let bundled = try XCTUnwrap(bundledImages(in: embedded).values.first)
        let bundledImage = try XCTUnwrap(UIImage(data: bundled))
        let embeddedRTF = String(
            data: embedded.fileWrappers?["TXT.rtf"]?.regularFileContents ?? Data(),
            encoding: .ascii) ?? ""
        XCTAssertTrue(embeddedRTF.contains("\\NeXTGraphic LunaImage-001.png"), embeddedRTF)
        XCTAssertTrue(embeddedRTF.contains(
            "\\width\(Int(bundledImage.size.width * 15)) "
                + "\\height\(Int(bundledImage.size.height * 15))"), embeddedRTF)

        let missingWrapper = rtfd([ArticleContent.Block(
            kind: .image, text: "A chart", links: [],
            imageURLString: "https://example.com/gone.png", imageFileName: nil)])
        let missing = String(
            data: missingWrapper.fileWrappers?["TXT.rtf"]?.regularFileContents ?? Data(),
            encoding: .ascii) ?? ""
        XCTAssertTrue(bundledImages(in: missingWrapper).isEmpty)
        XCTAssertFalse(missing.contains("\\NeXTGraphic"), missing)
        XCTAssertTrue(missing.contains("[A chart]"), missing)
    }

    /// Regression for the returned App Intent document: its package owns real,
    /// decodable bytes and the RTF references only that sibling attachment with
    /// an explicit rendered size — never Luna's source path.
    func testRTFDAttachmentIsSelfContainedSizedAndReadable() throws {
        let sourceBytes = try XCTUnwrap(encodedImage(as: .jpeg))
        let sourceName = "source-photo.jpg"
        let block = imageBlock(alt: "Photo", fileName: sourceName, data: sourceBytes)
        let wrapper = rtfd([block])
        try FileManager.default.removeItem(at: scratch.appendingPathComponent(sourceName))

        let images = bundledImages(in: wrapper)
        let bundled = try XCTUnwrap(images["LunaImage-001.jpg"])
        XCTAssertEqual(bundled, sourceBytes)
        let bundledImage = try XCTUnwrap(
            UIImage(data: bundled), "bundled attachment bytes must decode")

        let text = String(
            data: try XCTUnwrap(wrapper.fileWrappers?["TXT.rtf"]?.regularFileContents),
            encoding: .ascii) ?? ""
        XCTAssertTrue(text.contains("\\NeXTGraphic LunaImage-001.jpg"), text)
        XCTAssertTrue(text.contains(
            "\\width\(Int(bundledImage.size.width * 15)) "
                + "\\height\(Int(bundledImage.size.height * 15))"), text)
        XCTAssertFalse(text.contains(scratch.path), "RTFD must not reference Luna's files")

        let documentURL = scratch.appendingPathComponent("Readable.rtfd", isDirectory: true)
        try wrapper.write(to: documentURL, options: .atomic, originalContentsURL: nil)
        let parsed = try NSAttributedString(
            url: documentURL,
            options: [.documentType: NSAttributedString.DocumentType.rtfd],
            documentAttributes: nil)
        var parsedImageBytes: Data?
        parsed.enumerateAttribute(
            .attachment, in: NSRange(location: 0, length: parsed.length)
        ) { value, _, stop in
            parsedImageBytes = (value as? NSTextAttachment)?.fileWrapper?.regularFileContents
            if parsedImageBytes != nil { stop.pointee = true }
        }
        XCTAssertNotNil(parsedImageBytes, "a system RTFD reader must find the image")
        XCTAssertNotNil(parsedImageBytes.flatMap(UIImage.init(data:)))
    }

    func testRTFRendersEveryBlockKind() {
        let text = rtf([
            block(.heading, "Heading"),
            block(.paragraph, "Body."),
            block(.quote, "Quoted."),
            block(.listItem, "Bulleted"),
            block(.tableOfContents, "Contents entry"),
            block(.caption, "Credit line"),
        ])
        for expected in [
            "Heading", "Body.", "Quoted.", "Bulleted", "Contents entry", "Credit line",
        ] {
            XCTAssertTrue(text.contains(expected), "missing \(expected)")
        }
        // Bullets are an explicit character + tab, not a reader-specific list table.
        XCTAssertTrue(text.contains("\\u8226 ?\\tab"), text)
    }

    // MARK: - Format descriptors

    func testFormatExtensionsAreDistinct() {
        let extensions = ArticleExportFormat.allCases.map(\.fileExtension)
        XCTAssertEqual(extensions, ["epub", "pdf", "md", "txt", "rtfd"])
        XCTAssertEqual(Set(extensions).count, extensions.count)
    }

    /// The share menu is a SUBSET of the serializers: `.richText` is built only
    /// for a double save (claudedocs/double-save.md) and must never appear in
    /// "Export as…".
    func testShareMenuOmitsTheDoubleSaveOnlyFormat() {
        XCTAssertEqual(
            ArticleExportFormat.shareMenuFormats, [.epub, .pdf, .markdown, .plainText])
        XCTAssertFalse(ArticleExportFormat.shareMenuFormats.contains(.richText))
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
