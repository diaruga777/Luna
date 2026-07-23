//
//  RescueRuleStoreTests.swift
//  LunaTests
//

import XCTest
@testable import LunaURLRescue

final class RescueRuleStoreTests: XCTestCase {

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
