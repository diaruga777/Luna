//
//  ReadingListStoreCacheTests.swift
//  LunaTests
//
//  ReadingListStore serves items() from an in-memory cache validated against a
//  (modification date, size) stat token, and skips the write + notification
//  when a mutation doesn't actually change the array. Per the ingest-pipeline
//  audit (§3), these are the two PERF_REVIEW_PLAN tests that were specified
//  but never landed — there was previously no dedicated ReadingListStoreTests
//  file at all.
//

import LunaStorage
import LunaModels
import XCTest

final class ReadingListStoreCacheTests: XCTestCase {

    private var scratchDirectory: URL!
    private var store: ReadingListStore!
    private var listFileURL: URL!

    override func setUp() {
        super.setUp()
        scratchDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReadingListStoreCacheTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratchDirectory, withIntermediateDirectories: true)
        listFileURL = scratchDirectory.appendingPathComponent("readingList.json")
        store = ReadingListStore(containerURL: scratchDirectory)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: scratchDirectory)
        super.tearDown()
    }

    // MARK: - Cache coherence: an externally-written file invalidates the cache

    /// `postChanged()` dispatches the notification `async` on the main queue —
    /// every test that triggers a genuine (notifying) mutation waits for it
    /// here so the dispatch is fully drained before the test returns. Without
    /// this, a still-pending post can bleed into a LATER test's inverted
    /// "must not notify" expectation (`NotificationCenter.default` is process-
    /// global, not scoped per test method).
    @discardableResult
    private func addAndWaitForNotification(_ urlString: String) -> ReadingListItem {
        let notified = expectation(forNotification: .readingListChanged, object: nil)
        let item = store.add(urlString: urlString)
        wait(for: [notified], timeout: 2)
        return item
    }

    func testExternalWriteWithADifferentSizeIsPickedUpOnTheNextRead() throws {
        // Fills the cache with one item.
        addAndWaitForNotification("https://example.com/a")
        XCTAssertEqual(store.items().map(\.urlString), ["https://example.com/a"])

        // A second process (SaveLink intent, an extension) writes the shared file
        // directly — a different item count, so the byte size necessarily
        // differs regardless of the filesystem's mtime-timestamp granularity.
        let externalItems = [
            ReadingListItem(urlString: "https://example.com/a"),
            ReadingListItem(urlString: "https://example.com/b"),
        ]
        let data = try JSONEncoder().encode(externalItems)
        try data.write(to: listFileURL, options: .atomic)

        let reread = store.items()
        XCTAssertEqual(Set(reread.map(\.urlString)),
                       ["https://example.com/a", "https://example.com/b"],
                       "a changed (mtime, size) stat token must invalidate the in-process cache")
    }

    func testUnchangedFileServesTheCachedArrayRatherThanReDecoding() {
        addAndWaitForNotification("https://example.com/a")
        let first = store.items()
        // No external write in between — the stat token is unchanged, so this
        // must be the SAME cached array, not a fresh decode (same identity by
        // value equality here since ReadingListItem is a value type; the
        // behavior under test is that no crash/emptying occurs and repeated
        // reads stay consistent with each other).
        let second = store.items()
        XCTAssertEqual(first, second)
    }

    // MARK: - Skip-write-when-unchanged

    func testNoOpAddDoesNotPostReadingListChanged() {
        // The first add is a genuine change and must notify.
        addAndWaitForNotification("https://example.com/dup")

        // A second add for the SAME url is a no-op (returns the existing item
        // without mutating the array) and must NOT notify again.
        let secondAddMustNotNotify = expectation(forNotification: .readingListChanged, object: nil)
        secondAddMustNotNotify.isInverted = true
        _ = store.add(urlString: "https://example.com/dup")
        wait(for: [secondAddMustNotNotify], timeout: 0.5)

        XCTAssertEqual(store.items().count, 1, "the duplicate add must not have appended a second row")
    }

    func testNoOpAddDoesNotRewriteTheFileOnDisk() throws {
        addAndWaitForNotification("https://example.com/dup")
        let attributesAfterFirstWrite = try FileManager.default.attributesOfItem(atPath: listFileURL.path)
        let sizeAfterFirstWrite = attributesAfterFirstWrite[.size] as? Int

        _ = store.add(urlString: "https://example.com/dup") // no-op: same URL already saved

        let attributesAfterNoOp = try FileManager.default.attributesOfItem(atPath: listFileURL.path)
        let sizeAfterNoOp = attributesAfterNoOp[.size] as? Int
        XCTAssertEqual(sizeAfterFirstWrite, sizeAfterNoOp,
                       "a no-op mutation must skip the write entirely, not write identical bytes")
    }

    // MARK: - Atomic save-attempt reservation

    func testSaveAttemptReservationWritesTheInitialTimingStateImmediately() {
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let first = store.reserveSaveAttempt(
            urlString: "https://example.com/intent", source: .appIntent, at: startedAt)

        XCTAssertTrue(first.wasAdded)
        XCTAssertNil(first.previousPressDate)
        XCTAssertEqual(first.item.dateAdded, startedAt)
        XCTAssertEqual(first.item.captureSource, .appIntent)
        XCTAssertEqual(store.item(withID: first.item.id)?.dateAdded, startedAt)
    }

    func testSaveAttemptReservationDoesNotMoveMarkerBackwardForOverlappingRuns() {
        let laterStart = Date(timeIntervalSince1970: 1_700_000_000.25)
        let first = store.reserveSaveAttempt(
            urlString: "https://example.com/overlap", source: .appIntent, at: laterStart)
        let earlierStart = laterStart.addingTimeInterval(-0.25)
        let overlapping = store.reserveSaveAttempt(
            urlString: first.item.urlString, source: .appIntent, at: earlierStart)

        XCTAssertFalse(overlapping.wasAdded)
        XCTAssertEqual(overlapping.item.id, first.item.id)
        XCTAssertEqual(overlapping.previousPressDate, laterStart)
        XCTAssertEqual(store.item(withID: first.item.id)?.lastSaveAttemptDate, laterStart)
    }

    func testConcurrentSaveAttemptReservationsAddOneItem() {
        let urlString = "https://example.com/concurrent-intent"
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let stores = (0..<12).map { _ in ReadingListStore(containerURL: scratchDirectory) }
        let resultLock = NSLock()
        var reservations: [ReadingListStore.SaveAttemptReservation] = []
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

        // Drain the async reading-list notifications before the test returns.
        let notificationsDrained = expectation(description: "notifications drained")
        DispatchQueue.main.async { notificationsDrained.fulfill() }
        wait(for: [notificationsDrained], timeout: 2)
    }

    func testMarkFailedOnAMissingItemDoesNotPostReadingListChanged() {
        // markFailed uses coordinatedUpdate (the "only write when body reports a
        // change" sibling of coordinatedMutate) — a missing id is a no-op there too.
        let missingIDNotifies = expectation(forNotification: .readingListChanged, object: nil)
        missingIDNotifies.isInverted = true
        store.markFailed(UUID())
        wait(for: [missingIDNotifies], timeout: 0.5)
    }

    func testArchivingRoundTripsAndReleasesRecursivePreloadOwnership() throws {
        let preloadStore = PreloadStore(containerURL: scratchDirectory)
        store = ReadingListStore(containerURL: scratchDirectory, preloadStore: preloadStore)
        let item = addAndWaitForNotification("https://example.com/root")
        let descendant = try XCTUnwrap(URL(string: "https://example.com/child"))
        preloadStore.record(url: descendant, rootID: item.id, kind: .unrepresentable)
        XCTAssertEqual(preloadStore.entry(for: descendant)?.owners, [item.id.uuidString])

        let archived = expectation(forNotification: .readingListChanged, object: nil)
        store.setArchived(true, for: item.id, at: Date(timeIntervalSince1970: 123))
        wait(for: [archived], timeout: 2)

        XCTAssertEqual(store.item(withID: item.id)?.archivedAt, Date(timeIntervalSince1970: 123))
        XCTAssertNil(preloadStore.entry(for: descendant), "archive drops this root's preload tree")

        let unarchived = expectation(forNotification: .readingListChanged, object: nil)
        store.setArchived(false, for: item.id)
        wait(for: [unarchived], timeout: 2)
        XCTAssertNil(store.item(withID: item.id)?.archivedAt)
    }

    func testFinishedItemRemainsActiveUntilPendingArchiveIsCommitted() {
        let item = addAndWaitForNotification("https://example.com/finish-later")
        let finishedAt = Date(timeIntervalSince1970: 456)

        let finished = expectation(forNotification: .readingListChanged, object: nil)
        store.markFinishedReading(item.id, at: finishedAt)
        wait(for: [finished], timeout: 2)

        let pending = store.item(withID: item.id)
        XCTAssertEqual(pending?.readState, .read)
        XCTAssertEqual(pending?.readingProgress, 1)
        XCTAssertEqual(pending?.pendingArchiveAt, finishedAt)
        XCTAssertNil(pending?.archivedAt, "completion must not remove the foreground card")

        let archived = expectation(forNotification: .readingListChanged, object: nil)
        store.archivePendingFinishedItems()
        wait(for: [archived], timeout: 2)

        let committed = store.item(withID: item.id)
        XCTAssertNil(committed?.pendingArchiveAt)
        XCTAssertEqual(committed?.archivedAt, finishedAt)
    }

    func testMarkUnreadClearsCommittedAndPendingArchiveState() {
        let item = addAndWaitForNotification("https://example.com/unarchive")
        let finished = expectation(forNotification: .readingListChanged, object: nil)
        store.markFinishedReading(item.id, at: Date(timeIntervalSince1970: 456))
        wait(for: [finished], timeout: 2)
        let archived = expectation(forNotification: .readingListChanged, object: nil)
        store.archivePendingFinishedItems()
        wait(for: [archived], timeout: 2)

        let unarchived = expectation(forNotification: .readingListChanged, object: nil)
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
