//
//  GmailIMAPClientTests.swift
//  ClipTests
//

import XCTest
@testable import Clip

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

/// Mock IMAP client for importer tests.
private final class MockIMAPClient: IMAPFetching {
    var outcome: IMAPFetchOutcome
    private(set) var lastAfterUID: Int?
    init(outcome: IMAPFetchOutcome) { self.outcome = outcome }
    func fetchNewMessages(
        account: String, password: String, senders: [String],
        afterUID: Int, knownUIDValidity: Int?
    ) async throws -> IMAPFetchOutcome {
        lastAfterUID = afterUID
        return outcome
    }
}

final class IncomingMailImporterTests: XCTestCase {

    private var scratch: URL!
    private var store: ReadingListStore!
    private var credentials: InMemorySendCredentialsStore!
    private var ingested: [String] = []

    override func setUp() {
        super.setUp()
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("MailImporter-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        store = ReadingListStore(containerURL: scratch)
        credentials = InMemorySendCredentialsStore()
        credentials.setSMTPPassword("app-password")
        ingested = []
        KindleSendSettings.smtpUsername = "me@gmail.com"
        IncomingMailSettings.isEnabled = true
        IncomingMailSettings.allowedSenders = ["sender@example.com"]
        IncomingMailSettings.lastUID = 5
        IncomingMailSettings.uidValidity = 1
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: scratch)
        IncomingMailSettings.isEnabled = false
        IncomingMailSettings.allowedSenders = []
        super.tearDown()
    }

    func testImportsFirstURLOfEachMessageAndAdvancesCursor() async {
        let message = IncomingMessage(
            uid: 9, from: "sender@example.com", subject: "Hi",
            body: "link: https://example.com/x", urls: [URL(string: "https://example.com/x")!])
        let client = MockIMAPClient(outcome: IMAPFetchOutcome(
            uidValidity: 1, highestUID: 9, messages: [message]))
        let importer = IncomingMailImporter(
            makeClient: { client }, credentials: credentials, store: store,
            ingest: { [weak self] item in self?.ingested.append(item.urlString) })

        await importer.importNewMail()

        XCTAssertEqual(store.item(forURLString: "https://example.com/x")?.urlString,
                       "https://example.com/x")
        XCTAssertEqual(ingested, ["https://example.com/x"])
        XCTAssertEqual(IncomingMailSettings.lastUID, 9)
        XCTAssertEqual(client.lastAfterUID, 5)
    }

    func testSkipsWhenDisabled() async {
        IncomingMailSettings.isEnabled = false
        let client = MockIMAPClient(outcome: IMAPFetchOutcome(
            uidValidity: 1, highestUID: 9, messages: []))
        let importer = IncomingMailImporter(
            makeClient: { client }, credentials: credentials, store: store,
            ingest: { _ in })
        await importer.importNewMail()
        XCTAssertNil(client.lastAfterUID, "must not connect when disabled")
    }
}
