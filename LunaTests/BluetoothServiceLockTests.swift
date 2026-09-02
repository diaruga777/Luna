//
//  BluetoothServiceLockTests.swift
//  LunaTests
//

import LunaStorage
import XCTest
@testable import LunaSend

final class BluetoothServiceLockTests: XCTestCase {
    private var fileURL: URL!

    override func setUp() {
        super.setUp()
        fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("service-lock-\(UUID().uuidString).lock")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: fileURL)
        super.tearDown()
    }

    func testSecondAcquireFailsUntilReleased() {
        let lock = BluetoothServiceLock(fileURL: fileURL)
        XCTAssertTrue(lock.acquire())
        XCTAssertFalse(lock.acquire(), "re-acquire while held must fail")
        lock.release()
        XCTAssertTrue(lock.acquire())
        lock.release()
    }

    /// Two instances on the same file model the two Luna processes: the
    /// `flock` is per open-file-description, so the second loses even inside
    /// one process.
    func testSeparateInstancesExcludeEachOther() {
        let owner = BluetoothServiceLock(fileURL: fileURL)
        let rival = BluetoothServiceLock(fileURL: fileURL)
        XCTAssertTrue(owner.acquire())
        XCTAssertFalse(rival.acquire())
        owner.release()
        XCTAssertTrue(rival.acquire())
        rival.release()
    }

    /// With no shared container to arbitrate through the lock degrades to a
    /// per-process flag — the work still runs exactly once.
    func testNilFileURLStillExcludesWithinTheProcess() {
        let lock = BluetoothServiceLock(fileURL: nil)
        XCTAssertTrue(lock.acquire())
        XCTAssertFalse(lock.acquire())
        lock.release()
        XCTAssertTrue(lock.acquire())
        lock.release()
    }

    /// The two Luna processes reach the CrossPoint service through different
    /// code — the Reader through `XteinkRendezvousSweepLock`, central Luna
    /// through the plugin's `luna.bluetooth` bridge — and must arbitrate
    /// through one file. Neither knows the other's constant, so the path is a
    /// pure function of the service UUID.
    func testSwiftSweepAndPluginBridgeDeriveOneFileForTheCrossPointService() {
        let uuid = XteinkSyncProtocol.service.uuidString
        let swiftPath = XteinkRendezvousSweepLock.shared.lockFileURL
        let bridgePath = BluetoothServiceLock.lockFileURL(serviceUUID: uuid)
        XCTAssertEqual(swiftPath, bridgePath)
        XCTAssertEqual(
            bridgePath, BluetoothServiceLock.lockFileURL(serviceUUID: uuid.lowercased()),
            "the reader's own spelling of the UUID must lock the same file")
    }

    func testTheSharedLockIsOneInstancePerService() {
        let uuid = XteinkSyncProtocol.service.uuidString
        XCTAssertTrue(
            BluetoothServiceLock.shared(serviceUUID: uuid)
                === BluetoothServiceLock.shared(serviceUUID: uuid.lowercased()))
    }
}
