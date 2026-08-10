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

    // MARK: - The hand-off's two paths

    private func handoffRecord(
        urlString: String, title: String?, creator: String? = nil
    ) -> ResolvedMediaRecord {
        ResolvedMediaRecord(
            sourceURLString: urlString, title: title,
            assets: [MediaAsset(
                url: URL(string: "https://cdn.example.com/video.mp4")!, kind: .video)],
            dateWritten: Date(), creator: creator)
    }

    /// The normal path: the extension resolved this post to render its player,
    /// so the record already carries the metadata and the row is finished from
    /// it — no network round trip, and nothing left owed.
    @MainActor
    func testHandoffWithMetadataFinishesTheRowWithoutAFetch() throws {
        // 11 characters, because that is what a YouTube id is and
        // `PlatformRecognizer` checks.
        let videoID = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(11))
        let store = ReadingListStore(containerURL: scratch)
        let queue = completions()
        let saved = PendingResolvedMediaDownloads.persistSave(
            for: handoffRecord(urlString: "https://www.youtube.com/watch?v=\(videoID)",
                               title: "A resolved clip", creator: "Blender"),
            store: store, completions: queue)
        let item = try XCTUnwrap(store.item(forURLString: saved))

        XCTAssertEqual(item.state, .ready)
        XCTAssertEqual(item.title, "A resolved clip")
        XCTAssertEqual(item.channelName, "Blender")
        XCTAssertEqual(item.platform, .youtube)
        XCTAssertEqual(item.platformItemID, videoID)
        XCTAssertTrue(queue.owed().isEmpty)
    }

    /// A page that states no author leaves the row's creator EMPTY. The hand-off
    /// path never invents one from a title or a site name, and never goes to the
    /// network to find one — that is what keeps it a no-fetch path.
    @MainActor
    func testHandoffWithNoAuthorLeavesTheCreatorEmpty() throws {
        let videoID = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(11))
        let store = ReadingListStore(containerURL: scratch)
        let queue = completions()
        let saved = PendingResolvedMediaDownloads.persistSave(
            for: handoffRecord(urlString: "https://www.youtube.com/watch?v=\(videoID)",
                               title: "A resolved clip", creator: nil),
            store: store, completions: queue)
        let item = try XCTUnwrap(store.item(forURLString: saved))

        XCTAssertEqual(item.state, .ready)
        XCTAssertNil(item.channelName)
    }

    /// The fallback: the resolve had not finished when Download was pressed, so
    /// the record carries no metadata. The row is reserved `.pending` and its
    /// ingest is OWED — which is what the background pass pays off, with no
    /// manual launch.
    @MainActor
    func testIncompleteHandoffLeavesTheRowOwedForTheBackgroundIngest() throws {
        let videoID = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(11))
        let store = ReadingListStore(containerURL: scratch)
        let queue = completions()
        let saved = PendingResolvedMediaDownloads.persistSave(
            for: handoffRecord(urlString: "https://www.youtube.com/watch?v=\(videoID)",
                               title: nil),
            store: store, completions: queue)
        let item = try XCTUnwrap(store.item(forURLString: saved))

        XCTAssertEqual(item.state, .pending)
        XCTAssertEqual(queue.owed().map(\.itemID), [item.id])
        XCTAssertEqual(queue.owed().first?.urlString, saved)
    }

    /// A URL no platform rule recognizes has no `platform`/`platformItemID` to
    /// write, so however good its title is it still goes through the classifying
    /// pipeline rather than being guessed at here.
    @MainActor
    func testHandoffForAnUnrecognizedHostStaysOwed() throws {
        let store = ReadingListStore(containerURL: scratch)
        let queue = completions()
        let saved = PendingResolvedMediaDownloads.persistSave(
            for: handoffRecord(urlString: "https://example.org/clips/a-clip",
                               title: "A resolved clip"),
            store: store, completions: queue)
        let item = try XCTUnwrap(store.item(forURLString: saved))

        XCTAssertEqual(item.state, .pending)
        XCTAssertEqual(queue.owed().map(\.itemID), [item.id])
    }
}
