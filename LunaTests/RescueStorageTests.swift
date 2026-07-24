//
//  RescueStorageTests.swift
//  LunaTests
//

import XCTest
import LunaModels
@testable import LunaStorage

final class RescueLedgerStoreTests: XCTestCase {
    private func makeStore(now: @escaping () -> Date) -> RescueLedgerStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return RescueLedgerStore(containerURL: dir, now: now)
    }

    func testBudgetCapAtTwoAttempts() {
        var clock = Date(timeIntervalSince1970: 1_000_000)
        let store = makeStore(now: { clock })
        let id = UUID()
        XCTAssertTrue(store.shouldAutoRescue(id))
        store.recordAttempt(id, hint: .article)
        clock = clock.addingTimeInterval(RescueLedgerStore.autoRetrySpacing + 1)
        XCTAssertTrue(store.shouldAutoRescue(id))
        store.recordAttempt(id, hint: .article)
        clock = clock.addingTimeInterval(RescueLedgerStore.autoRetrySpacing + 1)
        XCTAssertFalse(store.shouldAutoRescue(id), "third auto-attempt is over budget")
    }

    func testSpacingWindowBlocksRapidRetry() {
        var clock = Date(timeIntervalSince1970: 1_000_000)
        let store = makeStore(now: { clock })
        let id = UUID()
        store.recordAttempt(id, hint: .article)
        clock = clock.addingTimeInterval(60) // < 24h
        XCTAssertFalse(store.shouldAutoRescue(id))
        clock = clock.addingTimeInterval(RescueLedgerStore.autoRetrySpacing)
        XCTAssertTrue(store.shouldAutoRescue(id))
    }

    func testProvenanceMarker() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let store = makeStore(now: { now })
        let id = UUID()
        XCTAssertFalse(store.wasRescued(id))
        store.recordSuccess(id, hint: .product)
        XCTAssertTrue(store.wasRescued(id))
        XCTAssertEqual(store.entry(id)?.lastHint, .product)
    }

    func testPruneDropsMissingItems() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let store = makeStore(now: { now })
        let keep = UUID(); let drop = UUID()
        store.recordAttempt(keep, hint: nil)
        store.recordAttempt(drop, hint: nil)
        store.prune(keeping: [keep])
        XCTAssertNotNil(store.entry(keep))
        XCTAssertNil(store.entry(drop))
    }

    func testPersistsAcrossInstances() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let now = Date(timeIntervalSince1970: 1_000_000)
        let id = UUID()
        let a = RescueLedgerStore(containerURL: dir, now: { now })
        a.recordSuccess(id, hint: .media)
        let b = RescueLedgerStore(containerURL: dir, now: { now })
        XCTAssertTrue(b.wasRescued(id))
    }
}

final class PendingRescueRequestStoreTests: XCTestCase {
    private func makeStore(now: @escaping () -> Date = Date.init) -> (PendingRescueRequestStore, UserDefaults) {
        let defaults = UserDefaults(suiteName: "test.rescue.\(UUID().uuidString)")!
        return (PendingRescueRequestStore(defaults: defaults, now: now), defaults)
    }

    func testAppendAndTakeAll() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let (store, _) = makeStore(now: { now })
        store.append(PendingRescueRequest(urlString: "https://a", hint: .article, dateWritten: now))
        store.append(PendingRescueRequest(urlString: "https://b", hint: .product, dateWritten: now))
        let taken = store.takeAll()
        XCTAssertEqual(taken.count, 2)
        XCTAssertTrue(store.takeAll().isEmpty, "takeAll should clear the queue")
    }

    func testDedupeByURLReplacesHint() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let (store, _) = makeStore(now: { now })
        store.append(PendingRescueRequest(urlString: "https://a", hint: .article, dateWritten: now))
        store.append(PendingRescueRequest(urlString: "https://a", hint: .media, dateWritten: now))
        let taken = store.takeAll()
        XCTAssertEqual(taken.count, 1)
        XCTAssertEqual(taken.first?.hint, .media)
    }

    func testExpiryDropsStale() {
        var clock = Date(timeIntervalSince1970: 1_000_000)
        let (store, _) = makeStore(now: { clock })
        store.append(PendingRescueRequest(urlString: "https://a", hint: .article, dateWritten: clock))
        clock = clock.addingTimeInterval(PendingRescueRequestStore.lifetime + 1)
        XCTAssertTrue(store.takeAll().isEmpty, "stale requests should be dropped")
    }
}
