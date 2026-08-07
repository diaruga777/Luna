//
//  SafariReturnPolicyTests.swift
//  LunaTests
//

import LunaURLClassification
import XCTest

/// `SafariReturnPolicy.shouldReturn`: flagged media/product handled -> return;
/// article -> never, even flagged and handled; failed/unsupported -> never;
/// unflagged -> never.
final class SafariReturnPolicyTests: XCTestCase {

    func testFlaggedHandledMediaReturns() {
        XCTAssertTrue(SafariReturnPolicy.shouldReturn(outcome: .handled, kind: .media, flagged: true))
    }

    func testFlaggedHandledProductReturns() {
        XCTAssertTrue(SafariReturnPolicy.shouldReturn(outcome: .handled, kind: .product, flagged: true))
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
