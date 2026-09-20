//
//  URLRescueCoordinatorTests.swift
//  LunaTests
//

import XCTest
import LunaModels
import LunaStorage
@testable import LunaSaves

final class URLRescueCoordinatorTests: XCTestCase {
    private var tempDir: URL!
    private var store: SavesStore!
    private var ledger: RescueLedgerStore!
    private var pending: PendingRescueRequestStore!
    private var savedEngine: (any URLRescueEngineBridging)?

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        store = SavesStore(containerURL: tempDir)
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
    ///
    /// A rescue starts on an unstructured `Task`, so every test here POLLS for
    /// the call rather than pumping a fixed duration: under a full suite the
    /// cooperative pool can take longer to pick the task up than any one number
    /// would survive.
    private final class RecordingEngine: URLRescueEngineBridging {
        var result: URLRescueCoordinator.RescueRunResult
        var available: Bool
        private let lock = NSLock()
        private var performed: [UUID] = []

        init(result: URLRescueCoordinator.RescueRunResult, available: Bool = true) {
            self.result = result
            self.available = available
        }
        convenience init(succeed: Bool, available: Bool = true) {
            self.init(result: succeed ? .advanced : .notRecovered, available: available)
        }

        var performedIDs: [UUID] {
            lock.lock(); defer { lock.unlock() }
            return performed
        }

        var isRescueAvailable: Bool { available }

        func performRescue(for item: SavedItem) async -> URLRescueCoordinator.RescueRunResult {
            lock.lock()
            performed.append(item.id)
            lock.unlock()
            return result
        }
    }

    private func makeCoordinator() -> URLRescueCoordinator {
        URLRescueCoordinator(store: store, ledger: ledger, pending: pending)
    }

    private func failedItem() -> SavedItem {
        let item = store.add(urlString: "https://example.com/\(UUID().uuidString)")
        store.markFailed(item.id)
        return store.item(withID: item.id)!
    }

    /// Apple Intelligence looks once. A failure runs it; the item's next
    /// failure finds the budget spent and runs nothing.
    func testAFailureRunsExactlyOneAutomaticAttemptEver() {
        let fake = RecordingEngine(succeed: false)
        URLRescueCoordinator.engine = fake
        let coordinator = makeCoordinator()
        let item = failedItem()

        coordinator.itemJustFailed(item.id, source: .manual)
        waitUntil { fake.performedIDs == [item.id] }
        XCTAssertFalse(ledger.shouldAutoRescue(item.id))

        coordinator.itemJustFailed(item.id, source: .manual)
        settle()
        XCTAssertEqual(fake.performedIDs.count, 1, "the one attempt is spent")
    }

    /// The extension's failure leg queues without asking, so a save that failed
    /// while the app was closed gets its attempt on the next foreground — with
    /// no tap anywhere.
    func testAQueuedExtensionFailureIsRescuedWithoutATap() {
        let fake = RecordingEngine(succeed: true)
        URLRescueCoordinator.engine = fake
        let coordinator = makeCoordinator()

        pending.append(PendingRescueRequest(
            urlString: "https://new.example.com/x", dateWritten: Date()))
        coordinator.drainPendingRequests()
        waitUntil { fake.performedIDs.count == 1 }
        XCTAssertNotNil(store.item(forURLString: "https://new.example.com/x"),
                        "a pending URL not yet in the store should be added")
    }

    /// A queued hand-off for an item that already spent its attempt runs
    /// nothing: the queue is a trigger, not a second budget.
    func testADrainedRequestRespectsTheSpentBudget() {
        let fake = RecordingEngine(succeed: false)
        URLRescueCoordinator.engine = fake
        let coordinator = makeCoordinator()
        let item = failedItem()
        ledger.recordAttempt(item.id)

        pending.append(PendingRescueRequest(
            urlString: item.urlString, dateWritten: Date()))
        coordinator.drainPendingRequests()
        settle()
        XCTAssertTrue(fake.performedIDs.isEmpty)
    }

    func testEngineUnavailableSkips() {
        let fake = RecordingEngine(succeed: true, available: false)
        URLRescueCoordinator.engine = fake
        let coordinator = makeCoordinator()
        let item = failedItem()
        coordinator.itemJustFailed(item.id, source: .manual)
        settle()
        XCTAssertTrue(fake.performedIDs.isEmpty)
    }

    func testASuccessfulRescueIsRecordedAsProvenance() {
        let fake = RecordingEngine(succeed: true)
        URLRescueCoordinator.engine = fake
        let coordinator = makeCoordinator()
        let item = failedItem()

        coordinator.itemJustFailed(item.id, source: .manual)
        waitUntil { self.ledger.wasRescued(item.id) }
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

    /// The card listens for this rather than `.savesChanged`, which would
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

    // MARK: - Guardrail permanence

    /// A guardrail is a verdict on the prompt, and the prompt is derived from the
    /// page: the same page trips it every time. The ledger is what makes that
    /// permanent.
    func testAGuardrailedRescueMarksTheItemPermanentlyBlocked() {
        let fake = RecordingEngine(result: .guardrailed)
        URLRescueCoordinator.engine = fake
        let coordinator = makeCoordinator()
        let item = failedItem()

        coordinator.itemJustFailed(item.id, source: .manual)
        waitUntil { self.ledger.isGuardrailed(item.id) }
        XCTAssertFalse(ledger.shouldAutoRescue(item.id), "no automatic retry either")
    }

    /// …and a queued hand-off may not spend 90 seconds re-proving it either.
    func testAGuardrailedItemIsNeverAttemptedAgain() {
        ledger.recordGuardrail(UUID())   // an unrelated row must not matter
        let fake = RecordingEngine(succeed: false)
        URLRescueCoordinator.engine = fake
        let coordinator = makeCoordinator()
        let item = failedItem()
        ledger.recordGuardrail(item.id)

        pending.append(PendingRescueRequest(
            urlString: item.urlString, dateWritten: Date()))
        coordinator.drainPendingRequests()
        settle()
        XCTAssertTrue(fake.performedIDs.isEmpty)
    }

    /// Pumps the run loop so anything already scheduled gets its turn. Used
    /// only to assert that something does NOT happen.
    private func settle(_ interval: TimeInterval = 0.5) {
        RunLoop.current.run(until: Date().addingTimeInterval(interval))
    }

    /// Pumps until `predicate` holds, or fails the test at the deadline.
    private func waitUntil(
        timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line,
        _ predicate: @escaping () -> Bool
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        XCTFail("condition never held within \(timeout)s", file: file, line: line)
    }
}

