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

    func testNewestQualifyingRowWins() {
        // Header row + three captures (oldest→newest). Newest non-tiny 200 wins.
        let data = json("""
        [["urlkey","timestamp","original","mimetype","statuscode","digest","length"],
         ["com,example)/a","20240101000000","https://example.com/a","text/html","200","D1","8000"],
         ["com,example)/a","20250601120000","https://example.com/a","text/html","200","D2","9000"],
         ["com,example)/a","20260101000000","https://example.com/a","text/html","200","D3","12000"]]
        """)
        XCTAssertEqual(ArticleFetcher.newestSnapshotTimestamp(fromCDXJSON: data), "20260101000000")
    }

    func testTinyCaptureSkipped() {
        // The newest row is a tiny (sub-1KB) stub; the prior real capture wins.
        let data = json("""
        [["urlkey","timestamp","original","mimetype","statuscode","digest","length"],
         ["com,example)/a","20250601120000","https://example.com/a","text/html","200","D2","9000"],
         ["com,example)/a","20260101000000","https://example.com/a","text/html","200","D3","200"]]
        """)
        XCTAssertEqual(ArticleFetcher.newestSnapshotTimestamp(fromCDXJSON: data), "20250601120000")
    }

    func testEmptyArrayReturnsNil() {
        XCTAssertNil(ArticleFetcher.newestSnapshotTimestamp(fromCDXJSON: json("[]")))
    }

    func testHeaderOnlyReturnsNil() {
        let data = json("""
        [["urlkey","timestamp","original","mimetype","statuscode","digest","length"]]
        """)
        XCTAssertNil(ArticleFetcher.newestSnapshotTimestamp(fromCDXJSON: data))
    }

    func testMalformedJSONReturnsNil() {
        XCTAssertNil(ArticleFetcher.newestSnapshotTimestamp(fromCDXJSON: json("{not an array}")))
    }

    func testNumericTimestampTolerated() {
        // CDX usually returns strings, but tolerate numeric cells defensively.
        let data = json("""
        [["urlkey","timestamp","original","mimetype","statuscode","digest","length"],
         ["com,example)/a",20260101000000,"https://example.com/a","text/html",200,"D3",12000]]
        """)
        XCTAssertEqual(ArticleFetcher.newestSnapshotTimestamp(fromCDXJSON: data), "20260101000000")
    }

    func testRowWithMissingLengthStillCounts() {
        // Some short rows omit the length column; don't drop them for that alone.
        let data = json("""
        [["urlkey","timestamp","original","mimetype","statuscode","digest","length"],
         ["com,example)/a","20260101000000","https://example.com/a","text/html","200"]]
        """)
        XCTAssertEqual(ArticleFetcher.newestSnapshotTimestamp(fromCDXJSON: data), "20260101000000")
    }

    // MARK: - Oldest (pre-paywall) end

    func testOldestQualifyingRowWins() {
        // The pre-paywall strategy wants the OTHER end of the same response: the first
        // capture, taken before the publisher metered the page.
        let data = json("""
        [["urlkey","timestamp","original","mimetype","statuscode","digest","length"],
         ["com,example)/a","20100101000000","https://example.com/a","text/html","200","D1","8000"],
         ["com,example)/a","20250601120000","https://example.com/a","text/html","200","D2","9000"],
         ["com,example)/a","20260101000000","https://example.com/a","text/html","200","D3","12000"]]
        """)
        XCTAssertEqual(ArticleFetcher.oldestSnapshotTimestamp(fromCDXJSON: data), "20100101000000")
        XCTAssertEqual(ArticleFetcher.newestSnapshotTimestamp(fromCDXJSON: data), "20260101000000")
    }

    func testOldestSkipsTinyCapture() {
        // The first capture is a sub-1KB stub (a redirect shell / "coming soon" page);
        // the first REAL capture is the pre-paywall one.
        let data = json("""
        [["urlkey","timestamp","original","mimetype","statuscode","digest","length"],
         ["com,example)/a","20090101000000","https://example.com/a","text/html","200","D0","200"],
         ["com,example)/a","20100101000000","https://example.com/a","text/html","200","D1","8000"]]
        """)
        XCTAssertEqual(ArticleFetcher.oldestSnapshotTimestamp(fromCDXJSON: data), "20100101000000")
    }

    func testOldestReturnsNilWithoutRows() {
        XCTAssertNil(ArticleFetcher.oldestSnapshotTimestamp(fromCDXJSON: json("[]")))
        XCTAssertNil(ArticleFetcher.oldestSnapshotTimestamp(fromCDXJSON: json("{not an array}")))
    }

    // MARK: - Is a pre-paywall capture even possible?

    private let now = ISO8601DateFormatter().date(from: "2026-08-01T12:00:00Z")!

    func testTimestampParsing() {
        XCTAssertEqual(ArticleFetcher.waybackDate(fromTimestamp: "20260731015035"),
                       ISO8601DateFormatter().date(from: "2026-07-31T01:50:35Z"))
        XCTAssertNil(ArticleFetcher.waybackDate(fromTimestamp: "2026073101"))     // too short
        XCTAssertNil(ArticleFetcher.waybackDate(fromTimestamp: "2026073101503x")) // not numeric
    }

    func testFreshCaptureCannotPredateAWall() {
        // Yesterday's first capture of a hard-paywalled story: the oldest snapshot IS the
        // walled one, so replaying it is a download that provably cannot help.
        XCTAssertFalse(ArticleFetcher.captureCouldPredateAWall("20260731015035", now: now))
    }

    func testDecadeOldCaptureCouldPredateAWall() {
        // The Paris Review shape: captured in 2012, metered years later.
        XCTAssertTrue(ArticleFetcher.captureCouldPredateAWall("20120405120000", now: now))
    }

    func testUnparseableTimestampKeepsTheAttempt() {
        // The skip is an optimization; bad index data must never suppress a strategy.
        XCTAssertTrue(ArticleFetcher.captureCouldPredateAWall("not-a-timestamp", now: now))
    }
}
