//
//  XteinkTransferSizePolicyTests.swift
//  LunaTests
//

import LunaSend
import XCTest

final class XteinkTransferSizePolicyTests: XCTestCase {

    func testDefaultBLECutoffIsAnInclusive200KiB() {
        let policy = XteinkTransferSizePolicy()
        XCTAssertEqual(policy.maximumBLEBytes, 200 * 1024)
        XCTAssertEqual(
            policy.transport(forFinalXteinkEPUBByteCount: 200 * 1024),
            .bluetoothLowEnergy)
        XCTAssertEqual(
            policy.transport(forFinalXteinkEPUBByteCount: 200 * 1024 + 1),
            .wifi)
    }

    func testFinalizedDataConvenienceUsesItsFinalByteCount() {
        let policy = XteinkTransferSizePolicy(maximumBLEBytes: 4)
        XCTAssertEqual(policy.transport(forFinalXteinkEPUB: Data([1, 2, 3, 4])), .bluetoothLowEnergy)
        XCTAssertEqual(policy.transport(forFinalXteinkEPUB: Data([1, 2, 3, 4, 5])), .wifi)
    }
}
