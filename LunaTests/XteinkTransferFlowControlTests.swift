//
//  XteinkTransferFlowControlTests.swift
//  LunaTests
//

import XCTest
@testable import LunaSend

final class XteinkTransferFlowControlTests: XCTestCase {
    private let interval = XteinkTransferFlowControl.checkpointIntervalBytes
    private let margin = XteinkTransferFlowControl.inFlightMarginBytes

    func testStreamsFreelyWithinOneIntervalPlusMargin() {
        XCTAssertFalse(XteinkTransferFlowControl.shouldPause(
            sentBytes: 0, confirmedBytes: 0, totalBytes: 100_000))
        XCTAssertFalse(XteinkTransferFlowControl.shouldPause(
            sentBytes: interval + margin - 1, confirmedBytes: 0, totalBytes: 100_000))
    }

    func testPausesAtTheInFlightCap() {
        XCTAssertTrue(XteinkTransferFlowControl.shouldPause(
            sentBytes: interval + margin, confirmedBytes: 0, totalBytes: 100_000))
    }

    /// A pause always has an unconfirmed checkpoint boundary below the sent
    /// offset, so a healthy reader always releases it: the cap exceeds one
    /// interval by construction.
    func testConfirmationReleasesThePause() {
        let sent = interval + margin
        XCTAssertTrue(XteinkTransferFlowControl.shouldPause(
            sentBytes: sent, confirmedBytes: 0, totalBytes: 100_000))
        XCTAssertFalse(XteinkTransferFlowControl.shouldPause(
            sentBytes: sent, confirmedBytes: interval, totalBytes: 100_000))
    }

    /// The tail of a file smaller than the pause threshold streams without
    /// ever waiting — the commit exchange is its confirmation.
    func testNeverPausesAtOrPastTheFinalByte() {
        XCTAssertFalse(XteinkTransferFlowControl.shouldPause(
            sentBytes: 500, confirmedBytes: 0, totalBytes: 500))
        XCTAssertFalse(XteinkTransferFlowControl.shouldPause(
            sentBytes: interval + margin, confirmedBytes: 0, totalBytes: interval + margin))
    }
}
