//
//  URLRescueStorageTests.swift
//  LunaTests
//

import XCTest
import LunaModels
@testable import LunaStorage
@testable import LunaURLRescue

final class URLRescueStorageTests: XCTestCase {

    // MARK: - RescueLedgerStore

    private func makeLedgerStore(now: @escaping () -> Date) -> RescueLedgerStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return RescueLedgerStore(containerURL: dir, now: now)
    }

    func testBudgetCapAtTwoAttempts() {
        var clock = Date(timeIntervalSince1970: 1_000_000)
        let store = makeLedgerStore(now: { clock })
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
        let store = makeLedgerStore(now: { clock })
        let id = UUID()
        store.recordAttempt(id, hint: .article)
        clock = clock.addingTimeInterval(60) // < 24h
        XCTAssertFalse(store.shouldAutoRescue(id))
        clock = clock.addingTimeInterval(RescueLedgerStore.autoRetrySpacing)
        XCTAssertTrue(store.shouldAutoRescue(id))
    }

    func testProvenanceMarker() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let store = makeLedgerStore(now: { now })
        let id = UUID()
        XCTAssertFalse(store.wasRescued(id))
        store.recordSuccess(id, hint: .product)
        XCTAssertTrue(store.wasRescued(id))
        XCTAssertEqual(store.entry(id)?.lastHint, .product)
    }

    func testPruneDropsMissingItems() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let store = makeLedgerStore(now: { now })
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

    // MARK: - PendingRescueRequestStore

    private func makePendingStore(now: @escaping () -> Date = Date.init) -> (PendingRescueRequestStore, UserDefaults) {
        let defaults = UserDefaults(suiteName: "test.rescue.\(UUID().uuidString)")!
        return (PendingRescueRequestStore(defaults: defaults, now: now), defaults)
    }

    func testAppendAndTakeAll() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let (store, _) = makePendingStore(now: { now })
        store.append(PendingRescueRequest(urlString: "https://a", hint: .article, dateWritten: now))
        store.append(PendingRescueRequest(urlString: "https://b", hint: .product, dateWritten: now))
        let taken = store.takeAll()
        XCTAssertEqual(taken.count, 2)
        XCTAssertTrue(store.takeAll().isEmpty, "takeAll should clear the queue")
    }

    func testDedupeByURLReplacesHint() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let (store, _) = makePendingStore(now: { now })
        store.append(PendingRescueRequest(urlString: "https://a", hint: .article, dateWritten: now))
        store.append(PendingRescueRequest(urlString: "https://a", hint: .media, dateWritten: now))
        let taken = store.takeAll()
        XCTAssertEqual(taken.count, 1)
        XCTAssertEqual(taken.first?.hint, .media)
    }

    func testExpiryDropsStale() {
        var clock = Date(timeIntervalSince1970: 1_000_000)
        let (store, _) = makePendingStore(now: { clock })
        store.append(PendingRescueRequest(urlString: "https://a", hint: .article, dateWritten: clock))
        clock = clock.addingTimeInterval(PendingRescueRequestStore.lifetime + 1)
        XCTAssertTrue(store.takeAll().isEmpty, "stale requests should be dropped")
    }

    // MARK: - RescueRuleStore

    private func rule(host: String = "example.com", hint: String = "article",
                      rewrite: RescueLearnedRule.URLRewrite = .pathSuffix("/amp"),
                      at date: Date) -> RescueLearnedRule {
        RescueLearnedRule(host: host, hint: hint, rewrite: rewrite, createdAt: date, lastSuccessAt: date)
    }

    func testRoundTripStoreAndFetch() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let store = InMemoryRescueRuleStore(now: { now })
        store.store(rule(at: now))
        XCTAssertNotNil(store.rule(forHost: "www.example.com", hint: .article))
        XCTAssertNil(store.rule(forHost: "example.com", hint: .product))
    }

    func testExpiryAfter30Days() {
        var clock = Date(timeIntervalSince1970: 1_000_000)
        let store = InMemoryRescueRuleStore(now: { clock })
        store.store(rule(at: clock))
        clock = clock.addingTimeInterval(RescueRuleStore.expiry + 1)
        XCTAssertNil(store.rule(forHost: "example.com", hint: .article))
    }

    func testThreeFailuresEvicts() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let store = InMemoryRescueRuleStore(now: { now })
        store.store(rule(at: now))
        store.recordFailure(forHost: "example.com", hint: .article)
        store.recordFailure(forHost: "example.com", hint: .article)
        XCTAssertNotNil(store.rule(forHost: "example.com", hint: .article))
        store.recordFailure(forHost: "example.com", hint: .article)
        XCTAssertNil(store.rule(forHost: "example.com", hint: .article))
    }

    func testRecordSuccessResetsFailures() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let store = InMemoryRescueRuleStore(now: { now })
        let r = rule(at: now)
        store.store(r)
        store.recordFailure(forHost: "example.com", hint: .article)
        store.recordFailure(forHost: "example.com", hint: .article)
        store.recordSuccess(r)
        store.recordFailure(forHost: "example.com", hint: .article)
        store.recordFailure(forHost: "example.com", hint: .article)
        XCTAssertNotNil(store.rule(forHost: "example.com", hint: .article), "success should have reset the failure count")
    }

    func testFileStoreKillSwitch() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let now = Date(timeIntervalSince1970: 1_000_000)
        let store = RescueRuleStore(containerURL: dir, now: { now })
        store.isEnabled = true
        store.store(rule(at: now))
        XCTAssertNotNil(store.rule(forHost: "example.com", hint: .article))
        store.isEnabled = false
        XCTAssertNil(store.rule(forHost: "example.com", hint: .article), "kill switch should suppress lookups")
        store.isEnabled = true // reset shared defaults for other tests
    }

    func testRewriteDerivation() {
        let base = URL(string: "https://www.example.com/a/b")!
        XCTAssertEqual(URLRescueEngine.rewrite(from: base, to: base), RescueLearnedRule.URLRewrite.none)
        XCTAssertEqual(URLRescueEngine.rewrite(from: base, to: URL(string: "https://amp.example.com/a/b")!),
                       .hostReplace("amp.example.com"))
        XCTAssertEqual(URLRescueEngine.rewrite(from: base, to: URL(string: "https://www.example.com/a/b/amp")!),
                       .pathSuffix("/amp"))
        XCTAssertEqual(URLRescueEngine.rewrite(from: base, to: URL(string: "https://www.example.com/a/b?output=amp")!),
                       .queryAppend("output=amp"))
    }

    func testApplyRewrite() {
        let base = URL(string: "https://www.example.com/a/b")!
        XCTAssertEqual(URLRescueEngine.applyRewrite(.hostReplace("amp.example.com"), to: base)?.host, "amp.example.com")
        XCTAssertEqual(URLRescueEngine.applyRewrite(.pathSuffix("/amp"), to: base)?.path, "/a/b/amp")
        XCTAssertEqual(URLRescueEngine.applyRewrite(.queryAppend("x=1"), to: base)?.query, "x=1")
    }
}
