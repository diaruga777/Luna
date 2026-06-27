//
//  WaybackCDXTests.swift
//  ClipTests
//

import ClipFetch
import XCTest
@testable import Clip

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
}
