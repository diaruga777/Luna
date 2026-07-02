//
//  GmailIMAPClientTests.swift
//  LunaTests
//

import LunaReadingList
import LunaMail
import LunaSend
import LunaStorage
import XCTest
@testable import Luna

final class GmailIMAPClientTests: XCTestCase {

    func testTrailingLiteralCount() {
        XCTAssertEqual(GmailIMAPClient.trailingLiteralCount("* 1 FETCH (BODY[TEXT] {142}"), 142)
        XCTAssertNil(GmailIMAPClient.trailingLiteralCount("a1 OK FETCH completed"))
        XCTAssertNil(GmailIMAPClient.trailingLiteralCount("no braces here"))
    }

    func testParseBracketValue() {
        let lines = ["* OK [UIDVALIDITY 12345] UIDs valid", "* OK [UIDNEXT 98765] next"]
        XCTAssertEqual(GmailIMAPClient.parseBracketValue("UIDVALIDITY", in: lines), 12345)
        XCTAssertEqual(GmailIMAPClient.parseBracketValue("UIDNEXT", in: lines), 98765)
        XCTAssertNil(GmailIMAPClient.parseBracketValue("HIGHESTMODSEQ", in: lines))
    }

    func testParseSearchUIDs() {
        XCTAssertEqual(
            GmailIMAPClient.parseSearchUIDs(["* SEARCH 90123 90150 90187", "a3 OK"]),
            [90123, 90150, 90187])
        XCTAssertEqual(GmailIMAPClient.parseSearchUIDs(["* SEARCH", "a3 OK"]), [])
    }

    func testNewSearchUIDsFiltersStaleHighestUID() {
        // `UID SEARCH UID N:*` returns the highest UID even when it's <= afterUID
        // (the cause of the re-import loop): it must be filtered out.
        XCTAssertEqual(
            GmailIMAPClient.newSearchUIDs(["* SEARCH 59964", "a3 OK"], afterUID: 59964), [])
        XCTAssertEqual(
            GmailIMAPClient.newSearchUIDs(["* SEARCH 59964 59970", "a3 OK"], afterUID: 59964),
            [59970])
    }

    func testParseHeaders() {
        let raw = "From: Alice <a@b.com>\r\nSubject: Read this\r\nDate: Mon, 16 Jun 2026 10:00:00 -0700\r\n"
        let headers = GmailIMAPClient.parseHeaders(raw)
        XCTAssertEqual(headers["from"], "Alice <a@b.com>")
        XCTAssertEqual(headers["subject"], "Read this")
        XCTAssertEqual(headers["date"], "Mon, 16 Jun 2026 10:00:00 -0700")
    }

    func testExtractURLsFromPlainText() {
        let body = "Check this out: https://example.com/article and https://example.com/article again"
        let urls = GmailIMAPClient.extractURLs(from: body)
        XCTAssertEqual(urls.map(\.absoluteString), ["https://example.com/article"]) // deduped
    }

    func testExtractURLsFromHTMLHref() {
        let body = "<a href=\"https://news.example.com/story\">Read</a>"
        let urls = GmailIMAPClient.extractURLs(from: body)
        XCTAssertTrue(urls.map(\.absoluteString).contains("https://news.example.com/story"))
    }

    func testExtractURLsUnwrapsQuotedPrintableSoftBreak() {
        // A long URL split across lines by a QP soft break must rejoin.
        let body = "Read this: https://example.com/very/long/=\r\npath/article\r\n"
        let urls = GmailIMAPClient.extractURLs(from: body)
        XCTAssertEqual(urls.map(\.absoluteString), ["https://example.com/very/long/path/article"])
    }

    func testExtractURLsDecodesQuotedPrintableHref() {
        // QP-encoded HTML: href=3D"..." with =3F/=3D inside the URL.
        let body = "<a href=3D\"https://news.example.com/story=3Fid=3D5\">x</a>=\r\n"
        let urls = GmailIMAPClient.extractURLs(from: body)
        XCTAssertTrue(urls.map(\.absoluteString).contains("https://news.example.com/story?id=5"))
    }

    func testQuotedEscapesSpecials() {
        XCTAssertEqual(GmailIMAPClient.quoted("a@b.com"), "\"a@b.com\"")
        XCTAssertEqual(GmailIMAPClient.quoted("a\"b"), "\"a\\\"b\"")
    }
}
