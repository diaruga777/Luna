//
//  DocumentParserTests.swift
//  LunaTests
//

import LunaModels
import LunaDocuments
import LunaSaves
import LunaStorage
import PDFKit
import UIKit
import XCTest
@testable import Luna

final class DocumentParserTests: XCTestCase {

    func testPlainTextSplitsParagraphsOnBlankLines() {
        let text = "First paragraph\nwith a wrapped line.\n\nSecond paragraph.\n\n\nThird."
        let blocks = PlainTextParser.blocks(from: text)
        XCTAssertEqual(blocks.count, 3)
        XCTAssertEqual(blocks[0].text, "First paragraph with a wrapped line.")
        XCTAssertEqual(blocks[1].text, "Second paragraph.")
        XCTAssertEqual(blocks[2].text, "Third.")
        XCTAssertTrue(blocks.allSatisfy { $0.kind == .paragraph })
    }

    func testPlainTextHandlesCRLF() {
        let blocks = PlainTextParser.blocks(from: "A\r\n\r\nB")
        XCTAssertEqual(blocks.map(\.text), ["A", "B"])
    }

    func testMarkdownHeadingsQuotesListsParagraphs() {
        let markdown = """
        # Title

        ## Subtitle
        A paragraph of text
        continuing here.

        > a quote

        - first
        - second
        1. ordered

        Final paragraph.
        """
        let blocks = MarkdownParser.blocks(from: markdown)
        XCTAssertEqual(blocks[0].kind, .heading)
        XCTAssertEqual(blocks[0].text, "Title")
        XCTAssertEqual(blocks[1].kind, .heading)
        XCTAssertEqual(blocks[1].text, "Subtitle")
        XCTAssertEqual(blocks[2].kind, .paragraph)
        XCTAssertEqual(blocks[2].text, "A paragraph of text continuing here.")
        XCTAssertEqual(blocks[3].kind, .quote)
        XCTAssertEqual(blocks[3].text, "a quote")
        XCTAssertEqual(blocks[4].kind, .listItem)
        XCTAssertEqual(blocks[4].text, "first")
        XCTAssertEqual(blocks[5].kind, .listItem)
        XCTAssertEqual(blocks[6].kind, .listItem)
        XCTAssertEqual(blocks[6].text, "ordered")
        XCTAssertEqual(blocks.last?.kind, .paragraph)
        XCTAssertEqual(blocks.last?.text, "Final paragraph.")
    }

    func testMarkdownHashWithoutSpaceIsNotHeading() {
        let blocks = MarkdownParser.blocks(from: "#hashtag not a heading")
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].kind, .paragraph)
    }

    func testParseTxtFileRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("note.txt")
        try "Hello world.\n\nSecond.".write(to: file, atomically: true, encoding: .utf8)

        let content = DocumentParser.parse(fileURL: file, type: "txt", title: "note")
        XCTAssertEqual(content?.title, "note")
        XCTAssertEqual(content?.blocks.count, 2)
        XCTAssertEqual(content?.blocks.first?.text, "Hello world.")
    }

    func testParseEmptyFileReturnsNil() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("empty.txt")
        try "   \n\n  ".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertNil(DocumentParser.parse(fileURL: file, type: "txt", title: "empty"))
    }

    @MainActor
    func testReaderImportsSharedPDFWithSelectableAndScannedPages() async throws {
        await AppLaunchServices.shared.waitUntilReady()
        let previousPolicy = URLBehaviorPolicy.pluginsOnly
        URLBehaviorPolicy.pluginsOnly = true
        defer { URLBehaviorPolicy.pluginsOnly = previousPolicy }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let source = directory.appendingPathComponent("Reading notes.tmp")
        let page = CGRect(x: 0, y: 0, width: 612, height: 792)
        let textAttributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 24), .foregroundColor: UIColor.black
        ]
        let typedText = "The first page has selectable text."
        let scannedText = "The second page is a scanned document."
        let scan = UIGraphicsImageRenderer(size: page.size).image { context in
            UIColor.white.setFill()
            context.fill(page)
            scannedText.draw(at: CGPoint(x: 44, y: 80), withAttributes: textAttributes)
        }
        try UIGraphicsPDFRenderer(bounds: page).writePDF(to: source) { context in
            context.beginPage()
            typedText.draw(at: CGPoint(x: 44, y: 80), withAttributes: textAttributes)
            context.beginPage()
            scan.draw(in: page)
        }
        let pdf = try XCTUnwrap(PDFDocument(url: source))
        XCTAssertTrue(pdf.page(at: 0)?.string?.contains(typedText) == true)
        XCTAssertTrue(pdf.page(at: 1)?.string?.isEmpty ?? true)

        let store = SavesStore(containerURL: directory)
        let item = try XCTUnwrap(store.addImportedDocument(sourceURL: source, type: "pdf"))
        XCTAssertEqual(item.title, "Reading notes")
        let original = try XCTUnwrap(store.originalDocumentURL(for: item))
        XCTAssertEqual(original.pathExtension, "pdf")

        // Exercise the same row a previous version left behind after treating
        // its lunadoc URL as a web link.
        store.markFailed(item.id)
        let failed = try XCTUnwrap(store.item(withID: item.id))
        await SavesIngestor(store: store).ingest(failed, allowsInteractivePrompt: false)
        let recovered = try XCTUnwrap(store.item(withID: item.id))
        XCTAssertEqual(recovered.state, .ready)
        XCTAssertEqual(store.content(for: recovered)?.blocks.map(\.text), [typedText, scannedText])
        XCTAssertEqual(store.originalDocumentURL(for: recovered), original)
    }

}
