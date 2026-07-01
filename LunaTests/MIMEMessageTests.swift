//
//  MIMEMessageTests.swift
//  LunaTests
//

import LunaEpub
import XCTest
@testable import Luna

final class MIMEMessageTests: XCTestCase {

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
}
