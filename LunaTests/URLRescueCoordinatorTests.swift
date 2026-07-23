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
    private var savedToggle: Bool!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        store = ReadingListStore(containerURL: tempDir)
        ledger = RescueLedgerStore(containerURL: tempDir)
        pending = PendingRescueRequestStore(defaults: UserDefaults(suiteName: "test.\(UUID().uuidString)")!)
        savedEngine = URLRescueCoordinator.engine
        savedToggle = RescueSettings.isAutoRescueEnabled
    }

    override func tearDown() {
        URLRescueCoordinator.engine = savedEngine
        RescueSettings.isAutoRescueEnabled = savedToggle
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    /// A fake engine recording each perform call; returns a configurable result.
    private final class RecordingEngine {
        var succeed: Bool
        var available: Bool
        private(set) var performedIDs: [UUID] = []
        private(set) var performedHints: [RescueHint?] = []
        private(set) var performedInteractive: [Bool] = []
        let expectation: XCTestExpectation?
        init(succeed: Bool, available: Bool = true, expectation: XCTestExpectation? = nil) {
            self.succeed = succeed; self.available = available; self.expectation = expectation
        }
        func engine() -> URLRescueCoordinator.Engine {
            URLRescueCoordinator.Engine(
                isAvailable: { self.available },
                perform: { item, hint, interactive in
                    self.performedIDs.append(item.id)
                    self.performedHints.append(hint)
                    self.performedInteractive.append(interactive)
                    self.expectation?.fulfill()
                    return self.succeed
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

    func testManualRescueRunsEvenWithToggleOff() {
        RescueSettings.isAutoRescueEnabled = false
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

    func testInlineFailureWithToggleOnTriggersOneAttempt() {
        RescueSettings.isAutoRescueEnabled = true
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

    func testInlineFailureWithToggleOffDoesNotTrigger() {
        RescueSettings.isAutoRescueEnabled = false
        let fake = RecordingEngine(succeed: false)
        URLRescueCoordinator.engine = fake.engine()
        let coordinator = makeCoordinator()
        let item = failedItem()

        coordinator.itemJustFailed(item.id, source: .manual, interactive: true)
        // Give any errant task a moment.
        let waited = expectation(description: "settle")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { waited.fulfill() }
        wait(for: [waited], timeout: 2)
        XCTAssertTrue(fake.performedIDs.isEmpty, "toggle off must not auto-rescue")
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
