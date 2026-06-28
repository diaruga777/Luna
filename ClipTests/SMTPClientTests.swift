//
//  SMTPClientTests.swift
//  ClipTests
//

import ClipSend
import ClipEpub
import XCTest
@testable import Clip

/// A transport that replays a scripted server and records everything the
/// client sends.
private final class ScriptedTransport: SMTPTransport {
    /// Server lines to hand out, in order.
    var replies: [String]
    /// Every byte the client wrote, concatenated.
    private(set) var written = Data()
    private(set) var closed = false

    init(replies: [String]) {
        self.replies = replies
    }

    func connect() async throws {}
    func send(_ data: Data) async throws { written.append(data) }
    func readLine() async throws -> String {
        guard !replies.isEmpty else {
            throw SMTPError(step: "script exhausted", reply: "")
        }
        return replies.removeFirst()
    }
    func close() { closed = true }

    var writtenText: String { String(decoding: written, as: UTF8.self) }
}

final class SMTPClientTests: XCTestCase {

    private func sampleMessage() -> MIMEMessage {
        MIMEMessage(
            from: "me@example.com", to: "you@kindle.com", subject: "S",
            bodyText: "B", attachmentFileName: "a.epub",
            attachmentMimeType: "application/epub+zip", attachmentData: Data([1, 2, 3]))
    }

    func testHappyPathWithAuthPlain() async throws {
        let transport = ScriptedTransport(replies: [
            "220 smtp.example.com ready",
            "250-smtp.example.com",         // multiline EHLO reply
            "250-AUTH PLAIN LOGIN",
            "250 OK",
            "235 accepted",
            "250 sender ok",
            "250 recipient ok",
            "354 go ahead",
            "250 queued",
        ])
        let client = SMTPClient(transport: transport)
        try await client.submit(message: sampleMessage(), username: "me@example.com", password: "pw")

        let text = transport.writtenText
        XCTAssertTrue(text.hasPrefix("EHLO clip.local\r\n"))
        let expectedAuth = Data("\0me@example.com\0pw".utf8).base64EncodedString()
        XCTAssertTrue(text.contains("AUTH PLAIN \(expectedAuth)\r\n"))
        XCTAssertTrue(text.contains("MAIL FROM:<me@example.com>\r\n"))
        XCTAssertTrue(text.contains("RCPT TO:<you@kindle.com>\r\n"))
        XCTAssertTrue(text.contains("DATA\r\n"))
        XCTAssertTrue(text.contains("\r\n.\r\nQUIT\r\n"))
        XCTAssertTrue(transport.closed)
    }

    func testFallsBackToAuthLogin() async throws {
        let transport = ScriptedTransport(replies: [
            "220 ready",
            "250 OK",
            "504 PLAIN not supported",
            "334 VXNlcm5hbWU6",
            "334 UGFzc3dvcmQ6",
            "235 accepted",
            "250 sender ok",
            "250 recipient ok",
            "354 go ahead",
            "250 queued",
        ])
        let client = SMTPClient(transport: transport)
        try await client.submit(message: sampleMessage(), username: "user", password: "pw")

        let text = transport.writtenText
        XCTAssertTrue(text.contains("AUTH LOGIN\r\n"))
        XCTAssertTrue(text.contains(Data("user".utf8).base64EncodedString() + "\r\n"))
        XCTAssertTrue(text.contains(Data("pw".utf8).base64EncodedString() + "\r\n"))
    }

    func testBadCredentialsThrowWithServerReply() async {
        let transport = ScriptedTransport(replies: [
            "220 ready",
            "250 OK",
            "535 bad credentials",
            "535 still bad",
        ])
        let client = SMTPClient(transport: transport)
        do {
            try await client.submit(message: sampleMessage(), username: "u", password: "wrong")
            XCTFail("expected SMTPError")
        } catch let error as SMTPError {
            XCTAssertTrue(error.reply.contains("535"))
            XCTAssertTrue(transport.closed)
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    func testRejectedRecipientThrows() async {
        let transport = ScriptedTransport(replies: [
            "220 ready",
            "250 OK",
            "235 accepted",
            "250 sender ok",
            "550 no such user",
        ])
        let client = SMTPClient(transport: transport)
        do {
            try await client.submit(message: sampleMessage(), username: "u", password: "pw")
            XCTFail("expected SMTPError")
        } catch let error as SMTPError {
            XCTAssertEqual(error.step, "RCPT TO")
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    func testDotStuffingEscapesLeadingDots() {
        let input = Data("first\r\n.hidden\r\n..already\r\nok.\r\n".utf8)
        let output = SMTPClient.dotStuffed(input)
        XCTAssertEqual(
            String(decoding: output, as: UTF8.self),
            "first\r\n..hidden\r\n...already\r\nok.\r\n")
    }
}
