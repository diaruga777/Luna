import Foundation
import XCTest
import LunaMailAccount
@testable import LunaMailTransport

final class StreamIMAPSearchTests: XCTestCase {
    func testBuiltInUnicodePrefixUsesUTF8ByteCountAndWaitsForContinuation() async throws {
        let command = StreamIMAPClient.textSearch(range: "UID 101:*", field: "SUBJECT", value: FilterGuide.subjectMatch)
        XCTAssertTrue(command.line.hasPrefix("UID SEARCH CHARSET UTF-8 UID 101:* SUBJECT {"))
        XCTAssertTrue(command.line.hasSuffix("{\(FilterGuide.subjectMatch.utf8.count)}"))
        XCTAssertFalse(command.line.contains("\u{200C}"))
        var replies = ["* 50 EXISTS", "+ Ready for literal", "* SEARCH 101 102", "a4 OK SEARCH completed"]
        var writes: [Data] = []
        let result = try await StreamIMAPClient.Session.exchange(
            command: "a4 \(command.line)", tag: "a4", step: "search", literal: command.literal,
            write: { data in
                if writes.count == 1 { XCTAssertEqual(replies.count, 2, "Must consume continuation before sending UTF-8") }
                writes.append(data)
            }, readLine: { replies.removeFirst() }, readBytes: { _ in XCTFail("No incoming literals"); return Data() })
        XCTAssertEqual(writes, [Data("a4 \(command.line)\r\n".utf8), Data((FilterGuide.subjectMatch + "\r\n").utf8)])
        XCTAssertEqual(GmailIMAPClient.parseSearchUIDs(result.lines), [101, 102])
    }

    func testServerRejectionDoesNotSendTheLiteral() async {
        let command = StreamIMAPClient.textSearch(range: "SINCE 07-Oct-2026", field: "SUBJECT", value: "日本語")
        var writes = 0
        do {
            _ = try await StreamIMAPClient.Session.exchange(
                command: "a4 \(command.line)", tag: "a4", step: "search", literal: command.literal,
                write: { _ in writes += 1 }, readLine: { "a4 NO [BADCHARSET] Unsupported charset" },
                readBytes: { _ in Data() })
            XCTFail("Expected a search failure")
        } catch {
            XCTAssertEqual(writes, 1)
            XCTAssertTrue(String(describing: error).contains("BADCHARSET"))
        }
    }

    func testQuotedCharactersAndNewlinesStayInsideLiteralAndDateIsLocaleIndependent() {
        let value = "Daily \\\"News\\\"\r\n日本語"
        let command = StreamIMAPClient.textSearch(range: "SINCE 07-Oct-2026", field: "SUBJECT", value: value)
        XCTAssertFalse(command.line.contains("\r"))
        XCTAssertFalse(command.line.contains("\n"))
        XCTAssertEqual(command.literal, Data(value.utf8))
        XCTAssertEqual(StreamIMAPClient.searchDate(ISO8601DateFormatter().date(from: "2026-10-07T23:59:59Z")!), "07-Oct-2026")
    }
}
