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

    /// Two live stores on one file — the app and an extension, in different
    /// processes. Neither one's attempt may rewrite the other's row away, and
    /// each has to see what the other recorded.
    func testEitherLiveStoreSeesTheOthersWrites() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let now = Date(timeIntervalSince1970: 1_000_000)
        let a = RescueLedgerStore(containerURL: dir, now: { now })
        let b = RescueLedgerStore(containerURL: dir, now: { now })
        let fromA = UUID()
        let fromB = UUID()
        a.recordAttempt(fromA, hint: .article)
        b.recordGuardrail(fromB)

        XCTAssertTrue(a.isGuardrailed(fromB))
        a.recordAttempt(fromA, hint: .article)
        XCTAssertTrue(b.isGuardrailed(fromB), "A's attempt must not drop B's guardrail")
        XCTAssertEqual(b.entry(fromA)?.attemptCount, 2)
    }

    /// The on-disk shape another process (or an older build) writes: item UUID
    /// keys, ISO-8601 dates.
    func testLedgerReadsTheFileFormatAnotherProcessWrites() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let id = UUID()
        let json = """
        {"\(id.uuidString)":{"attemptCount":2,"succeeded":false,\
        "lastAttemptDate":"2026-08-13T04:05:06Z","guardrailedAt":"2026-08-13T04:05:06Z"}}
        """
        try Data(json.utf8).write(to: dir.appendingPathComponent("rescueLedger.json"))
        let store = RescueLedgerStore(containerURL: dir, now: { Date() })
        let entry = try XCTUnwrap(store.entry(id))
        XCTAssertEqual(entry.attemptCount, 2)
        XCTAssertEqual(entry.lastAttemptDate, Date(timeIntervalSince1970: 1_786_593_906))
        XCTAssertTrue(store.isGuardrailed(id))
        XCTAssertFalse(store.shouldAutoRescue(id))
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

    // MARK: - Guardrail permanence

    /// The budget's whole shape (2 attempts, 24h apart, reopened by an update)
    /// is beside the point once a guardrail lands: it is not a budget, it is a
    /// verdict.
    func testAGuardrailOutranksTheAttemptBudgetAndSurvivesAnUpdate() {
        var clock = Date(timeIntervalSince1970: 1_000_000)
        let store = makeLedgerStore(now: { clock })
        let id = UUID()
        store.recordGuardrail(id)
        XCTAssertTrue(store.isGuardrailed(id))
        XCTAssertFalse(store.shouldAutoRescue(id))

        clock = clock.addingTimeInterval(RescueLedgerStore.autoRetrySpacing * 30)
        store.resetAttempts(for: [id])
        XCTAssertFalse(store.shouldAutoRescue(id),
                       "an app update changes Luna's extraction code, not Apple's safety model")
    }

    func testTheBrowserHandoffIsRecordedOncePerItem() {
        let store = makeLedgerStore(now: { Date() })
        let id = UUID()
        XCTAssertFalse(store.hasHandedToBrowser(id))
        store.recordBrowserHandoff(id)
        XCTAssertTrue(store.hasHandedToBrowser(id))
    }

    // MARK: - RescueStatsStore

    private func makeStatsStore() -> RescueStatsStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return RescueStatsStore(containerURL: dir)
    }

    /// Counters have to survive the process, or a sweep's summary line resets to
    /// zero on every launch and measures nothing.
    func testCountersPersistAcrossStoreInstances() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let first = RescueStatsStore(containerURL: dir)
        first.recordAttempt()
        first.record(.rescued, method: "reroute")
        first.recordCachedRuleHit()

        let reopened = RescueStatsStore(containerURL: dir)
        XCTAssertEqual(reopened.snapshot().attempts, 1)
        XCTAssertEqual(reopened.snapshot().outcome(.rescued), 1)
        XCTAssertEqual(reopened.snapshot().methods["reroute"], 1)
        XCTAssertEqual(reopened.snapshot().cachedRuleHits, 1)
    }

    /// Two live stores counting into one file: every bump has to land, because
    /// each mutation reads the file it is adding to.
    func testCountersFromEitherLiveStoreAccumulate() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let a = RescueStatsStore(containerURL: dir)
        let b = RescueStatsStore(containerURL: dir)
        a.recordAttempt()
        b.recordAttempt()
        a.record(.rescued, method: "reroute")
        b.record(.guardrailed)

        XCTAssertEqual(a.snapshot().attempts, 2)
        XCTAssertEqual(b.snapshot().attempts, 2)
        XCTAssertEqual(a.snapshot().outcome(.rescued), 1)
        XCTAssertEqual(a.snapshot().outcome(.guardrailed), 1)
        XCTAssertEqual(b.snapshot().methods["reroute"], 1)
    }

    /// The summary line is what a sweep logs and what Diagnostics reads, so it
    /// has to name the numbers rather than just the total.
    func testSummaryLineNamesOutcomesAndMethods() {
        let store = makeStatsStore()
        store.recordAttempt()
        store.recordAttempt()
        store.record(.rescued, method: "search")
        store.record(.guardrailed)

        let line = store.summaryLine()
        XCTAssertTrue(line.contains("attempts=2"))
        XCTAssertTrue(line.contains("rescued=1"))
        XCTAssertTrue(line.contains("guardrailed=1"))
        XCTAssertTrue(line.contains("search 1"))
    }

    /// Zero-valued buckets would make every line a wall of noise.
    func testSummaryLineOmitsEmptyBuckets() {
        let store = makeStatsStore()
        store.recordAttempt()
        XCTAssertFalse(store.summaryLine().contains("guardrailed"))
    }

    // MARK: - RescueFailureEvidence

    private let sampleTrace = """
    2026-08-13T10:00:00Z [ingest] start https://example.com/story
    2026-08-13T10:00:01Z [fetch] status=403 refused
    2026-08-13T10:00:01Z [fetch] status=403 refused
    2026-08-13T10:00:02Z [bypass] strategy=googlebot status=403
    2026-08-13T10:00:03Z [reader] extracted 0 blocks
    """

    /// Compression, not truncation: the ladder's repeats collapse to one line
    /// with a count, which is what the model needs to know happened.
    func testRepeatedLinesCollapseWithACount() {
        let evidence = RescueFailureEvidence.build(trace: sampleTrace, maxCharacters: 4_000)
        XCTAssertNotNil(evidence)
        XCTAssertTrue(evidence!.contains("[fetch] status=403 refused (×2)"))
        XCTAssertEqual(evidence!.components(separatedBy: "status=403 refused").count - 1, 1)
    }

    /// Timestamps cost tokens and the ORDER already carries the only temporal
    /// fact that matters.
    func testTimestampsAreDroppedButCategoriesKept() {
        let evidence = RescueFailureEvidence.build(trace: sampleTrace, maxCharacters: 4_000) ?? ""
        XCTAssertFalse(evidence.contains("2026-08-13T10:00:00Z"))
        XCTAssertTrue(evidence.contains("[bypass]"))
    }

    /// A trace accumulates every retry; the newest pass is the one whose evidence
    /// is still true.
    func testOnlyTheLastAttemptSurvives() {
        let trace = """
        2026-08-13T09:00:00Z [ingest] start https://example.com/story
        2026-08-13T09:00:01Z [fetch] status=500 ancient failure
        2026-08-13T10:00:00Z [ingest] start https://example.com/story
        2026-08-13T10:00:01Z [fetch] status=403 today's failure
        """
        let evidence = RescueFailureEvidence.build(trace: trace, maxCharacters: 4_000) ?? ""
        XCTAssertTrue(evidence.contains("today's failure"))
        XCTAssertFalse(evidence.contains("ancient failure"))
    }

    /// The segmentation is only worth anything if it recognizes the shape the
    /// REAL writers use. Both `ReadingListIngestor` and `ShareSurfaceDriver` open
    /// a trace with `ingest: begin <url> source=…`, and this parser is maintained
    /// independently of them — so pin the two together here rather than
    /// discovering the mismatch as silently-unsegmented evidence on a device.
    func testTheRealRecordersOpeningLineIsRecognizedAsAnAttemptBoundary() {
        XCTAssertTrue(RescueFailureEvidence.isAttemptBoundary(
            "ingest: begin https://example.com/story source=shareSheet"))
        XCTAssertFalse(RescueFailureEvidence.isAttemptBoundary(
            "pipeline: classified article"))
        XCTAssertFalse(RescueFailureEvidence.isAttemptBoundary(
            "resolve: no silent strategy qualified"))
    }

    /// A previous rescue's own narration must NOT segment away the ingest record
    /// it was reasoning about — that record is the most useful thing in the file,
    /// and a rescue that only sees the last rescue's account of itself is back to
    /// being blind. The earlier attempt's verdict stays, as evidence.
    func testAPreviousRescueDoesNotSegmentAwayTheIngestRecord() {
        let trace = """
        2026-08-13T10:00:00.000Z [ingest] ingest: begin https://example.com/story source=manual
        2026-08-13T10:00:01.000Z [fetch] fetch: status=403 refused
        2026-08-13T10:05:00.000Z [rescue] start host=example.com hint=auto
        2026-08-13T10:05:30.000Z [rescue] apply outcome=unrescuable host=example.com
        """
        let evidence = RescueFailureEvidence.build(trace: trace, maxCharacters: 4_000) ?? ""
        XCTAssertTrue(evidence.contains("status=403 refused"))
        XCTAssertTrue(evidence.contains("outcome=unrescuable"),
                      "what the last rescue already tried is evidence too")
    }

    /// …end to end, in the recorder's real line format.
    func testALiveShapedTraceSegmentsToItsLastPass() {
        let trace = """
        2026-08-13T10:00:00.123Z [ingest] ingest: begin https://example.com/story source=shareSheet
        2026-08-13T10:00:01.000Z [fetch] fetch: status=500 first pass
        2026-08-13T11:00:00.000Z [ingest] ingest: begin https://example.com/story source=manual
        2026-08-13T11:00:01.000Z [fetch] fetch: status=403 second pass
        2026-08-13T11:00:02.000Z [bypass] resolve: no silent strategy qualified
        """
        let evidence = RescueFailureEvidence.build(trace: trace, maxCharacters: 4_000) ?? ""
        XCTAssertTrue(evidence.contains("second pass"))
        XCTAssertTrue(evidence.contains("no silent strategy qualified"))
        XCTAssertFalse(evidence.contains("first pass"))
    }

    /// Over budget, the least diagnostic lines go first and the OLDEST survivors
    /// go next — what reaches the model is the newest and most telling.
    func testBudgetKeepsTheNewestSignalBearingLines() {
        let noise = (0..<50).map { "2026-08-13T10:00:00Z [ui] rendered frame \($0)" }
        let trace = (noise + ["2026-08-13T10:01:00Z [fetch] status=429 challenge"])
            .joined(separator: "\n")
        let evidence = RescueFailureEvidence.build(trace: trace, maxCharacters: 120) ?? ""
        XCTAssertTrue(evidence.contains("status=429"))
        XCTAssertFalse(evidence.contains("rendered frame"))
    }

    /// Nil is the normal case on a real install for a while — every failure
    /// recorded before the trace file existed — and it must read as "no evidence",
    /// never as an empty fenced section.
    func testAnAbsentTraceProducesNoEvidence() {
        XCTAssertNil(RescueFailureEvidence.build(trace: nil, maxCharacters: 4_000))
        XCTAssertNil(RescueFailureEvidence.build(trace: "", maxCharacters: 4_000))
        XCTAssertNil(RescueFailureEvidence.build(trace: sampleTrace, maxCharacters: 0))
    }

    /// Evidence takes its slice out of the digest's, and only when there IS
    /// evidence — a trace-less rescue must see the budget it always saw.
    func testTheBudgetSplitOnlyAppliesWhenThereIsEvidence() {
        let whole = URLRescueEngine.split(budget: .onDevice, hasEvidence: false)
        XCTAssertEqual(whole.digest.maxCharacters, RescueDigestBudget.onDevice.maxCharacters)
        XCTAssertEqual(whole.evidence, 0)

        let split = URLRescueEngine.split(budget: .onDevice, hasEvidence: true)
        XCTAssertEqual(split.digest.maxCharacters + split.evidence,
                       RescueDigestBudget.onDevice.maxCharacters)
        XCTAssertGreaterThan(split.evidence, 0)
        XCTAssertLessThan(split.evidence, split.digest.maxCharacters)
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
