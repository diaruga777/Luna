//
//  XteinkRemoteDeleteRunnerTests.swift
//  LunaTests
//

import LunaModels
import LunaStorage
import XCTest
@testable import LunaSend

final class XteinkRemoteDeleteRunnerTests: XCTestCase {
    private var scratchDirectory: URL!
    private var store: SavesStore!
    private let destination = ArticleDestinationID.xteink

    override func setUp() {
        super.setUp()
        scratchDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("XteinkRemoteDeleteRunnerTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratchDirectory, withIntermediateDirectories: true)
        store = SavesStore(containerURL: scratchDirectory)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: scratchDirectory)
        super.tearDown()
    }

    private final class BLE: XteinkBLETransporting {
        var isRendezvousActive = true
        var deleteHandler: (String) throws -> Void = { _ in }
        private(set) var deletedPaths: [String] = []
        func beginRendezvousScan() {}
        func send(
            _ epub: Data, fileName: String, title: String,
            articleID: UUID?, queuedRemaining: Int?,
            progress: @escaping @Sendable (XteinkSyncProgress) -> Void
        ) async throws {}
        func requestWiFi() async throws -> XteinkWiFiOffer { XteinkWiFiOffer(mode: .ap, host: "192.168.4.1") }
        func delete(remotePath: String) async throws {
            deletedPaths.append(remotePath)
            try deleteHandler(remotePath)
        }
    }

    private func makePendingDelivery(remoteName: String = "book.epub") -> UUID {
        let item = store.add(urlString: "https://example.com/\(UUID().uuidString)")
        store.recordRemoteDelivery(for: item.id, destination: destination, remoteName: remoteName)
        store.markFinishedReading(item.id)
        precondition(store.item(withID: item.id)?.remoteDeleteStatus(for: destination) == .deletePending)
        return item.id
    }

    func testSuccessfulDeleteMarksTheDeliveryDeleted() async {
        let itemID = makePendingDelivery(remoteName: "book.epub")
        let ble = BLE()
        await XteinkRemoteDeleteRunner.drainPendingDeletes(ble: ble, store: store)
        XCTAssertEqual(ble.deletedPaths, ["book.epub"])
        XCTAssertEqual(store.item(withID: itemID)?.remoteDeleteStatus(for: destination), .deleted)
    }

    func testMissingFileErrorCountsAsDone() async {
        let itemID = makePendingDelivery()
        let ble = BLE()
        ble.deleteHandler = { _ in throw XteinkSyncError.protocolError("no such file") }
        await XteinkRemoteDeleteRunner.drainPendingDeletes(ble: ble, store: store)
        XCTAssertEqual(store.item(withID: itemID)?.remoteDeleteStatus(for: destination), .deleted)
    }

    func testOtherProtocolErrorLeavesTheDeletePending() async {
        let itemID = makePendingDelivery()
        let ble = BLE()
        ble.deleteHandler = { _ in throw XteinkSyncError.protocolError("busy") }
        await XteinkRemoteDeleteRunner.drainPendingDeletes(ble: ble, store: store)
        XCTAssertEqual(store.item(withID: itemID)?.remoteDeleteStatus(for: destination), .deletePending)
    }

    func testDeliveredNotYetReadIsNeverTargeted() async {
        let item = store.add(urlString: "https://example.com/unread")
        store.recordRemoteDelivery(for: item.id, destination: destination, remoteName: "book.epub")
        let ble = BLE()
        await XteinkRemoteDeleteRunner.drainPendingDeletes(ble: ble, store: store)
        XCTAssertTrue(ble.deletedPaths.isEmpty)
        XCTAssertEqual(store.item(withID: item.id)?.remoteDeleteStatus(for: destination), .delivered)
    }
}
