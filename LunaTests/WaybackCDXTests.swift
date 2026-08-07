//
//  WaybackCDXTests.swift
//  LunaTests
//

import LunaFetch
import XCTest
@testable import Luna

/// Covers the pure CDX-JSON timestamp parser used by the Wayback raw-replay strategy.
final class WaybackCDXTests: XCTestCase {

    private func json(_ string: String) -> Data { Data(string.utf8) }

    private let header = #"["urlkey","timestamp","original","mimetype","statuscode","digest","length"]"#

    /// Header row + captures, oldest→newest, all real (non-tiny) 200s.
    private var threeGoodCaptures: String {
        """
        [\(header),
         ["com,example)/a","20100101000000","https://example.com/a","text/html","200","D1","8000"],
         ["com,example)/a","20250601120000","https://example.com/a","text/html","200","D2","9000"],
         ["com,example)/a","20260101000000","https://example.com/a","text/html","200","D3","12000"]]
        """
    }

    // MARK: - Newest (raw-replay) end

    func testNewestSnapshotTimestamp() {
        let cases: [(name: String, json: String, expected: String?)] = [
            ("newest qualifying row wins", threeGoodCaptures, "20260101000000"),
            // The newest row is a tiny (sub-1KB) stub; the prior real capture wins.
            ("tiny newest capture is skipped", """
            [\(header),
             ["com,example)/a","20250601120000","https://example.com/a","text/html","200","D2","9000"],
             ["com,example)/a","20260101000000","https://example.com/a","text/html","200","D3","200"]]
            """, "20250601120000"),
            ("empty array", "[]", nil),
            ("header only", "[\(header)]", nil),
            ("malformed JSON", "{not an array}", nil),
            // CDX usually returns strings, but tolerate numeric cells defensively.
            ("numeric cells tolerated", """
            [\(header),
             ["com,example)/a",20260101000000,"https://example.com/a","text/html",200,"D3",12000]]
            """, "20260101000000"),
            // Some short rows omit the length column; don't drop them for that alone.
            ("row with a missing length column still counts", """
            [\(header),
             ["com,example)/a","20260101000000","https://example.com/a","text/html","200"]]
            """, "20260101000000"),
        ]

        for testCase in cases {
            XCTAssertEqual(
                ArticleFetcher.newestSnapshotTimestamp(fromCDXJSON: json(testCase.json)),
                testCase.expected,
                testCase.name)
        }
    }

    // MARK: - Oldest (pre-paywall) end

    func testOldestSnapshotTimestamp() {
        let cases: [(name: String, json: String, expected: String?)] = [
            // The pre-paywall strategy wants the OTHER end of the same response: the
            // first capture, taken before the publisher metered the page.
            ("oldest qualifying row wins", threeGoodCaptures, "20100101000000"),
            // The first capture is a sub-1KB stub (a redirect shell / "coming soon"
            // page); the first REAL capture is the pre-paywall one.
            ("tiny oldest capture is skipped", """
            [\(header),
             ["com,example)/a","20090101000000","https://example.com/a","text/html","200","D0","200"],
             ["com,example)/a","20100101000000","https://example.com/a","text/html","200","D1","8000"]]
            """, "20100101000000"),
            ("empty array", "[]", nil),
            ("malformed JSON", "{not an array}", nil),
        ]

        for testCase in cases {
            XCTAssertEqual(
                ArticleFetcher.oldestSnapshotTimestamp(fromCDXJSON: json(testCase.json)),
                testCase.expected,
                testCase.name)
        }
    }

    // MARK: - Is a pre-paywall capture even possible?

    private let now = ISO8601DateFormatter().date(from: "2026-08-01T12:00:00Z")!

    func testTimestampParsing() {
        let cases: [(name: String, timestamp: String, expected: Date?)] = [
            ("full 14-digit timestamp", "20260731015035",
             ISO8601DateFormatter().date(from: "2026-07-31T01:50:35Z")),
            ("too short", "2026073101", nil),
            ("not numeric", "2026073101503x", nil),
        ]

        for testCase in cases {
            XCTAssertEqual(
                ArticleFetcher.waybackDate(fromTimestamp: testCase.timestamp),
                testCase.expected,
                testCase.name)
        }
    }

    func testCaptureCouldPredateAWall() {
        let cases: [(name: String, timestamp: String, expected: Bool)] = [
            // Yesterday's first capture of a hard-paywalled story: the oldest snapshot
            // IS the walled one, so replaying it is a download that provably can't help.
            ("fresh capture cannot predate a wall", "20260731015035", false),
            // The Paris Review shape: captured in 2012, metered years later.
            ("decade-old capture could predate a wall", "20120405120000", true),
            // The skip is an optimization; bad index data must never suppress a strategy.
            ("unparseable timestamp keeps the attempt", "not-a-timestamp", true),
        ]

        for testCase in cases {
            XCTAssertEqual(
                ArticleFetcher.captureCouldPredateAWall(testCase.timestamp, now: now),
                testCase.expected,
                testCase.name)
        }
    }
}
