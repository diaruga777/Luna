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
            body: "Para one.\n\nPara two.\n\nUnsubscribe", urls: [])
        let content = MailArticleBuilder.article(from: message)
        XCTAssertEqual(content?.title, "Weekly")
        XCTAssertEqual(content?.author, "Author")
        XCTAssertEqual(content?.blocks.count, 2)
    }

    func testArticleNilForEmptyBody() {
        let message = IncomingMessage(
            uid: 1, from: "a@b.com", subject: "Empty", date: "", body: "   \n\n  ", urls: [])
        XCTAssertNil(MailArticleBuilder.article(from: message))
    }
}
