//
//  PendingRequestsStoreTests.swift
//  LunaTests
//

import LunaSocial
import XCTest
@testable import Luna

final class PendingRequestsStoreTests: XCTestCase {

    private var store: PendingRequestsStore!
    private var scratch: URL!

    override func setUp() {
        super.setUp()
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("PendingReq-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        store = PendingRequestsStore(containerURL: scratch)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: scratch)
        super.tearDown()
    }

    private func request(url: String = "https://ex.com/a", from: String = "bob@example.com") -> PendingRequest {
        PendingRequest(senderEmail: from, senderName: "Bob", urlString: url,
                       title: "A", kind: "article", messageID: "1")
    }

    func testAddCountRemove() {
        store.add(request())
        XCTAssertEqual(store.count, 1)
        let item = store.items().first!
        store.remove(id: item.id)
        XCTAssertEqual(store.count, 0)
    }

    func testDedupesSameURLAndSender() {
        store.add(request())
        store.add(request())
        XCTAssertEqual(store.count, 1)
        XCTAssertTrue(store.contains(urlString: "https://ex.com/a", senderEmail: "BOB@example.com"))
    }

    func testDistinctSendersCoexist() {
        store.add(request(from: "bob@example.com"))
        store.add(request(from: "alice@example.com"))
        XCTAssertEqual(store.count, 2)
    }

    func testDisplaySenderFallsBackToLocalPart() {
        let req = PendingRequest(senderEmail: "carol@example.com", senderName: nil,
                                 urlString: "https://x", title: nil, kind: "link", messageID: nil)
        XCTAssertEqual(req.displaySender, "carol")
    }
}
