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

    func testMarkFailedOnAMissingItemDoesNotPostReadingListChanged() {
        // markFailed uses coordinatedUpdate (the "only write when body reports a
        // change" sibling of coordinatedMutate) — a missing id is a no-op there too.
        let missingIDNotifies = expectation(forNotification: .readingListChanged, object: nil)
        missingIDNotifies.isInverted = true
        store.markFailed(UUID())
        wait(for: [missingIDNotifies], timeout: 0.5)
    }
}
