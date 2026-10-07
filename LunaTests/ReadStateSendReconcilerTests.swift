//
//  ReadStateSendReconcilerTests.swift
//  LunaTests
//

import LunaEpub
import LunaModels
import LunaStorage
import XCTest
@testable import LunaSend

final class ReadStateSendReconcilerTests: XCTestCase {
    private var scratchDirectory: URL!
    private var store: SavesStore!
    private let destination = "plugin.reader"

    /// A destination that answers whatever a test needs it to, so the
    /// reconciler is exercised over the `dequeuesOnRead` flag rather than over
    /// one hard-coded id.
    private struct Destination: ArticleDestination {
        let id: String
        let dequeuesOnRead: Bool
        var displayName: String { id }
        var isConfigured: Bool { true }
        func sendMode(for item: SavedItem) -> ArticleSendMode { .off }
        var appIntentsSendMode: ArticleSendMode { .off }
        func send(epubData: Data, fileName: String, title: String) async throws {}
    }

    override func setUp() {
        super.setUp()
        scratchDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReadStateSendReconcilerTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratchDirectory, withIntermediateDirectories: true)
        store = SavesStore(containerURL: scratchDirectory)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: scratchDirectory)
        super.tearDown()
    }

    private func reconcile(_ ids: [String]) {
        ReadStateSendReconciler.dequeueSendsFinishedBeforeDelivery(
            destinationIDs: ids, store: store)
    }

    func testUnqueuesAReadNonImmuneSend() {
        let item = store.add(urlString: "https://example.com/read")
        store.setSendState(.queued, for: item.id, destination: destination) // unread at enqueue
        store.markReadState(.read, for: item.id) // finished before delivery went out
        reconcile([destination])
        XCTAssertNil(store.item(withID: item.id)?.sendState(for: destination))
    }

    func testDropsAnAlreadyReadSendEvenWithLegacyImmunity() {
        let item = store.add(urlString: "https://example.com/immune")
        store.markReadState(.read, for: item.id)
        store.setSendState(.queued, for: item.id, destination: destination) // legacy queue with queuedWhileRead set
        reconcile([destination])
        XCTAssertNil(store.item(withID: item.id)?.sendState(for: destination))
    }

    func testKeepsAnUnreadQueuedSend() {
        let item = store.add(urlString: "https://example.com/unread")
        store.setSendState(.queued, for: item.id, destination: destination)
        reconcile([destination])
        XCTAssertEqual(store.item(withID: item.id)?.sendState(for: destination), .queued)
    }

    func testLeavesAnAlreadyDeliveredSendAlone() {
        let item = store.add(urlString: "https://example.com/sent")
        store.setSendState(.sent, for: item.id, destination: destination)
        store.markReadState(.read, for: item.id)
        reconcile([destination])
        XCTAssertEqual(store.item(withID: item.id)?.sendState(for: destination), .sent)
    }

    /// The dequeue follows the flag, not the id: a second destination that
    /// declares it is pruned the same way, and one that does not keeps its
    /// queued send even for the same read save.
    func testTheDequeueFollowsTheDestinationsOwnFlag() {
        let item = store.add(urlString: "https://example.com/both")
        store.setSendState(.queued, for: item.id, destination: "plugin.reader")
        store.setSendState(.queued, for: item.id, destination: ArticleDestinationID.kindle)
        store.markReadState(.read, for: item.id)

        let coordinator = ArticleSendCoordinator(
            store: store,
            destinations: [
                Destination(id: "plugin.reader", dequeuesOnRead: true),
                Destination(id: ArticleDestinationID.kindle, dequeuesOnRead: false),
            ])
        XCTAssertEqual(coordinator.dequeueOnReadDestinationIDs(), ["plugin.reader"])

        reconcile(coordinator.dequeueOnReadDestinationIDs())
        let fresh = store.item(withID: item.id)
        XCTAssertNil(fresh?.sendState(for: "plugin.reader"))
        XCTAssertEqual(
            fresh?.sendState(for: ArticleDestinationID.kindle), .queued,
            "a destination that tracks no reading keeps its queue")
    }

    /// The sweep entry point reconciles before it reads the queue, so a save
    /// finished while the receiver was asleep is never delivered.
    func testDeliverQueuedSendsDropsAReadSaveBeforeSweeping() async {
        let item = store.add(urlString: "https://example.com/finished")
        store.setSendState(.queued, for: item.id, destination: "plugin.reader")
        store.markReadState(.read, for: item.id)

        let coordinator = ArticleSendCoordinator(
            store: store, destinations: [Destination(id: "plugin.reader", dequeuesOnRead: true)])
        await coordinator.deliverQueuedSends(toDestinationID: "plugin.reader")

        XCTAssertNil(store.item(withID: item.id)?.sendState(for: "plugin.reader"))
    }
}
