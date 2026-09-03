//
//  DocumentExporterTests.swift
//  LunaTests
//

import PDFKit
import XCTest
@testable import LunaWriterLibraryUI
import LunaWriterModels

final class DocumentExporterTests: XCTestCase {

    private let markdown = "# Heading\n\nSome **bold** and *italic* text with a [link](https://example.com)."

    func testPlainTextStripsMarkupButKeepsTheWords() {
        let plain = DocumentExporter.plainText(from: markdown)
        XCTAssertFalse(plain.contains("#"))
        XCTAssertFalse(plain.contains("**"))
        XCTAssertFalse(plain.contains("["))
        XCTAssertTrue(plain.contains("Heading"))
        XCTAssertTrue(plain.contains("bold"))
        XCTAssertTrue(plain.contains("italic"))
        XCTAssertTrue(plain.contains("link"))
    }

    func testHTMLRendersTheHeadingAsARealElement() {
        let html = DocumentExporter.html(from: markdown, title: "My Sheet")
        XCTAssertTrue(html.contains("<h1"))
        XCTAssertTrue(html.contains("Heading"))
        XCTAssertTrue(html.contains("<strong>bold</strong>") || html.contains("<b>bold</b>"))
    }

    func testMarkdownExportIsThePlainSourceUnmodified() {
        let data = DocumentExporter.data(for: markdown, title: "My Sheet", format: .markdown)
        XCTAssertEqual(String(data: data, encoding: .utf8), markdown)
    }

    @MainActor
    func testPDFExportProducesAtLeastOnePage() {
        let html = DocumentExporter.html(from: markdown, title: "My Sheet")
        let data = DocumentExporter.pdfData(fromHTML: html)
        XCTAssertFalse(data.isEmpty)
        let document = PDFDocument(data: data)
        XCTAssertNotNil(document)
        XCTAssertGreaterThanOrEqual(document?.pageCount ?? 0, 1)
    }

    func testPlainTextKeepsBlankLinesBetweenParagraphs() {
        let plain = DocumentExporter.plainText(from: "First paragraph.\n\nSecond paragraph.")
        let lines = plain.components(separatedBy: "\n")
        XCTAssertEqual(lines, ["First paragraph.", "", "Second paragraph."])
    }
}
