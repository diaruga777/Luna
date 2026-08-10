//
//  BackgroundIngestCompletionTests.swift
//  LunaTests
//

@testable import LunaMediaDownload
import LunaModels
import LunaReadingList
import LunaStorage
import XCTest

/// The Safari Download hand-off leaves a RESERVED row behind and goes straight
/// back to the page; these cover the debt it records and the runner that pays
/// it off in the background.
final class BackgroundIngestCompletionTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!
    private var scratch: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "test.pendingIngestCompletions.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: scratch)
        try super.tearDownWithError()
    }

    private func completions(now: @escaping () -> Date = Date.init) -> PendingIngestCompletions {
        PendingIngestCompletions(defaults: defaults, now: now)
    }

    // MARK: - The debt

    /// An interrupted attempt must not lose the debt: only a row that actually
    /// left `.pending` settles it, so the queue survives a run that recorded an
    /// attempt and never finished.
    func testRecordedAttemptLeavesTheDebtOwedUntilItIsSettled() {
        let queue = completions()
        let id = UUID()
        queue.owe(itemID: id, urlString: "https://x.com/luna/status/1")
        queue.recordAttempt(id)

        XCTAssertEqual(queue.owed().map(\.itemID), [id])
        XCTAssertEqual(queue.owed().first?.attempts, 1)

        queue.settle(id)
        XCTAssertTrue(queue.owed().isEmpty)
    }

    /// A second hand-off for the same page must not reset the debt's history —
    /// otherwise a row that keeps being re-queued looks like a first attempt
    /// forever.
    func testRepeatedHandoffKeepsTheOriginalDebt() {
        let queue = completions()
        let id = UUID()
        queue.owe(itemID: id, urlString: "https://x.com/luna/status/1")
        queue.recordAttempt(id)
        queue.owe(itemID: id, urlString: "https://x.com/luna/status/1")

        XCTAssertEqual(queue.owed().count, 1)
        XCTAssertEqual(queue.owed().first?.attempts, 1)
    }

    /// Past the lifetime the queue hands the row back to the ordinary pending
    /// sweep rather than retrying it forever.
    func testDebtOlderThanTheLifetimeIsDropped() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var now = start
        let queue = completions(now: { now })
        queue.owe(itemID: UUID(), urlString: "https://x.com/luna/status/1")

        now = start.addingTimeInterval(PendingIngestCompletions.lifetime - 60)
        XCTAssertEqual(queue.owed().count, 1)

        now = start.addingTimeInterval(PendingIngestCompletions.lifetime + 60)
        XCTAssertTrue(queue.owed().isEmpty)
    }

    // MARK: - Paying it off

    /// The launch sweep, a rescue, or an earlier run may have finished the row
    /// already; the runner must then settle the debt instead of re-ingesting a
    /// finished save.
    func testRunSettlesARowThatAlreadyReachedAVerdict() throws {
        let store = ReadingListStore(containerURL: scratch)
        let item = store.add(urlString: "https://x.com/luna/status/1")
        _ = store.savePlatformMetadata(
            platform: .x, platformItemID: "1", title: "A post", creator: nil,
            thumbnailFileName: nil, for: item.id)
        XCTAssertEqual(store.item(withID: item.id)?.state, .ready)
        let queue = completions()
        queue.owe(itemID: item.id, urlString: item.urlString)

        let finished = expectation(description: "queue worked")
        BackgroundIngestCompletion.run(
            store: store, completions: queue,
            ingestor: ReadingListIngestor(store: store)) { finished.fulfill() }
        wait(for: [finished], timeout: 5)

        XCTAssertTrue(queue.owed().isEmpty)
    }

    /// A row the surface gate discarded (or a tracker merge deleted) is gone
    /// from the store entirely — nothing is owed for it any more.
    func testRunSettlesADebtWhoseRowNoLongerExists() {
        let store = ReadingListStore(containerURL: scratch)
        let queue = completions()
        queue.owe(itemID: UUID(), urlString: "https://x.com/luna/status/1")

        let finished = expectation(description: "queue worked")
        BackgroundIngestCompletion.run(
            store: store, completions: queue,
            ingestor: ReadingListIngestor(store: store)) { finished.fulfill() }
        wait(for: [finished], timeout: 5)

        XCTAssertTrue(queue.owed().isEmpty)
    }

    // MARK: - The hand-off records one

    /// The load-bearing wiring: the Safari drain's synchronous half reserves the
    /// row AND owes its metadata pass, so nothing waits for a manual launch.
    @MainActor
    func testResolvedMediaHandoffOwesTheReservedRowsIngest() throws {
        let urlString = "https://www.youtube.com/watch?v=\(UUID().uuidString.prefix(8))"
        let record = ResolvedMediaRecord(
            sourceURLString: urlString, title: nil,
            assets: [MediaAsset(
                url: URL(string: "https://cdn.example.com/video.mp4")!, kind: .video)],
            dateWritten: Date())

        let saved = PendingResolvedMediaDownloads.persistSave(for: record)
        let item = try XCTUnwrap(ReadingListStore.shared.item(forURLString: saved))
        defer {
            PendingIngestCompletions.shared.settle(item.id)
            ReadingListStore.shared.delete(item)
        }

        XCTAssertEqual(item.state, .pending)
        XCTAssertTrue(PendingIngestCompletions.shared.owed().contains {
            $0.itemID == item.id && $0.urlString == saved
        })
    }
}
