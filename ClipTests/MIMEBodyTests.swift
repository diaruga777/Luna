//
//  MIMEBodyTests.swift
//  ClipTests
//

import ClipMail
import XCTest
@testable import Clip

final class MIMEBodyTests: XCTestCase {

    func testBoundaryParsingQuotedAndBare() {
        XCTAssertEqual(
            MIMEBody.boundary(in: "multipart/alternative; boundary=\"abc123\""), "abc123")
        XCTAssertEqual(
            MIMEBody.boundary(in: "multipart/mixed; boundary=xyz; charset=utf-8"), "xyz")
        XCTAssertNil(MIMEBody.boundary(in: "text/plain; charset=utf-8"))
    }

    func testDecodeBase64() {
        let encoded = Data("hello world".utf8).base64EncodedString()
        XCTAssertEqual(MIMEBody.decode(encoded, transferEncoding: "base64"), "hello world")
    }

    func testDecodeQuotedPrintable() {
        XCTAssertEqual(MIMEBody.decode("a=3Db", transferEncoding: "quoted-printable"), "a=b")
    }

    func testExtractPrefersHTMLPart() {
        let html = "<html><body><p>Rich content</p></body></html>"
        let body = """
        --B
        Content-Type: text/plain

        plain text
        --B
        Content-Type: text/html
        Content-Transfer-Encoding: base64

        \(Data(html.utf8).base64EncodedString())
        --B--
        """.replacingOccurrences(of: "\n", with: "\r\n")
        let result = MIMEBody.extract(
            rawBody: body, contentType: "multipart/alternative; boundary=B", transferEncoding: "7bit")
        XCTAssertTrue(result.isHTML)
        XCTAssertTrue(result.text.contains("Rich content"))
    }

    func testExtractFallsBackToPlainWhenNoHTML() {
        let body = """
        --B
        Content-Type: text/plain

        only plain here
        --B--
        """.replacingOccurrences(of: "\n", with: "\r\n")
        let result = MIMEBody.extract(
            rawBody: body, contentType: "multipart/alternative; boundary=B", transferEncoding: "7bit")
        XCTAssertFalse(result.isHTML)
        XCTAssertTrue(result.text.contains("only plain here"))
    }

    func testExtractSinglePartDecodesByEncoding() {
        let result = MIMEBody.extract(
            rawBody: "line=20one", contentType: "text/plain", transferEncoding: "quoted-printable")
        XCTAssertFalse(result.isHTML)
        XCTAssertEqual(result.text, "line one")
    }

    func testExtractNestedMultipart() {
        // multipart/mixed wrapping a multipart/alternative (common with
        // attachments): the HTML part is two levels deep.
        let html = "<html><body><div>Nested HTML body</div></body></html>"
        let inner = """
        --INNER
        Content-Type: text/plain

        nested plain
        --INNER
        Content-Type: text/html
        Content-Transfer-Encoding: base64

        \(Data(html.utf8).base64EncodedString())
        --INNER--
        """
        let body = """
        --OUTER
        Content-Type: multipart/alternative; boundary="INNER"

        \(inner)
        --OUTER--
        """.replacingOccurrences(of: "\n", with: "\r\n")
        let result = MIMEBody.extract(
            rawBody: body, contentType: "multipart/mixed; boundary=OUTER", transferEncoding: "7bit")
        XCTAssertTrue(result.isHTML)
        XCTAssertTrue(result.text.contains("Nested HTML body"))
    }
}

final class IncomingMailSettingsTests: XCTestCase {

    override func setUp() {
        super.setUp()
        IncomingMailSettings.subjectFilters = []
    }

    override func tearDown() {
        IncomingMailSettings.subjectFilters = []
        super.tearDown()
    }

    func testAddSubjectFilterTrimsAndDedupesCaseInsensitively() {
        IncomingMailSettings.addSubjectFilter("  Money Stuff  ")
        IncomingMailSettings.addSubjectFilter("money stuff") // dup (case-insensitive)
        IncomingMailSettings.addSubjectFilter("") // ignored
        XCTAssertEqual(IncomingMailSettings.subjectFilters, ["Money Stuff"])
    }

    func testRemoveSubjectFilter() {
        IncomingMailSettings.addSubjectFilter("A")
        IncomingMailSettings.addSubjectFilter("B")
        IncomingMailSettings.removeSubjectFilter(at: 0)
        XCTAssertEqual(IncomingMailSettings.subjectFilters, ["B"])
        IncomingMailSettings.removeSubjectFilter(at: 5) // out of range, no crash
        XCTAssertEqual(IncomingMailSettings.subjectFilters, ["B"])
    }
}
