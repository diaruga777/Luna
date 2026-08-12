//
//  URLRescueCoordinatorTests.swift
//  LunaTests
//

import XCTest
import LunaModels
import LunaStorage
@testable import LunaReadingList

final class URLRescueCoordinatorTests: XCTestCase {
    private var tempDir: URL!
    private var store: ReadingListStore!
    private var ledger: RescueLedgerStore!
    private var pending: PendingRescueRequestStore!
    private var savedEngine: URLRescueCoordinator.Engine?

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        store = ReadingListStore(containerURL: tempDir)
        ledger = RescueLedgerStore(containerURL: tempDir)
        pending = PendingRescueRequestStore(defaults: UserDefaults(suiteName: "test.\(UUID().uuidString)")!)
        savedEngine = URLRescueCoordinator.engine
    }

    override func tearDown() {
        URLRescueCoordinator.engine = savedEngine
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    /// A fake engine recording each perform call; returns a configurable result.
    private final class RecordingEngine {
        var result: URLRescueCoordinator.RescueRunResult
        var available: Bool
        private(set) var performedIDs: [UUID] = []
        private(set) var performedHints: [RescueHint?] = []
        private(set) var performedInteractive: [Bool] = []
        let expectation: XCTestExpectation?
        init(result: URLRescueCoordinator.RescueRunResult, available: Bool = true,
             expectation: XCTestExpectation? = nil) {
            self.result = result; self.available = available; self.expectation = expectation
        }
        convenience init(succeed: Bool, available: Bool = true, expectation: XCTestExpectation? = nil) {
            self.init(result: succeed ? .advanced : .notRecovered,
                      available: available, expectation: expectation)
        }
        func engine() -> URLRescueCoordinator.Engine {
            URLRescueCoordinator.Engine(
                isAvailable: { self.available },
                perform: { item, hint, interactive in
                    self.performedIDs.append(item.id)
                    self.performedHints.append(hint)
                    self.performedInteractive.append(interactive)
                    self.expectation?.fulfill()
                    return self.result
                })
        }
    }

    private func makeCoordinator() -> URLRescueCoordinator {
        URLRescueCoordinator(store: store, ledger: ledger, pending: pending)
    }

    private func failedItem() -> ReadingListItem {
        let item = store.add(urlString: "https://example.com/\(UUID().uuidString)")
        store.markFailed(item.id)
        return store.item(withID: item.id)!
    }

    func testManualRescueRunsForATappedItem() {
        let exp = expectation(description: "perform")
        let fake = RecordingEngine(succeed: true, expectation: exp)
        URLRescueCoordinator.engine = fake.engine()
        let coordinator = makeCoordinator()
        let item = failedItem()

        coordinator.requestManualRescue(itemID: item.id, hint: .article)
        wait(for: [exp], timeout: 2)
        XCTAssertEqual(fake.performedIDs, [item.id])
        XCTAssertEqual(fake.performedHints, [.article])
        XCTAssertTrueEventually { self.ledger.wasRescued(item.id) }
    }

    func testInlineFailureTriggersOneAttempt() {
        let exp = expectation(description: "perform")
        let fake = RecordingEngine(succeed: false, expectation: exp)
        URLRescueCoordinator.engine = fake.engine()
        let coordinator = makeCoordinator()
        let item = failedItem()

        coordinator.itemJustFailed(item.id, source: .manual, interactive: true)
        wait(for: [exp], timeout: 2)
        XCTAssertEqual(fake.performedIDs.count, 1)
        XCTAssertEqual(fake.performedInteractive, [true])
    }

    /// Non-interactive failures (extension saves, background sweeps) are left for
    /// the debounced sweep rather than rescued inline.
    func testNonInteractiveInlineFailureDoesNotTrigger() {
        let fake = RecordingEngine(succeed: false)
        URLRescueCoordinator.engine = fake.engine()
        let coordinator = makeCoordinator()
        let item = failedItem()

        coordinator.itemJustFailed(item.id, source: .shareSheet, interactive: false)
        // Give any errant task a moment.
        let waited = expectation(description: "settle")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { waited.fulfill() }
        wait(for: [waited], timeout: 2)
        XCTAssertTrue(fake.performedIDs.isEmpty, "a non-interactive failure must not rescue inline")
    }

    func testEngineUnavailableSkips() {
        let fake = RecordingEngine(succeed: true, available: false)
        URLRescueCoordinator.engine = fake.engine()
        let coordinator = makeCoordinator()
        let item = failedItem()
        coordinator.requestManualRescue(itemID: item.id, hint: .article)
        let waited = expectation(description: "settle")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { waited.fulfill() }
        wait(for: [waited], timeout: 2)
        XCTAssertTrue(fake.performedIDs.isEmpty)
    }

    func testDrainPendingFindsOrAddsAndPassesHint() {
        let exp = expectation(description: "perform")
        let fake = RecordingEngine(succeed: true, expectation: exp)
        URLRescueCoordinator.engine = fake.engine()
        let coordinator = makeCoordinator()

        pending.append(PendingRescueRequest(urlString: "https://new.example.com/x",
                                            hint: .media, dateWritten: Date()))
        coordinator.drainPendingRequests()
        wait(for: [exp], timeout: 2)
        XCTAssertEqual(fake.performedHints, [.media])
        XCTAssertNotNil(store.item(forURLString: "https://new.example.com/x"),
                        "a pending URL not yet in the store should be added")
    }

    // MARK: - Stage progress

    /// Nothing running ⇒ no fraction. The card uses nil to mean "no overlay".
    func testProgressIsNilBeforeAnyStageIsReported() {
        XCTAssertNil(makeCoordinator().rescueProgress(UUID()))
    }

    func testProgressFollowsTheReportedStage() {
        let coordinator = makeCoordinator()
        let id = UUID()
        coordinator.reportProgress(id, stage: .queued)
        let queued = coordinator.rescueProgress(id)
        coordinator.reportProgress(id, stage: .thinking)
        let thinking = coordinator.rescueProgress(id)

        XCTAssertNotNil(queued)
        XCTAssertNotNil(thinking)
        XCTAssertGreaterThan(thinking!, queued!)
        XCTAssertGreaterThanOrEqual(thinking!, RescueStage.thinking.fraction)
    }

    /// The bar must keep creeping through a long model call rather than freezing
    /// at the stage's own fraction — but never past the next stage.
    func testProgressCreepsWithinAStageWithoutOvershooting() {
        var clock = Date(timeIntervalSince1970: 1_000_000_000)
        let coordinator = URLRescueCoordinator(
            store: store, ledger: ledger, pending: pending, now: { clock })
        let id = UUID()
        coordinator.reportProgress(id, stage: .thinking)
        let atStart = coordinator.rescueProgress(id)!

        clock = clock.addingTimeInterval(10)
        let after10s = coordinator.rescueProgress(id)!
        clock = clock.addingTimeInterval(600)
        let wayLater = coordinator.rescueProgress(id)!

        XCTAssertEqual(atStart, RescueStage.thinking.fraction, accuracy: 0.001)
        XCTAssertGreaterThan(after10s, atStart)
        XCTAssertLessThan(wayLater, RescueStage.reading.fraction,
                          "creep must never reach the next stage on its own")
    }

    func testProgressReachesOneWhenFinished() {
        let coordinator = makeCoordinator()
        let id = UUID()
        coordinator.reportProgress(id, stage: .finished)
        XCTAssertEqual(coordinator.rescueProgress(id), 1.0)
    }

    /// The card listens for this rather than `.readingListChanged`, which would
    /// make every deck reload several times per rescue.
    func testProgressPostsItsOwnNotificationCarryingTheItemID() {
        let coordinator = makeCoordinator()
        let id = UUID()
        let exp = expectation(forNotification: .rescueProgressChanged, object: nil) { note in
            note.userInfo?[RescueProgressKey.itemID] as? UUID == id
        }
        coordinator.reportProgress(id, stage: .digesting)
        wait(for: [exp], timeout: 2)
    }

    /// The stage table has to stay monotonic, or the bar walks backwards.
    func testStageFractionsAreMonotonic() {
        let fractions = RescueStage.allCases.map(\.fraction)
        XCTAssertEqual(fractions, fractions.sorted())
        XCTAssertEqual(RescueStage.finished.fraction, 1.0)
    }

    // MARK: - Once-per-version AI attempt

    /// An update reopens every card whose AI attempt was spent under an older
    /// version, by clearing the ledger budget that would otherwise block the
    /// automatic half of the retry.
    func testStaleVersionAttemptsAreReopenedAtInstall() {
        let failures = SaveFailureStore(containerURL: tempDir)
        let item = failedItem()
        failures.recordAIAttempt(item.id, version: "0.9 (1)")
        ledger.recordAttempt(item.id, hint: nil)
        ledger.recordAttempt(item.id, hint: nil)
        XCTAssertFalse(ledger.shouldAutoRescue(item.id))

        let coordinator = URLRescueCoordinator(
            store: store, ledger: ledger, pending: pending, failures: failures)
        XCTAssertEqual(coordinator.reopenStaleVersionAttempts(), [item.id])
        XCTAssertTrue(ledger.shouldAutoRescue(item.id))
    }

    /// An attempt spent under the RUNNING version stays spent — that's the whole
    /// point of the terminal state.
    func testCurrentVersionAttemptsAreNotReopened() {
        let failures = SaveFailureStore(containerURL: tempDir)
        let item = failedItem()
        failures.recordAIAttempt(item.id)
        let coordinator = URLRescueCoordinator(
            store: store, ledger: ledger, pending: pending, failures: failures)
        XCTAssertTrue(coordinator.reopenStaleVersionAttempts().isEmpty)
    }

    /// A card-initiated rescue that fails spends the version's attempt; one that
    /// succeeds leaves nothing behind (the record is cleared when the item
    /// reaches `.ready`).
    func testAFailedManualRescueSpendsTheVersionAttempt() {
        let failures = SaveFailureStore(containerURL: tempDir)
        let exp = expectation(description: "perform")
        let fake = RecordingEngine(succeed: false, expectation: exp)
        URLRescueCoordinator.engine = fake.engine()
        let coordinator = URLRescueCoordinator(
            store: store, ledger: ledger, pending: pending, failures: failures)
        let item = failedItem()

        coordinator.requestManualRescue(itemID: item.id, hint: nil)
        wait(for: [exp], timeout: 2)
        XCTAssertTrueEventually { failures.hasSpentAIAttempt(item.id) }
    }

    func testASucceedingManualRescueDoesNotSpendTheVersionAttempt() {
        let failures = SaveFailureStore(containerURL: tempDir)
        let exp = expectation(description: "perform")
        let fake = RecordingEngine(succeed: true, expectation: exp)
        URLRescueCoordinator.engine = fake.engine()
        let coordinator = URLRescueCoordinator(
            store: store, ledger: ledger, pending: pending, failures: failures)
        let item = failedItem()

        coordinator.requestManualRescue(itemID: item.id, hint: nil)
        wait(for: [exp], timeout: 2)
        XCTAssertTrueEventually { self.ledger.wasRescued(item.id) }
        XCTAssertFalse(failures.hasSpentAIAttempt(item.id))
    }

    /// The AUTOMATIC sweep must not burn the user's one visible attempt — the
    /// button is theirs to press.
    /// The model never saw the page — assets downloading, another request holding
    /// the session — so the user's one visible attempt must survive it.
    func testATransientModelFailureDoesNotSpendTheVersionAttempt() {
        let failures = SaveFailureStore(containerURL: tempDir)
        let exp = expectation(description: "perform")
        let fake = RecordingEngine(result: .transient, expectation: exp)
        URLRescueCoordinator.engine = fake.engine()
        let coordinator = URLRescueCoordinator(
            store: store, ledger: ledger, pending: pending, failures: failures)
        let item = failedItem()

        coordinator.requestManualRescue(itemID: item.id, hint: nil)
        wait(for: [exp], timeout: 2)
        settle()
        XCTAssertFalse(failures.hasSpentAIAttempt(item.id))
    }

    /// The rescue DID recover the content; this app's surface dropped it on the
    /// way in. That is not the user's attempt to lose either.
    func testASurfaceDroppedRescueDoesNotSpendTheVersionAttempt() {
        let failures = SaveFailureStore(containerURL: tempDir)
        let exp = expectation(description: "perform")
        let fake = RecordingEngine(result: .surfaceDropped, expectation: exp)
        URLRescueCoordinator.engine = fake.engine()
        let coordinator = URLRescueCoordinator(
            store: store, ledger: ledger, pending: pending, failures: failures)
        let item = failedItem()

        coordinator.requestManualRescue(itemID: item.id, hint: nil)
        wait(for: [exp], timeout: 2)
        settle()
        XCTAssertFalse(failures.hasSpentAIAttempt(item.id))
    }

    // MARK: - Guardrail permanence

    /// A guardrail is a verdict on the prompt, and the prompt is derived from the
    /// page: the same page trips it every time. The ledger is what makes that
    /// permanent.
    func testAGuardrailedRescueMarksTheItemPermanentlyBlocked() {
        let exp = expectation(description: "perform")
        let fake = RecordingEngine(result: .guardrailed, expectation: exp)
        URLRescueCoordinator.engine = fake.engine()
        let coordinator = makeCoordinator()
        let item = failedItem()

        coordinator.requestManualRescue(itemID: item.id, hint: nil)
        wait(for: [exp], timeout: 2)
        XCTAssertTrueEventually { self.ledger.isGuardrailed(item.id) }
        XCTAssertFalse(ledger.shouldAutoRescue(item.id), "no automatic retry either")
    }

    /// …and no later tap may spend 90 seconds re-proving it.
    func testAGuardrailedItemIsNeverAttemptedAgain() {
        ledger.recordGuardrail(UUID())   // an unrelated row must not matter
        let fake = RecordingEngine(succeed: false)
        URLRescueCoordinator.engine = fake.engine()
        let coordinator = makeCoordinator()
        let item = failedItem()
        ledger.recordGuardrail(item.id)

        coordinator.requestManualRescue(itemID: item.id, hint: nil)
        settle()
        XCTAssertTrue(fake.performedIDs.isEmpty)
    }

    /// An app update reopens a spent VERSION attempt, because Luna's extraction
    /// code changed. It does not reopen a guardrail, because Apple's safety model
    /// didn't.
    func testAnUpdateDoesNotReopenAGuardrailedItem() {
        let failures = SaveFailureStore(containerURL: tempDir)
        let item = failedItem()
        failures.recordAIAttempt(item.id, version: "0.9 (1)")
        ledger.recordGuardrail(item.id)

        let coordinator = URLRescueCoordinator(
            store: store, ledger: ledger, pending: pending, failures: failures)
        coordinator.reopenStaleVersionAttempts()
        XCTAssertFalse(ledger.shouldAutoRescue(item.id))
    }

    private func settle(_ interval: TimeInterval = 0.3) {
        let waited = expectation(description: "settle")
        DispatchQueue.main.asyncAfter(deadline: .now() + interval) { waited.fulfill() }
        wait(for: [waited], timeout: 2)
    }

    func testAnAutomaticRescueDoesNotSpendTheVersionAttempt() {
        let failures = SaveFailureStore(containerURL: tempDir)
        let exp = expectation(description: "perform")
        let fake = RecordingEngine(succeed: false, expectation: exp)
        URLRescueCoordinator.engine = fake.engine()
        let coordinator = URLRescueCoordinator(
            store: store, ledger: ledger, pending: pending, failures: failures)
        let item = failedItem()

        coordinator.itemJustFailed(item.id, source: .shareSheet, interactive: true)
        wait(for: [exp], timeout: 2)
        XCTAssertFalse(failures.hasSpentAIAttempt(item.id))
    }
}

// MARK: - Test helpers

private extension XCTestCase {
    func XCTAssertTrueEventually(timeout: TimeInterval = 1, _ predicate: @escaping () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertTrue(predicate())
    }
}
