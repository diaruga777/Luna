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

    private func request(url: String = "https://ex.com/a") -> PendingRequest {
        PendingRequest(senderEmail: "bob@example.com", senderName: "Bob", urlString: url,
                       title: "A", kind: "article", messageID: "1")
    }

    func testLoadsAndRemovesLegacyRequests() throws {
        let item = request()
        try JSONEncoder().encode([item]).write(
            to: scratch.appendingPathComponent("pendingRequests.json"), options: .atomic)

        XCTAssertEqual(store.items(), [item])
        XCTAssertEqual(store.count, 1)
        store.remove(id: item.id)
        XCTAssertEqual(store.count, 0)
    }

    func testLegacyRequestsAreSortedNewestFirst() throws {
        let older = PendingRequest(
            senderEmail: "bob@example.com", senderName: "Bob",
            urlString: "https://ex.com/old", title: "Old", kind: "article",
            messageID: "1", date: Date(timeIntervalSince1970: 1))
        let newer = PendingRequest(
            senderEmail: "alice@example.com", senderName: "Alice",
            urlString: "https://ex.com/new", title: "New", kind: "article",
            messageID: "2", date: Date(timeIntervalSince1970: 2))
        try JSONEncoder().encode([older, newer]).write(
            to: scratch.appendingPathComponent("pendingRequests.json"), options: .atomic)

        XCTAssertEqual(store.items().map(\.id), [newer.id, older.id])
    }

    func testDisplaySenderFallsBackToLocalPart() {
        let req = PendingRequest(senderEmail: "carol@example.com", senderName: nil,
                                 urlString: "https://x", title: nil, kind: "link", messageID: nil)
        XCTAssertEqual(req.displaySender, "carol")
    }
}
