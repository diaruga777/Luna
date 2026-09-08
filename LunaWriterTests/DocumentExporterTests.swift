//
//  DocumentExporterTests.swift
//  LunaWriterTests
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

    /// organiser #37: the raw title was used as a path component, so a title
    /// carrying "/" or ":" failed the write silently.
    func testSanitizedFilenameReplacesPathAndControlCharacters() {
        XCTAssertEqual(DocumentExporter.sanitizedFilename(from: "Notes: Q3/Q4 Plan"), "Notes- Q3-Q4 Plan")
    }

    func testSanitizedFilenameFallsBackToUntitledWithNothingUsable() {
        XCTAssertEqual(DocumentExporter.sanitizedFilename(from: ""), "Untitled")
        XCTAssertEqual(DocumentExporter.sanitizedFilename(from: "   "), "Untitled")
    }

    /// A single path separator becomes a dash rather than vanishing, so the
    /// result is still a recognisable stand-in for the title rather than
    /// silently falling all the way back to "Untitled".
    func testSanitizedFilenameReplacesALoneSeparatorWithADash() {
        XCTAssertEqual(DocumentExporter.sanitizedFilename(from: "/"), "-")
    }

    func testSanitizedFilenameLeavesAnOrdinaryTitleAlone() {
        XCTAssertEqual(DocumentExporter.sanitizedFilename(from: "My Sheet"), "My Sheet")
    }

    /// organiser #38: a printed page (including the PDF export, which prints
    /// through `UIMarkupTextPrintFormatter`) should use paper colours, not
    /// the night background the screen shows.
    func testHTMLCarriesAPrintMediaQueryWithPaperColours() {
        let html = DocumentExporter.html(from: markdown, title: "My Sheet")
        XCTAssertTrue(html.contains("@media print"))
        XCTAssertTrue(html.contains("#ffffff"))
    }
}
