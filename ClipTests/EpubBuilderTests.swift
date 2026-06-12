//
//  EpubBuilderTests.swift
//  ClipTests
//

import XCTest
@testable import Clip

final class EpubBuilderTests: XCTestCase {

    private var scratchDirectory: URL!

    override func setUp() {
        super.setUp()
        scratchDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("EpubBuilderTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratchDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: scratchDirectory)
        super.tearDown()
    }

    private func sampleContent() -> ArticleContent {
        ArticleContent(
            title: "Tom & Jerry <On Tour>",
            author: "A. Writer",
            blocks: [
                ArticleContent.Block(kind: .heading, text: "Act 1", links: []),
                ArticleContent.Block(kind: .paragraph, text: "Cats > mice & dogs.", links: []),
                ArticleContent.Block(kind: .listItem, text: "first", links: []),
                ArticleContent.Block(kind: .listItem, text: "second", links: []),
                ArticleContent.Block(kind: .quote, text: "Said someone.", links: []),
            ])
    }

    func testEpubStartsWithStoredMimetypeEntry() {
        let epub = EpubBuilder().build(
            content: sampleContent(), sourceURLString: "https://example.com/a",
            imagesDirectory: scratchDirectory)
        XCTAssertEqual(epub.prefix(4), Data([0x50, 0x4B, 0x03, 0x04]))
        XCTAssertEqual(epub.subdata(in: 30..<38), Data("mimetype".utf8))
        XCTAssertEqual(epub.subdata(in: 38..<58), Data("application/epub+zip".utf8))
    }

    func testEpubContainsPackagePiecesAndEscapedText() {
        let epub = EpubBuilder().build(
            content: sampleContent(), sourceURLString: "https://example.com/a",
            imagesDirectory: scratchDirectory)

        // Stored entries mean the XML is byte-for-byte findable in the archive.
        XCTAssertNotNil(epub.firstRange(of: Data("META-INF/container.xml".utf8)))
        XCTAssertNotNil(epub.firstRange(of: Data("OEBPS/content.opf".utf8)))
        XCTAssertNotNil(epub.firstRange(of: Data("OEBPS/nav.xhtml".utf8)))
        XCTAssertNotNil(epub.firstRange(
            of: Data("<dc:title>Tom &amp; Jerry &lt;On Tour&gt;</dc:title>".utf8)))
        XCTAssertNotNil(epub.firstRange(of: Data("<p>Cats &gt; mice &amp; dogs.</p>".utf8)))
        XCTAssertNotNil(epub.firstRange(
            of: Data("<ul>\n<li>first</li>\n<li>second</li>\n</ul>".utf8)))
        XCTAssertNotNil(epub.firstRange(of: Data("<dc:creator>A. Writer</dc:creator>".utf8)))
    }

    func testDownloadedImageIsEmbeddedAndReferenced() throws {
        let imageData = Data([0xFF, 0xD8, 0xFF, 0xE0] + Array(repeating: 0, count: 64))
        try imageData.write(to: scratchDirectory.appendingPathComponent("art-img0.jpg"))

        var content = sampleContent()
        content.blocks.append(ArticleContent.Block(
            kind: .image, text: "caption", links: [],
            imageURLString: "https://example.com/x.jpg", imageFileName: "art-img0.jpg"))

        let epub = EpubBuilder().build(
            content: content, sourceURLString: "https://example.com/a",
            imagesDirectory: scratchDirectory)

        XCTAssertNotNil(epub.firstRange(of: Data("OEBPS/images/art-img0.jpg".utf8)))
        XCTAssertNotNil(epub.firstRange(of: imageData))
        XCTAssertNotNil(epub.firstRange(of: Data("<img src=\"images/art-img0.jpg\"".utf8)))
        XCTAssertNotNil(epub.firstRange(of: Data("media-type=\"image/jpeg\"".utf8)))
    }

    func testMissingImageFileIsSkippedEntirely() {
        var content = sampleContent()
        content.blocks.append(ArticleContent.Block(
            kind: .image, text: "caption", links: [],
            imageURLString: "https://example.com/x.jpg", imageFileName: "not-on-disk.jpg"))

        let epub = EpubBuilder().build(
            content: content, sourceURLString: "https://example.com/a",
            imagesDirectory: scratchDirectory)

        XCTAssertNil(epub.firstRange(of: Data("not-on-disk.jpg".utf8)))
    }
}
