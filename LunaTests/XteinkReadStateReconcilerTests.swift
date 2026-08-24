//
//  XteinkReadStateReconcilerTests.swift
//  LunaTests
//

import LunaModels
import LunaStorage
import XCTest
@testable import LunaSend

final class XteinkReadStateReconcilerTests: XCTestCase {
    private var scratchDirectory: URL!
    private var store: SavesStore!
    private let destination = ArticleDestinationID.xteink

    override func setUp() {
        super.setUp()
        scratchDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("XteinkReadStateReconcilerTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratchDirectory, withIntermediateDirectories: true)
        store = SavesStore(containerURL: scratchDirectory)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: scratchDirectory)
        super.tearDown()
    }

    func testUnqueuesAReadNonImmuneSend() {
        let item = store.add(urlString: "https://example.com/read")
        store.setSendState(.queued, for: item.id, destination: destination) // unread at enqueue
        store.markReadState(.read, for: item.id) // finished before delivery went out
        XteinkReadStateReconciler.dequeueSendsFinishedBeforeDelivery(store: store)
        XCTAssertNil(store.item(withID: item.id)?.sendState(for: destination))
    }

    func testKeepsAnImmuneSendQueuedEvenWhenRead() {
        let item = store.add(urlString: "https://example.com/immune")
        store.markReadState(.read, for: item.id)
        store.setSendState(.queued, for: item.id, destination: destination) // queued WHILE read: immune
        XteinkReadStateReconciler.dequeueSendsFinishedBeforeDelivery(store: store)
        XCTAssertEqual(store.item(withID: item.id)?.sendState(for: destination), .queued)
    }

    func testKeepsAnUnreadQueuedSend() {
        let item = store.add(urlString: "https://example.com/unread")
        store.setSendState(.queued, for: item.id, destination: destination)
        XteinkReadStateReconciler.dequeueSendsFinishedBeforeDelivery(store: store)
        XCTAssertEqual(store.item(withID: item.id)?.sendState(for: destination), .queued)
    }

    func testLeavesAnAlreadyDeliveredSendAlone() {
        let item = store.add(urlString: "https://example.com/sent")
        store.setSendState(.sent, for: item.id, destination: destination)
        store.markReadState(.read, for: item.id)
        XteinkReadStateReconciler.dequeueSendsFinishedBeforeDelivery(store: store)
        XCTAssertEqual(store.item(withID: item.id)?.sendState(for: destination), .sent)
    }
}
