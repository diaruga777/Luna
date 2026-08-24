//
//  SavesStoreRemoteDeliveryTests.swift
//  LunaTests
//
//  A destination that tracks a delivered remote file's read/delete lifecycle
//  (Xteink) rides on generic SavesStore/SavedItem bookkeeping: the immunity
//  flag stamped at enqueue, and the delete-pending transition
//  `markFinishedReading` drives for any destination that recorded a delivery.
//

import LunaStorage
import LunaModels
import XCTest

final class SavesStoreRemoteDeliveryTests: XCTestCase {
    private var scratchDirectory: URL!
    private var store: SavesStore!
    private let destination = "xteink"

    override func setUp() {
        super.setUp()
        scratchDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SavesStoreRemoteDeliveryTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratchDirectory, withIntermediateDirectories: true)
        store = SavesStore(containerURL: scratchDirectory)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: scratchDirectory)
        super.tearDown()
    }

    // MARK: - Immunity flag at enqueue

    func testFreshEnqueueStampsImmunityFromCurrentReadState() {
        let item = store.add(urlString: "https://example.com/a")
        store.markReadState(.read, for: item.id)
        store.setSendState(.queued, for: item.id, destination: destination)
        XCTAssertTrue(store.item(withID: item.id)?.queuedWhileRead(for: destination) ?? false)
    }

    func testFreshEnqueueOfAnUnreadItemIsNotImmune() {
        let item = store.add(urlString: "https://example.com/a")
        store.setSendState(.queued, for: item.id, destination: destination)
        XCTAssertFalse(store.item(withID: item.id)?.queuedWhileRead(for: destination) ?? true)
    }

    /// A retry (already `.queued`) must not re-stamp the flag from whatever
    /// the read state happens to be by the time the retry runs — only the
    /// ORIGINAL enqueue should decide immunity.
    func testRetryOfAnAlreadyQueuedSendDoesNotRestampImmunity() {
        let item = store.add(urlString: "https://example.com/a")
        store.setSendState(.queued, for: item.id, destination: destination) // unread: not immune
        store.markReadState(.read, for: item.id) // read before the retry runs
        store.markSendAttemptStarted(for: item.id, destination: destination) // still .queued going in
        XCTAssertFalse(store.item(withID: item.id)?.queuedWhileRead(for: destination) ?? true)
    }

    // MARK: - Delivery bookkeeping

    func testRecordRemoteDeliveryStoresNameAndMarksDelivered() {
        let item = store.add(urlString: "https://example.com/a")
        store.recordRemoteDelivery(for: item.id, destination: destination, remoteName: "book.epub")
        let stored = store.item(withID: item.id)
        XCTAssertEqual(stored?.remoteName(for: destination), "book.epub")
        XCTAssertEqual(stored?.remoteDeleteStatus(for: destination), .delivered)
    }

    // MARK: - In-app read schedules a remote delete

    func testInAppFinishOfADeliveredNonImmuneSendMarksDeletePending() {
        let item = store.add(urlString: "https://example.com/a")
        store.recordRemoteDelivery(for: item.id, destination: destination, remoteName: "book.epub")
        store.markFinishedReading(item.id)
        XCTAssertEqual(store.item(withID: item.id)?.remoteDeleteStatus(for: destination), .deletePending)
    }

    func testImmuneDeliveryIsNotMarkedForDeleteOnFinish() {
        let item = store.add(urlString: "https://example.com/a")
        store.markReadState(.read, for: item.id)
        store.setSendState(.queued, for: item.id, destination: destination) // stamps immune = true
        store.recordRemoteDelivery(for: item.id, destination: destination, remoteName: "book.epub")
        store.markFinishedReading(item.id)
        XCTAssertEqual(store.item(withID: item.id)?.remoteDeleteStatus(for: destination), .delivered)
    }

    /// The device-report exemption: once a delivery is flagged read-on-device,
    /// `markFinishedReading` must never advance it to delete-pending.
    func testDeviceReportedReadNeverMarksDeletePending() {
        let item = store.add(urlString: "https://example.com/a")
        store.recordRemoteDelivery(for: item.id, destination: destination, remoteName: "book.epub")
        store.markRemoteDeliveryReadOnDevice(for: item.id, destination: destination)
        store.markFinishedReading(item.id)
        XCTAssertEqual(store.item(withID: item.id)?.remoteDeleteStatus(for: destination), .readOnDevice)
    }

    func testMarkRemoteDeliveryReadOnDeviceIsANoOpOnceAlreadyPastDelivered() {
        let item = store.add(urlString: "https://example.com/a")
        store.recordRemoteDelivery(for: item.id, destination: destination, remoteName: "book.epub")
        store.markFinishedReading(item.id) // -> deletePending
        store.markRemoteDeliveryReadOnDevice(for: item.id, destination: destination)
        XCTAssertEqual(store.item(withID: item.id)?.remoteDeleteStatus(for: destination), .deletePending)
    }

    func testMarkRemoteDeliveryDeletedIsIdempotent() {
        let item = store.add(urlString: "https://example.com/a")
        store.recordRemoteDelivery(for: item.id, destination: destination, remoteName: "book.epub")
        store.markRemoteDeliveryDeleted(for: item.id, destination: destination)
        store.markRemoteDeliveryDeleted(for: item.id, destination: destination)
        XCTAssertEqual(store.item(withID: item.id)?.remoteDeleteStatus(for: destination), .deleted)
    }

    // MARK: - Dequeue

    func testClearSendStateRemovesQueueAndRetryBookkeeping() {
        let item = store.add(urlString: "https://example.com/a")
        store.scheduleSendRetry(
            for: item.id, destination: destination, failureCount: 1,
            nextAttemptDate: Date(), errorMessage: "network blip")
        store.clearSendState(for: item.id, destination: destination)
        let stored = store.item(withID: item.id)
        XCTAssertNil(stored?.sendState(for: destination))
        XCTAssertNil(stored?.sendNextAttemptDates[destination])
        XCTAssertFalse(stored?.queuedWhileRead(for: destination) ?? true)
    }
}
