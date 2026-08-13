//
//  SavesStoreCacheTests.swift
//  LunaTests
//
//  SavesStore serves items() from an in-memory list validated against
//  `PRAGMA data_version`, and skips the row write + notification when a mutation
//  doesn't actually change anything.
//

import LunaStorage
import LunaModels
import XCTest

final class SavesStoreCacheTests: XCTestCase {

    private var scratchDirectory: URL!
    private var store: SavesStore!

    override func setUp() {
        super.setUp()
        scratchDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SavesStoreCacheTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratchDirectory, withIntermediateDirectories: true)
        store = SavesStore(containerURL: scratchDirectory)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: scratchDirectory)
        super.tearDown()
    }

    // MARK: - Cache coherence: another connection's commit invalidates the cache

    /// `postChanged()` dispatches the notification `async` on the main queue —
    /// every test that triggers a genuine (notifying) mutation waits for it
    /// here so the dispatch is fully drained before the test returns. Without
    /// this, a still-pending post can bleed into a LATER test's inverted
    /// "must not notify" expectation (`NotificationCenter.default` is process-
    /// global, not scoped per test method).
    @discardableResult
    private func addAndWaitForNotification(_ urlString: String) -> SavedItem {
        let notified = expectation(forNotification: .savesChanged, object: nil)
        let item = store.add(urlString: urlString)
        wait(for: [notified], timeout: 2)
        return item
    }

    /// Both halves of the cache contract over one seeded store: repeated reads
    /// with nothing else happening stay consistent, and a second store instance
    /// on the same directory — a separate connection, which is what another
    /// process is — has its commit picked up without any notification.
    func testAnotherConnectionsCommitInvalidatesTheCacheAndTheCacheServesReadsOtherwise() {
        addAndWaitForNotification("https://example.com/a")
        XCTAssertEqual(store.items().map(\.urlString), ["https://example.com/a"])

        // Nothing has committed in between, so repeated reads must stay
        // consistent with each other (SavedItem is a value type, so this
        // compares by value).
        XCTAssertEqual(store.items(), store.items())

        // A second process (the SaveLink intent, an extension) writes the shared
        // database through its own connection.
        let sibling = SavesStore(containerURL: scratchDirectory)
        sibling.add(urlString: "https://example.com/b")

        XCTAssertEqual(Set(store.items().map(\.urlString)),
                       ["https://example.com/a", "https://example.com/b"],
                       "another connection's commit must invalidate the in-process list")
    }

    // MARK: - Skip-write-when-unchanged

    /// The two no-op mutation paths — a duplicate `add` and `markFailed` on an id
    /// that isn't there — share ONE inverted expectation, so proving "neither
    /// notifies" costs one 0.5s window rather than two.
    func testNoOpMutationsNeitherNotifyNorWriteARow() {
        addAndWaitForNotification("https://example.com/dup")
        let rowsWrittenAfterFirstSave = store.writtenRowCountForTesting

        let mustNotNotify = expectation(forNotification: .savesChanged, object: nil)
        mustNotNotify.isInverted = true
        // A second add for the SAME url returns the existing item without
        // inserting; markFailed for a missing id is the same no-op on the
        // targeted-setter side.
        _ = store.add(urlString: "https://example.com/dup")
        store.markFailed(UUID())
        wait(for: [mustNotNotify], timeout: 0.5)

        XCTAssertEqual(store.items().count, 1, "the duplicate add must not have inserted a second row")
        XCTAssertEqual(store.writtenRowCountForTesting, rowsWrittenAfterFirstSave,
                       "a no-op mutation must skip the write entirely, not rewrite identical values")
    }

    // MARK: - Atomic save-attempt reservation

    /// The reservation's three timing rules in one pass: the initial state is
    /// durable immediately, completion extends the window from the END (and a
    /// late callback can't shorten it), and an overlapping run can't move the
    /// marker backward.
    func testSaveAttemptTimingIsDurableImmediatelyAndOnlyEverMovesForward() {
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let first = store.reserveSaveAttempt(
            urlString: "https://example.com/intent", source: .appIntent, at: startedAt)

        XCTAssertTrue(first.wasAdded)
        XCTAssertNil(first.previousPressDate)
        XCTAssertEqual(first.item.dateAdded, startedAt)
        XCTAssertEqual(first.item.lastSaveAttemptDate, startedAt)
        XCTAssertEqual(first.item.captureSource, .appIntent)
        XCTAssertEqual(store.item(withID: first.item.id)?.dateAdded, startedAt)
        XCTAssertEqual(store.item(withID: first.item.id)?.lastSaveAttemptDate, startedAt)

        // An overlapping reservation of the SAME url, stamped earlier, reuses
        // the row and leaves the marker where the later start put it.
        let earlierStart = startedAt.addingTimeInterval(-0.25)
        let overlapping = store.reserveSaveAttempt(
            urlString: first.item.urlString, source: .appIntent, at: earlierStart)
        XCTAssertFalse(overlapping.wasAdded)
        XCTAssertEqual(overlapping.item.id, first.item.id)
        XCTAssertEqual(overlapping.previousPressDate, startedAt)
        XCTAssertEqual(store.item(withID: first.item.id)?.lastSaveAttemptDate, startedAt)

        // Completion extends the durable window from the end...
        let completedAt = startedAt.addingTimeInterval(18)
        store.finishSaveAttempt(for: first.item.id, at: completedAt)
        XCTAssertEqual(store.item(withID: first.item.id)?.lastSaveAttemptDate, completedAt)

        // ...and a delayed callback carrying an older time cannot shorten it.
        store.finishSaveAttempt(for: first.item.id, at: startedAt.addingTimeInterval(4))
        XCTAssertEqual(store.item(withID: first.item.id)?.lastSaveAttemptDate, completedAt)
    }

    func testConcurrentSaveAttemptReservationsAddOneItem() {
        let urlString = "https://example.com/concurrent-intent"
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let stores = (0..<12).map { _ in SavesStore(containerURL: scratchDirectory) }
        let resultLock = NSLock()
        var reservations: [SavesStore.SaveAttemptReservation] = []
        let completion = expectation(description: "all reservations finished")
        completion.expectedFulfillmentCount = stores.count

        for concurrentStore in stores {
            DispatchQueue.global(qos: .userInitiated).async {
                let reservation = concurrentStore.reserveSaveAttempt(
                    urlString: urlString, source: .appIntent, at: startedAt)
                resultLock.lock()
                reservations.append(reservation)
                resultLock.unlock()
                completion.fulfill()
            }
        }
        wait(for: [completion], timeout: 10)

        XCTAssertEqual(reservations.filter(\.wasAdded).count, 1)
        XCTAssertEqual(Set(reservations.map(\.item.id)).count, 1)
        XCTAssertEqual(store.items().filter { $0.urlString == urlString }.count, 1)

        // Drain the async saves notifications before the test returns.
        let notificationsDrained = expectation(description: "notifications drained")
        DispatchQueue.main.async { notificationsDrained.fulfill() }
        wait(for: [notificationsDrained], timeout: 2)
    }

    func testArchivingRoundTripsAndReleasesRecursivePreloadOwnership() throws {
        let preloadStore = PreloadStore(containerURL: scratchDirectory)
        store = SavesStore(containerURL: scratchDirectory, preloadStore: preloadStore)
        let item = addAndWaitForNotification("https://example.com/root")
        let descendant = try XCTUnwrap(URL(string: "https://example.com/child"))
        preloadStore.record(url: descendant, rootID: item.id, kind: .unrepresentable)
        XCTAssertEqual(preloadStore.entry(for: descendant)?.owners, [item.id.uuidString])

        let archived = expectation(forNotification: .savesChanged, object: nil)
        store.setArchived(true, for: item.id, at: Date(timeIntervalSince1970: 123))
        wait(for: [archived], timeout: 2)

        XCTAssertEqual(store.item(withID: item.id)?.archivedAt, Date(timeIntervalSince1970: 123))
        XCTAssertNil(preloadStore.entry(for: descendant), "archive drops this root's preload tree")

        let unarchived = expectation(forNotification: .savesChanged, object: nil)
        store.setArchived(false, for: item.id)
        wait(for: [unarchived], timeout: 2)
        XCTAssertNil(store.item(withID: item.id)?.archivedAt)
    }

    /// The whole finish → pending → committed → unread lifecycle in one pass:
    /// the two halves used to repeat the same finish-and-commit setup, one
    /// notification round trip each.
    func testFinishStaysActiveUntilCommittedAndMarkUnreadClearsBothArchiveMarks() {
        let item = addAndWaitForNotification("https://example.com/finish-later")
        let finishedAt = Date(timeIntervalSince1970: 456)

        let finished = expectation(forNotification: .savesChanged, object: nil)
        store.markFinishedReading(item.id, at: finishedAt)
        wait(for: [finished], timeout: 2)

        let pending = store.item(withID: item.id)
        XCTAssertEqual(pending?.readState, .read)
        XCTAssertEqual(pending?.readingProgress, 1)
        XCTAssertEqual(pending?.pendingArchiveAt, finishedAt)
        XCTAssertNil(pending?.archivedAt, "completion must not remove the foreground card")

        let archived = expectation(forNotification: .savesChanged, object: nil)
        store.archivePendingFinishedItems()
        wait(for: [archived], timeout: 2)

        let committed = store.item(withID: item.id)
        XCTAssertNil(committed?.pendingArchiveAt)
        XCTAssertEqual(committed?.archivedAt, finishedAt)

        // Marking unread from the committed state clears BOTH marks and bumps.
        let unarchived = expectation(forNotification: .savesChanged, object: nil)
        let unarchivedAt = Date(timeIntervalSince1970: 789)
        store.markUnread(item.id, at: unarchivedAt)
        wait(for: [unarchived], timeout: 2)

        let restored = store.item(withID: item.id)
        XCTAssertEqual(restored?.readState, .unopened)
        XCTAssertNil(restored?.archivedAt)
        XCTAssertNil(restored?.pendingArchiveAt)
        XCTAssertEqual(restored?.bumpDate, unarchivedAt)
    }
}
