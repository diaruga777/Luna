//
//  XteinkStatusMessageTests.swift
//  LunaTests
//

import Foundation
import XCTest
@testable import LunaSend

final class XteinkStatusMessageTests: XCTestCase {
    private func json(_ object: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }

    func testExistingFieldsStillParse() throws {
        let data = json([
            "op_ack": "hello", "nonce": "abc123", "received": 40,
            "resume_offset": 40, "next_sequence": 3,
        ])
        let message = try XCTUnwrap(XteinkStatusMessage.parse(data))
        XCTAssertEqual(message.opAck, "hello")
        XCTAssertEqual(message.nonce, "abc123")
        XCTAssertEqual(message.received, 40)
        XCTAssertEqual(message.resumeOffset, 40)
        XCTAssertEqual(message.nextSequence, 3)
        XCTAssertFalse(message.isFailure)
        XCTAssertTrue(message.readIDs.isEmpty)
        XCTAssertFalse(message.isReadReportWindow)
    }

    func testWifiOfferParses() throws {
        let data = json(["wifi": ["mode": "ap", "ssid": "Xteink-X3", "password": "secret", "ip": "192.168.4.1"]])
        let message = try XCTUnwrap(XteinkStatusMessage.parse(data))
        let wifi = try XCTUnwrap(message.wifi)
        XCTAssertEqual(wifi.mode, .ap)
        XCTAssertEqual(wifi.ssid, "Xteink-X3")
        XCTAssertEqual(wifi.passphrase, "secret")
        XCTAssertEqual(wifi.host, "192.168.4.1")
    }

    func testOkFalsePrecedesOverOtherFields() throws {
        let data = json(["ok": false, "op_ack": "start_put"])
        let message = try XCTUnwrap(XteinkStatusMessage.parse(data))
        XCTAssertTrue(message.isFailure)
        XCTAssertNil(message.error)
    }

    func testNonEmptyErrorIsAFailureEvenWithoutOkFalse() throws {
        let data = json(["error": "pairing_failed"])
        let message = try XCTUnwrap(XteinkStatusMessage.parse(data))
        XCTAssertTrue(message.isFailure)
        XCTAssertEqual(message.error, "pairing_failed")
    }

    func testEmptyErrorStringIsNotAFailure() throws {
        let data = json(["ok": true, "error": ""])
        let message = try XCTUnwrap(XteinkStatusMessage.parse(data))
        XCTAssertFalse(message.isFailure)
    }

    func testWinRRMarksReadReportWindow() throws {
        let data = json(["win": "rr", "nonce": "xyz"])
        let message = try XCTUnwrap(XteinkStatusMessage.parse(data))
        XCTAssertTrue(message.isReadReportWindow)
    }

    func testWinAbsentIsNotAReadReportWindow() throws {
        let data = json(["nonce": "xyz"])
        let message = try XCTUnwrap(XteinkStatusMessage.parse(data))
        XCTAssertFalse(message.isReadReportWindow)
    }

    func testNoReadIDsParsesAsEmpty() throws {
        let message = try XCTUnwrap(XteinkStatusMessage.parse(json(["op_ack": "hello"])))
        XCTAssertEqual(message.readIDs, [])
    }

    func testOneReadID() throws {
        let id = UUID()
        let message = try XCTUnwrap(
            XteinkStatusMessage.parse(json(["read_ids": [id.uuidString.lowercased()]])))
        XCTAssertEqual(message.readIDs, [id])
    }

    func testTwoReadIDs() throws {
        let first = UUID(); let second = UUID()
        let message = try XCTUnwrap(XteinkStatusMessage.parse(
            json(["read_ids": [first.uuidString.lowercased(), second.uuidString.lowercased()]])))
        XCTAssertEqual(Set(message.readIDs), Set([first, second]))
    }

    /// A malformed entry is skipped rather than failing the whole message —
    /// the device's size cap means a truncated array is expected, not fatal.
    func testMalformedReadIDIsSkippedNotFailed() throws {
        let valid = UUID()
        let message = try XCTUnwrap(XteinkStatusMessage.parse(
            json(["read_ids": ["not-a-uuid", valid.uuidString.lowercased()]])))
        XCTAssertEqual(message.readIDs, [valid])
    }

    func testUnparseableDataReturnsNil() {
        XCTAssertNil(XteinkStatusMessage.parse(Data("not json".utf8)))
    }
}
