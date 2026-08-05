//
//  MailTests.swift
//  LunaTests
//
//  Merged from MIMEBodyTests, MIMEMessageTests, MailArticleBuilderTests,
//  GmailIMAPClientTests, and IncomingMailImporterTests.
//

import LunaMail
import LunaEpub
import LunaMailAccount
import LunaSend
import LunaSocial
import LunaStorage
import XCTest
@testable import Luna
@testable import LunaReadingList

final class MailTests: XCTestCase {

    override func setUp() {
        super.setUp()
        IncomingMailSettings.subjectFilters = []
    }

    override func tearDown() {
        IncomingMailSettings.subjectFilters = []
        super.tearDown()
    }

    // MARK: - MIMEBody

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

    // MARK: - IncomingMailSettings (subject filters)

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

    // MARK: - MIMEMessage

    private func sampleMessage(subject: String = "Hello") -> MIMEMessage {
        MIMEMessage(
            from: "me@example.com",
            to: "you@kindle.com",
            subject: subject,
            bodyText: "Body.",
            attachmentFileName: "Article.epub",
            attachmentMimeType: "application/epub+zip",
            attachmentData: Data((0..<300).map { UInt8($0 % 256) }))
    }

    func testHeadersAndStructure() {
        let text = String(decoding: sampleMessage().messageData(), as: UTF8.self)

        XCTAssertTrue(text.contains("From: <me@example.com>\r\n"))
        XCTAssertTrue(text.contains("To: <you@kindle.com>\r\n"))
        XCTAssertTrue(text.contains("Subject: Hello\r\n"))
        XCTAssertTrue(text.contains("MIME-Version: 1.0\r\n"))
        XCTAssertTrue(text.contains("Content-Type: multipart/mixed; boundary=\""))
        XCTAssertTrue(text.contains("Content-Type: application/epub+zip; name=\"Article.epub\""))
        XCTAssertTrue(text.contains("Content-Disposition: attachment; filename=\"Article.epub\""))

        // The boundary appears twice as a part opener and once as the closer.
        let boundary = text.components(separatedBy: "boundary=\"")[1]
            .components(separatedBy: "\"")[0]
        XCTAssertEqual(text.components(separatedBy: "--\(boundary)\r\n").count - 1, 2)
        XCTAssertTrue(text.hasSuffix("--\(boundary)--\r\n"))
    }

    func testAttachmentRoundTripsThroughBase64() {
        let message = sampleMessage()
        let text = String(decoding: message.messageData(), as: UTF8.self)
        let base64Section = text
            .components(separatedBy: "Content-Transfer-Encoding: base64\r\n\r\n")[1]
            .components(separatedBy: "\r\n--")[0]

        // Lines wrapped at 76 columns, and the payload survives decoding.
        let lines = base64Section.components(separatedBy: "\r\n").filter { !$0.isEmpty }
        XCTAssertTrue(lines.allSatisfy { $0.count <= 76 })
        let decoded = Data(base64Encoded: lines.joined())
        XCTAssertEqual(decoded, message.attachmentData)
    }

    func testNonASCIISubjectIsRFC2047Encoded() {
        let text = String(
            decoding: sampleMessage(subject: "Caffè ☕ news").messageData(), as: UTF8.self)
        XCTAssertTrue(text.contains("Subject: =?UTF-8?B?"))
        XCTAssertFalse(text.contains("Subject: Caffè"))
    }

    // MARK: - MailArticleBuilder

    func testSenderNameFromDisplayName() {
        XCTAssertEqual(MailArticleBuilder.senderName(from: "Daily News <news@x.com>"), "Daily News")
    }

    func testSenderNameFromBareAddress() {
        XCTAssertEqual(MailArticleBuilder.senderName(from: "news@example.com"), "news")
    }

    func testSenderNameFromAddressOnlyAngle() {
        XCTAssertEqual(MailArticleBuilder.senderName(from: "<news@example.com>"), "news")
    }

    func testLooksLikeHTML() {
        XCTAssertTrue(MailArticleBuilder.looksLikeHTML("<div>hi</div>"))
        XCTAssertTrue(MailArticleBuilder.looksLikeHTML("<P>hi</P>"))
        XCTAssertFalse(MailArticleBuilder.looksLikeHTML("just plain text"))
    }

    func testParagraphBlocksTrimsFooter() {
        let blocks = MailArticleBuilder.paragraphBlocks(
            from: "Body line one.\n\nBody line two.\n\nUnsubscribe | View in browser")
        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(blocks.first?.text, "Body line one.")
    }

    func testDecodeEncodedWordsBase64() {
        // "=?UTF-8?B?SGVsbG8=?=" → "Hello"
        XCTAssertEqual(MailArticleBuilder.decodeEncodedWords("=?UTF-8?B?SGVsbG8=?="), "Hello")
    }

    func testDecodeEncodedWordsQ() {
        // Q-encoding: underscore = space, =XX hex.
        XCTAssertEqual(MailArticleBuilder.decodeEncodedWords("=?UTF-8?Q?Hi_there?="), "Hi there")
    }

    func testArticleFromPlainTextEmail() {
        let message = IncomingMessage(
            uid: 1, from: "Author <a@b.com>", subject: "Weekly", date: "",
            contentType: "text/plain", transferEncoding: "7bit",
            body: "Para one.\n\nPara two.\n\nUnsubscribe", urls: [])
        let content = MailArticleBuilder.article(from: message)
        XCTAssertEqual(content?.title, "Weekly")
        XCTAssertEqual(content?.author, "Author")
        XCTAssertEqual(content?.blocks.count, 2)
    }

    func testArticleNilForEmptyBody() {
        let message = IncomingMessage(
            uid: 1, from: "a@b.com", subject: "Empty", date: "",
            contentType: "text/plain", transferEncoding: "7bit", body: "   \n\n  ", urls: [])
        XCTAssertNil(MailArticleBuilder.article(from: message))
    }

    func testArticleFromMultipartBase64HTML() {
        // A realistic newsletter: multipart/alternative with a base64 text/html
        // part. The raw BODY[TEXT] is unreadable until the part is walked +
        // base64-decoded.
        let html = "<html><body><p>The market will get more stock.</p>"
            + "<p>Second paragraph here.</p></body></html>"
        let base64 = Data(html.utf8).base64EncodedString()
        let body = """
        --BOUNDARY
        Content-Type: text/plain; charset="utf-8"
        Content-Transfer-Encoding: 7bit

        plain fallback
        --BOUNDARY
        Content-Type: text/html; charset="utf-8"
        Content-Transfer-Encoding: base64

        \(base64)
        --BOUNDARY--
        """.replacingOccurrences(of: "\n", with: "\r\n")
        let message = IncomingMessage(
            uid: 2, from: "Matt Levine <noreply@news.bloomberg.com>",
            subject: "Money Stuff: The Stock Market", date: "",
            contentType: "multipart/alternative; boundary=\"BOUNDARY\"", transferEncoding: "7bit",
            body: body, urls: [])
        let content = MailArticleBuilder.article(from: message)
        XCTAssertEqual(content?.title, "Money Stuff: The Stock Market")
        XCTAssertEqual(content?.blocks.count, 2, "HTML part decoded, not the plain fallback")
        XCTAssertEqual(content?.blocks.first?.text, "The market will get more stock.")
    }

    // MARK: - GmailIMAPClient

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

    // MARK: - IncomingMailImporter

    func testIsLunaShareSubjectTrueForPrefix() {
        XCTAssertTrue(IncomingMailImporter.isLunaShareSubject(
            "\(FilterGuide.subjectPrefix)A Great Article"))
    }

    func testIsLunaShareSubjectFalseForOldReadablePrefix() {
        XCTAssertFalse(IncomingMailImporter.isLunaShareSubject("From Luna: A Great Article"))
    }

    func testIsLunaShareSubjectFalseForOrdinaryNewsletter() {
        XCTAssertFalse(IncomingMailImporter.isLunaShareSubject("Money Stuff: The Stock Market"))
    }

    func testIsLunaShareSubjectDecodesEncodedWordsFirst() {
        // "=?UTF-8?B?dmlhIEx14oCMbmE6IEhlbGxv?=" -> "via Lu\u{200C}na: Hello"
        XCTAssertTrue(IncomingMailImporter.isLunaShareSubject("=?UTF-8?B?dmlhIEx14oCMbmE6IEhlbGxv?="))
    }

    func testTitleStrippingLunaPrefixRemovesPrefixAndTrims() {
        XCTAssertEqual(
            IncomingMailImporter.titleStrippingLunaPrefix(
                "\(FilterGuide.subjectPrefix)A Great Article"),
            "A Great Article")
    }

    func testTitleStrippingLunaPrefixLeavesNonLunaSubjectUnchanged() {
        XCTAssertEqual(
            IncomingMailImporter.titleStrippingLunaPrefix("Money Stuff: The Stock Market"),
            "Money Stuff: The Stock Market")
    }

    func testTitleStrippingLunaPrefixHandlesURLFallbackTitle() {
        // EmailContentRenderer.subject falls back to the URL when the share
        // has no title — the stripped title should just be the bare URL.
        XCTAssertEqual(
            IncomingMailImporter.titleStrippingLunaPrefix(
                "\(FilterGuide.subjectPrefix)https://example.com/article"),
            "https://example.com/article")
    }

    func testSameAddressIsCaseAndWhitespaceInsensitive() {
        XCTAssertTrue(IncomingMailImporter.sameAddress(
            " Sender@Example.com ", "sender@example.com"))
        XCTAssertFalse(IncomingMailImporter.sameAddress(
            "sender@example.com", "other@example.com"))
        XCTAssertFalse(IncomingMailImporter.sameAddress("sender@example.com", nil))
    }
}
