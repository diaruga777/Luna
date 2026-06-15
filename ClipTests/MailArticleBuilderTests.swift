//
//  MailArticleBuilderTests.swift
//  ClipTests
//

import XCTest
@testable import Clip

final class MailArticleBuilderTests: XCTestCase {

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
}
