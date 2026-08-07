//
//  EbookDocumentImportTests.swift
//  LunaTests
//

import LunaDocuments
import LunaModels
import LunaShareSurface
import UniformTypeIdentifiers
import XCTest

/// Importing the container formats — EPUB and `.docx` — plus the markup
/// extractor they share with the `.html` import.
///
/// The fixtures are built with `ZipArchiveWriter`, the same writer that produces
/// the books Luna EXPORTS: the round trip is the point, and a hand-carved byte
/// blob would only test this file's idea of a zip.
final class EbookDocumentImportTests: XCTestCase {

    // MARK: - Zip

    func testTheReaderReadsBackWhatTheWriterWrote() throws {
        var zip = ZipArchiveWriter()
        zip.addEntry(path: "mimetype", data: Data("application/epub+zip".utf8))
        zip.addEntry(path: "OEBPS/chapter.xhtml", data: Data("<p>hello</p>".utf8))
        let archive = try XCTUnwrap(ZipArchiveReader(data: zip.archiveData()))

        XCTAssertEqual(archive.paths, ["mimetype", "OEBPS/chapter.xhtml"])
        XCTAssertEqual(archive.text(at: "mimetype"), "application/epub+zip")
        XCTAssertEqual(archive.text(at: "OEBPS/chapter.xhtml"), "<p>hello</p>")
        XCTAssertNil(archive.data(at: "OEBPS/missing.xhtml"))
    }

    /// A real ebook's entries are DEFLATEd, which the writer never emits — so the
    /// inflate path needs bytes from something else. `NSData`'s `.zlib`
    /// algorithm is Apple's `COMPRESSION_ZLIB`, which despite the name is RAW
    /// deflate with no header or trailer: exactly a zip entry's payload.
    func testDeflatedEntriesInflate() throws {
        let text = String(repeating: "The quick brown fox. ", count: 200)
        let raw = Data(text.utf8)
        let deflated = try XCTUnwrap((raw as NSData).compressed(using: .zlib) as Data?)
        XCTAssertLessThan(deflated.count, raw.count, "the fixture has to actually compress")

        let archive = try XCTUnwrap(ZipArchiveReader(data: deflatedArchive(
            path: "word/document.xml", deflated: deflated, uncompressedSize: raw.count)))
        XCTAssertEqual(archive.text(at: "word/document.xml"), text)
    }

    /// The writer a streaming tool uses leaves both sizes at zero in the local
    /// header AND the central directory, deferring them to a data descriptor. The
    /// reader has to inflate without being told how big the result is.
    func testADeflatedEntryOfUnknownSizeStillInflates() throws {
        let text = String(repeating: "Sized by nobody. ", count: 300)
        let deflated = try XCTUnwrap(
            (Data(text.utf8) as NSData).compressed(using: .zlib) as Data?)
        let archive = try XCTUnwrap(ZipArchiveReader(data: deflatedArchive(
            path: "chapter.xhtml", deflated: deflated, uncompressedSize: 0)))
        XCTAssertEqual(archive.text(at: "chapter.xhtml"), text)
    }

    func testGarbageIsNotAZip() {
        XCTAssertNil(ZipArchiveReader(data: Data("not a zip at all".utf8)))
        XCTAssertNil(ZipArchiveReader(data: Data()))
    }

    // MARK: - EPUB

    func testAnEpubReadsAsOneArticleWithItsOwnTitleAuthorAndChapterHeadings() throws {
        let content = try XCTUnwrap(EpubDocumentParser.parse(
            data: sampleEpub(), fallbackTitle: "pg84-images-3"))

        XCTAssertEqual(content.title, "A Book Of Two Chapters")
        XCTAssertEqual(content.author, "A Writer")
        XCTAssertEqual(
            content.blocks.map(\.kind),
            [.heading, .paragraph, .quote, .heading, .listItem, .paragraph])
        XCTAssertEqual(content.blocks[0].text, "Chapter One")
        XCTAssertEqual(content.blocks[1].text, "The first chapter opens.")
        XCTAssertEqual(content.blocks[2].text, "Quoted from elsewhere.")
        // Chapter two names itself only in its <title>, so the break is supplied.
        XCTAssertEqual(content.blocks[3].text, "Chapter Two")
    }

    /// `linear="no"` is the spine saying "reachable by link, not part of the read
    /// through" — a copyright page, an advertisement.
    func testNonLinearSpineItemsAreNotPartOfTheRead() throws {
        let content = try XCTUnwrap(EpubDocumentParser.parse(
            data: sampleEpub(), fallbackTitle: "book"))
        XCTAssertFalse(
            content.blocks.contains { $0.text.contains("All rights reserved") })
    }

    /// The OPF names its chapters relative to ITS OWN directory, percent-escaped,
    /// and may sit anywhere the container says — a book whose package is at
    /// `OEBPS/content.opf` referring to `text/one.xhtml` means
    /// `OEBPS/text/one.xhtml`, which is a different string from either.
    func testChapterHrefsResolveAgainstThePackageDirectory() throws {
        var zip = ZipArchiveWriter()
        zip.addEntry(path: "META-INF/container.xml", data: Data("""
            <container><rootfiles><rootfile full-path="OEBPS/content.opf"/></rootfiles></container>
            """.utf8))
        zip.addEntry(path: "OEBPS/content.opf", data: Data("""
            <package><metadata><dc:title>Nested</dc:title></metadata>
            <manifest><item id="c1" href="text/chapter%20one.xhtml"/>
            <item id="c2" href="../Extra/two.xhtml"/></manifest>
            <spine><itemref idref="c1"/><itemref idref="c2"/></spine></package>
            """.utf8))
        zip.addEntry(
            path: "OEBPS/text/chapter one.xhtml", data: Data("<p>Escaped name.</p>".utf8))
        zip.addEntry(path: "Extra/two.xhtml", data: Data("<p>Above the package.</p>".utf8))

        let content = try XCTUnwrap(EpubDocumentParser.parse(
            data: zip.archiveData(), fallbackTitle: "book"))
        XCTAssertEqual(content.title, "Nested")
        XCTAssertEqual(content.blocks.map(\.text), ["Escaped name.", "Above the package."])
    }

    func testABookWithNoReadableChaptersIsNotAnImport() throws {
        var zip = ZipArchiveWriter()
        zip.addEntry(path: "META-INF/container.xml", data: Data("""
            <container><rootfiles><rootfile full-path="content.opf"/></rootfiles></container>
            """.utf8))
        zip.addEntry(path: "content.opf", data: Data("""
            <package><metadata><dc:title>Empty</dc:title></metadata>
            <manifest/><spine/></package>
            """.utf8))
        XCTAssertNil(EpubDocumentParser.parse(data: zip.archiveData(), fallbackTitle: "book"))
        XCTAssertNil(EpubDocumentParser.parse(data: Data("nonsense".utf8), fallbackTitle: "book"))
    }

    // MARK: - Word

    func testAWordDocumentKeepsItsHeadingsListsAndRunSpacing() throws {
        let content = try XCTUnwrap(DocxDocumentParser.parse(
            data: sampleDocx(), fallbackTitle: "export-3"))

        XCTAssertEqual(content.title, "The Real Title")
        XCTAssertEqual(
            content.blocks.map(\.kind), [.heading, .paragraph, .listItem, .quote])
        // Two runs, the first ending in a space that `text()` would have eaten.
        XCTAssertEqual(content.blocks[1].text, "Split across two runs.")
        XCTAssertEqual(content.blocks[2].text, "A numbered point.")
    }

    /// A `.docx` with no `dc:title` still opens with one: its first heading.
    func testTheFirstHeadingNamesAnUntitledDocument() throws {
        var zip = ZipArchiveWriter()
        zip.addEntry(path: "word/document.xml", data: Data("""
            <w:document><w:body>
            <w:p><w:pPr><w:pStyle w:val="Heading1"/></w:pPr><w:r><w:t>Field Notes</w:t></w:r></w:p>
            <w:p><w:r><w:t>Body.</w:t></w:r></w:p>
            </w:body></w:document>
            """.utf8))
        let content = try XCTUnwrap(DocxDocumentParser.parse(
            data: zip.archiveData(), fallbackTitle: "untitled-2"))
        XCTAssertEqual(content.title, "Field Notes")
    }

    // MARK: - Markup

    /// The outer element wins: a `p` inside a `blockquote` matches the selector
    /// too, and emitting both prints the quote twice.
    func testNestedBlocksAreNotEmittedTwice() {
        let blocks = MarkupBlockExtractor.blocks(fromHTML: """
            <html><body><blockquote><p>Said once.</p></blockquote>
            <ul><li>One</li><li>Two</li></ul></body></html>
            """)
        XCTAssertEqual(blocks.map(\.kind), [.quote, .listItem, .listItem])
        XCTAssertEqual(blocks.map(\.text), ["Said once.", "One", "Two"])
    }

    func testScriptAndStyleAreNotProse() {
        let blocks = MarkupBlockExtractor.blocks(fromHTML: """
            <html><head><style>p { color: red }</style></head>
            <body><script>var x = 1;</script><p>Only this.</p></body></html>
            """)
        XCTAssertEqual(blocks.map(\.text), ["Only this."])
    }

    /// Badly made ebooks lay prose out in bare `div`s, which match no block
    /// selector at all. Falling through to the plain-text parser is the
    /// difference between a readable chapter and an empty one.
    func testADocumentOfBareDivsStillYieldsItsText() {
        let blocks = MarkupBlockExtractor.blocks(fromHTML:
            "<html><body><div>First thought.</div><div>Second thought.</div></body></html>")
        XCTAssertFalse(blocks.isEmpty)
        XCTAssertTrue(blocks.contains { $0.text.contains("First thought.") })
    }

    // MARK: - The two accepted-format lists

    /// `DocumentParser.readableExtensions` and the share router's
    /// `documentTypes` answer the same question for different callers — one takes
    /// a file on disk, one takes what a provider advertises. A format Luna claims
    /// to parse but the router turns away is a file the user can hand over and
    /// never see again.
    ///
    /// The escape hatch is real rather than a weakening: an extension iOS has no
    /// registered type for (`.markdown` is one, on some systems) arrives as a
    /// bare `public.file-url`, which `route` sends down the URL leg, whose
    /// `isFileURL` branch imports it as a document anyway. Both routes end at
    /// `saveDocumentDirectly`.
    func testEveryFormatWithAParserIsReachableThroughTheShareSheet() throws {
        for parsed in DocumentParser.readableExtensions {
            let type = try XCTUnwrap(
                UTType(filenameExtension: parsed), "\(parsed) resolves to no type at all")
            guard !type.isDynamic else { continue }
            // CONFORMANCE, not extension equality: `.md` is its own type that
            // conforms to `public.plain-text`, and that conformance is exactly
            // what makes the router accept it.
            XCTAssertTrue(
                ShareAttachmentRouter.documentTypes.contains { type.conforms(to: $0) },
                "\(parsed) parses but no accepted share type covers it")
        }
    }

    // MARK: - Fixtures

    private func sampleEpub() -> Data {
        var zip = ZipArchiveWriter()
        zip.addEntry(path: "mimetype", data: Data("application/epub+zip".utf8))
        zip.addEntry(path: "META-INF/container.xml", data: Data("""
            <?xml version="1.0"?>
            <container version="1.0"><rootfiles>
            <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
            </rootfiles></container>
            """.utf8))
        zip.addEntry(path: "OEBPS/content.opf", data: Data("""
            <?xml version="1.0"?>
            <package version="3.0"><metadata>
            <dc:title>A Book Of Two Chapters</dc:title><dc:creator>A Writer</dc:creator>
            </metadata>
            <manifest>
            <item id="one" href="one.xhtml" media-type="application/xhtml+xml"/>
            <item id="two" href="two.xhtml" media-type="application/xhtml+xml"/>
            <item id="rights" href="rights.xhtml" media-type="application/xhtml+xml"/>
            </manifest>
            <spine>
            <itemref idref="one"/><itemref idref="two"/>
            <itemref idref="rights" linear="no"/>
            </spine></package>
            """.utf8))
        zip.addEntry(path: "OEBPS/one.xhtml", data: Data("""
            <html><head><title>One</title></head><body>
            <h1>Chapter One</h1><p>The first chapter opens.</p>
            <blockquote>Quoted from elsewhere.</blockquote>
            </body></html>
            """.utf8))
        zip.addEntry(path: "OEBPS/two.xhtml", data: Data("""
            <html><head><title>Chapter Two</title></head><body>
            <ul><li>A list opens it.</li></ul><p>And prose follows.</p>
            </body></html>
            """.utf8))
        zip.addEntry(path: "OEBPS/rights.xhtml", data: Data(
            "<html><body><p>All rights reserved.</p></body></html>".utf8))
        return zip.archiveData()
    }

    private func sampleDocx() -> Data {
        var zip = ZipArchiveWriter()
        zip.addEntry(path: "docProps/core.xml", data: Data("""
            <?xml version="1.0"?>
            <cp:coreProperties><dc:title>The Real Title</dc:title>
            <dc:creator>A Writer</dc:creator></cp:coreProperties>
            """.utf8))
        zip.addEntry(path: "word/document.xml", data: Data("""
            <?xml version="1.0"?>
            <w:document><w:body>
            <w:p><w:pPr><w:pStyle w:val="Heading2"/></w:pPr>
              <w:r><w:t>A Section</w:t></w:r></w:p>
            <w:p><w:r><w:t xml:space="preserve">Split across </w:t></w:r>
              <w:r><w:t>two runs.</w:t></w:r></w:p>
            <w:p><w:pPr><w:numPr><w:ilvl w:val="0"/></w:numPr></w:pPr>
              <w:r><w:t>A numbered point.</w:t></w:r></w:p>
            <w:p><w:pPr><w:pStyle w:val="IntenseQuote"/></w:pPr>
              <w:r><w:t>Set apart.</w:t></w:r></w:p>
            <w:p><w:r><w:t>   </w:t></w:r></w:p>
            </w:body></w:document>
            """.utf8))
        return zip.archiveData()
    }

    /// A one-entry archive whose payload is DEFLATEd, assembled by hand because
    /// `ZipArchiveWriter` only stores.
    private func deflatedArchive(
        path: String, deflated payload: Data, uncompressedSize: Int
    ) -> Data {
        let name = Data(path.utf8)
        var archive = Data()

        func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }

        append(UInt32(0x0403_4b50), to: &archive)
        append(UInt16(20), to: &archive)
        append(UInt16(0), to: &archive)
        append(UInt16(8), to: &archive)          // deflate
        append(UInt16(0), to: &archive)
        append(UInt16(0x21), to: &archive)
        append(UInt32(0), to: &archive)          // crc (unchecked by the reader)
        append(UInt32(payload.count), to: &archive)
        append(UInt32(uncompressedSize), to: &archive)
        append(UInt16(name.count), to: &archive)
        append(UInt16(0), to: &archive)
        archive.append(name)
        archive.append(payload)

        let directoryOffset = archive.count
        append(UInt32(0x0201_4b50), to: &archive)
        append(UInt16(20), to: &archive)
        append(UInt16(20), to: &archive)
        append(UInt16(0), to: &archive)
        append(UInt16(8), to: &archive)
        append(UInt16(0), to: &archive)
        append(UInt16(0x21), to: &archive)
        append(UInt32(0), to: &archive)
        append(UInt32(payload.count), to: &archive)
        append(UInt32(uncompressedSize), to: &archive)
        append(UInt16(name.count), to: &archive)
        append(UInt16(0), to: &archive)
        append(UInt16(0), to: &archive)
        append(UInt16(0), to: &archive)
        append(UInt16(0), to: &archive)
        append(UInt32(0), to: &archive)
        append(UInt32(0), to: &archive)          // local header offset
        archive.append(name)
        let directorySize = archive.count - directoryOffset

        append(UInt32(0x0605_4b50), to: &archive)
        append(UInt16(0), to: &archive)
        append(UInt16(0), to: &archive)
        append(UInt16(1), to: &archive)
        append(UInt16(1), to: &archive)
        append(UInt32(directorySize), to: &archive)
        append(UInt32(directoryOffset), to: &archive)
        append(UInt16(0), to: &archive)
        return archive
    }
}
