//
//  SafariReturnPolicyTests.swift
//  LunaTests
//

import LunaURLClassification
import XCTest

/// `SafariReturnPolicy.shouldReturn`: only a flagged, handled media save returns;
/// article/product, failed/unsupported, and unflagged saves stay in Luna.
final class SafariReturnPolicyTests: XCTestCase {

    func testFlaggedHandledMediaReturns() {
        XCTAssertTrue(SafariReturnPolicy.shouldReturn(outcome: .handled, kind: .media, flagged: true))
    }

    func testFlaggedHandledProductStaysInLuna() {
        XCTAssertFalse(SafariReturnPolicy.shouldReturn(outcome: .handled, kind: .product, flagged: true))
    }

    func testArticleNeverReturnsEvenFlaggedAndHandled() {
        XCTAssertFalse(SafariReturnPolicy.shouldReturn(outcome: .handled, kind: .article, flagged: true))
    }

    func testFailedOrUnsupportedNeverReturns() {
        XCTAssertFalse(SafariReturnPolicy.shouldReturn(outcome: .failedOrUnsupported, kind: .media, flagged: true))
        XCTAssertFalse(SafariReturnPolicy.shouldReturn(outcome: .failedOrUnsupported, kind: .product, flagged: true))
    }

    func testUnflaggedNeverReturnsRegardlessOfKindOrOutcome() {
        XCTAssertFalse(SafariReturnPolicy.shouldReturn(outcome: .handled, kind: .media, flagged: false))
        XCTAssertFalse(SafariReturnPolicy.shouldReturn(outcome: .handled, kind: .product, flagged: false))
        XCTAssertFalse(SafariReturnPolicy.shouldReturn(outcome: .handled, kind: .article, flagged: false))
    }
}
