//
//  StreamIMAPCursorTests.swift
//  LunaTests
//
//  How far the IMAP poll's cursor may move. The next poll searches only above the
//  stored uid, so a cursor that advances past a message nobody read is that
//  message deleted: it is never searched for again.
//

import LunaMailAccount
import XCTest
@testable import LunaMailTransport

final class StreamIMAPCursorTests: XCTestCase {

    /// A minimal RFC 822 message body, the shape `BODY.PEEK[]` returns.
    private func raw(uid: Int) -> Data {
        Data("""
            From: Alice <alice@example.com>\r
            Subject: Share \(uid)\r
            Date: Mon, 16 Jun 2026 10:00:00 -0700\r
            \r
            https://example.com/story-\(uid)\r

            """.utf8)
    }

    /// The bug: the cursor moved before the body was in hand, so a message the
    /// server answered without a literal was skipped AND put behind the cursor —
    /// gone for good. The walk now stops at that uid and leaves the cursor below it,
    /// so the next poll searches for it again.
    func testCursorStopsAtAMessageWhoseBodyTheServerOmitted() async throws {
        var fetched: [Int] = []

        let read = try await StreamIMAPClient.readMessages(
            uids: [11, 12, 13], afterUID: 10
        ) { uid in
            fetched.append(uid)
            return uid == 12 ? nil : self.raw(uid: uid)
        }

        XCTAssertEqual(read.messages.map(\.uid), [11], "only the message that was read is delivered")
        XCTAssertEqual(read.highestUID, 11,
                       "the cursor must stay below the uid whose body never arrived")
        XCTAssertEqual(fetched, [11, 12], "the walk stops at the gap rather than reading past it")
    }

    /// The ordinary run: every body arrives, so the cursor ends at the last uid.
    func testCursorAdvancesToTheLastMessageRead() async throws {
        let read = try await StreamIMAPClient.readMessages(
            uids: [11, 12, 13], afterUID: 10
        ) { uid in self.raw(uid: uid) }

        XCTAssertEqual(read.messages.map(\.uid), [11, 12, 13])
        XCTAssertEqual(read.messages.first?.subject, "Share 11")
        XCTAssertEqual(read.highestUID, 13)
    }

    /// A poll that matched nothing leaves the cursor exactly where it was.
    func testAnEmptyMatchLeavesTheCursorWhereItWas() async throws {
        let read = try await StreamIMAPClient.readMessages(uids: [], afterUID: 10) { _ in
            XCTFail("nothing to fetch")
            return nil
        }

        XCTAssertTrue(read.messages.isEmpty)
        XCTAssertEqual(read.highestUID, 10)
    }

    /// The first message being the empty one is the worst case: nothing is read and
    /// nothing moves.
    func testAGapOnTheFirstMessageLeavesTheCursorUntouched() async throws {
        let read = try await StreamIMAPClient.readMessages(
            uids: [11, 12], afterUID: 10
        ) { _ in nil }

        XCTAssertTrue(read.messages.isEmpty)
        XCTAssertEqual(read.highestUID, 10)
    }
}
