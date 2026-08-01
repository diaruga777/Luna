//
//  ArticleDocumentBuilderTests.swift
//  LunaTests
//

import LunaModels
import LunaSend
import UIKit
import XCTest

/// The Markdown / plain-text / PDF / RTF serializers behind the "Export as…"
/// formats and the double-save "Open …" actions.
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

    /// Writes a real 2x2 PNG into the scratch images directory and returns an
    /// image block pointing at it.
    private func imageBlock(alt: String, fileName: String = "pic.png",
                            remote: String? = "https://example.com/pic.png") -> ArticleContent.Block {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }
        try? image.pngData()?.write(to: scratch.appendingPathComponent(fileName))
        return ArticleContent.Block(
            kind: .image, text: alt, links: [],
            imageURLString: remote, imageFileName: fileName)
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

    /// Images are embedded from the downloaded file; a block whose file is missing
    /// must be skipped rather than fail the export.
    func testPDFEmbedsDownloadedImageAndSkipsMissingOne() throws {
        let present = ArticlePDFBuilder().build(
            content: content([imageBlock(alt: "A photo")]),
            sourceURLString: "", imagesDirectory: scratch)
        let missing = ArticlePDFBuilder().build(
            content: content([ArticleContent.Block(
                kind: .image, text: "A photo", links: [], imageFileName: "gone.png")]),
            sourceURLString: "", imagesDirectory: scratch)

        XCTAssertEqual(String(decoding: missing.prefix(4), as: UTF8.self), "%PDF")
        XCTAssertGreaterThan(present.count, missing.count)
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

    // MARK: - Rich Text (RTF)

    private func rtf(_ blocks: [ArticleContent.Block],
                     sourceURLString: String = "https://example.com/a") -> String {
        let data = ArticleRTFBuilder().build(
            content: content(blocks), sourceURLString: sourceURLString,
            imagesDirectory: scratch)
        return String(data: data, encoding: .ascii) ?? ""
    }

    func testRTFIsAWellFormedAsciiDocument() {
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

    func testRTFEmbedsDownloadedImageAndPlaceholdersAMissingOne() {
        let embedded = rtf([imageBlock(alt: "A chart")])
        XCTAssertTrue(embedded.contains("{\\pict\\pngblip"), String(embedded.prefix(400)))
        XCTAssertTrue(embedded.contains("picwgoal"), embedded)

        let missing = rtf([ArticleContent.Block(
            kind: .image, text: "A chart", links: [],
            imageURLString: "https://example.com/gone.png", imageFileName: nil)])
        XCTAssertFalse(missing.contains("\\pict"), missing)
        XCTAssertTrue(missing.contains("[A chart]"), missing)
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
        XCTAssertEqual(extensions, ["epub", "pdf", "md", "txt", "rtf"])
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
