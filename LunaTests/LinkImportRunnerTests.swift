//
//  LinkImportRunnerTests.swift
//  LunaTests
//

import LunaIngest
import LunaModels
import LunaStorage
import XCTest
@testable import LunaReadingList

/// The bulk import's orchestration — order, scoring, progress, cancellation —
/// with both of its real operations stubbed (`claudedocs/import-export.md`).
final class LinkImportRunnerTests: XCTestCase {

    private var tempDirectory: URL!
    private var store: ReadingListStore!

    override func setUp() {
        super.setUp()
        // Process-wide seams: the app this suite hosts on installs the real ones at
        // launch, so every test starts from none.
        LinkImportRunner.media = nil
        LinkImportRunner.articleUnlocker = nil
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(
            at: tempDirectory, withIntermediateDirectories: true)
        store = ReadingListStore(containerURL: tempDirectory)
    }

    override func tearDown() {
        LinkImportRunner.media = nil
        LinkImportRunner.articleUnlocker = nil
        try? FileManager.default.removeItem(at: tempDirectory)
        super.tearDown()
    }

    // MARK: - Helpers

    private func candidates(
        _ links: [String], archived: [String] = []
    ) -> [LinkImportRunner.Candidate] {
        links.map { LinkImportRunner.Candidate(urlString: $0, isArchived: false) }
            + archived.map { LinkImportRunner.Candidate(urlString: $0, isArchived: true) }
    }

    /// A runner whose ingest sets each item's state from `outcomes`, keyed by URL.
    /// Anything unlisted is left `.ready`.
    private func makeRunner(
        outcomes: [String: ReadingListItem.State] = [:],
        unsupported: Set<String> = [],
        concurrency: Int = 4,
        rescueSucceeds: @escaping (String) -> Bool = { _ in false },
        onIngest: (@Sendable (ReadingListItem) -> Void)? = nil
    ) -> LinkImportRunner {
        let store = store!
        return LinkImportRunner(
            store: store, concurrency: concurrency,
            ingest: { item in
                onIngest?(item)
                if unsupported.contains(item.urlString) {
                    store.delete(item) // What the real gate does.
                    return .unsupported(owner: .downloader)
                }
                switch outcomes[item.urlString] ?? .ready {
                case .ready:
                    Self.markReady(item, in: store)
                case .failed:
                    store.markFailed(item.id)
                case .needsCaptcha:
                    store.markNeedsCaptcha(item.id, title: "Locked")
                case .pending:
                    break
                }
                return .supported
            },
            rescue: { itemID in
                guard let item = store.item(withID: itemID),
                      rescueSucceeds(item.urlString) else { return false }
                Self.markReady(item, in: store)
                return true
            },
            rescueFraction: { _ in nil })
    }

    /// The store has no bare "set ready" — readiness always accompanies real
    /// content — so a stub reaches it the way an article ingest does.
    private static func markReady(_ item: ReadingListItem, in store: ReadingListStore) {
        _ = store.saveContent(
            ArticleContent(
                title: "Imported",
                blocks: [.init(kind: .paragraph, text: "Body.", links: [])]),
            for: item)
    }

    // MARK: - Concurrency policy

    func testDefaultConcurrencyStaysWithinItsBounds() {
        XCTAssertEqual(LinkImportRunner.defaultConcurrency(processorCount: 2, isLowPowerMode: false), 2)
        XCTAssertEqual(LinkImportRunner.defaultConcurrency(processorCount: 8, isLowPowerMode: false), 4)
        XCTAssertEqual(LinkImportRunner.defaultConcurrency(processorCount: 24, isLowPowerMode: false), 6)
    }

    func testLowPowerModeHalvesConcurrencyButNeverToZero() {
        XCTAssertEqual(LinkImportRunner.defaultConcurrency(processorCount: 8, isLowPowerMode: true), 2)
        XCTAssertEqual(LinkImportRunner.defaultConcurrency(processorCount: 2, isLowPowerMode: true), 1)
    }

    // MARK: - Ordering

    func testImportPreservesFileOrderInTheDisplaySort() async {
        let urls = (1...12).map { "https://example.com/\($0)" }
        _ = await makeRunner().run(candidates(urls))

        // Every deck orders by `bumpDate ?? dateAdded` descending, so that — not
        // the stored array — is what has to come back in file order.
        let saved = store.items()
            .sorted { ($0.bumpDate ?? $0.dateAdded) > ($1.bumpDate ?? $1.dateAdded) }
            .map(\.urlString)
        XCTAssertEqual(saved, urls)
    }

    func testEveryImportedItemGetsADistinctDateAdded() async {
        let urls = (1...20).map { "https://example.com/\($0)" }
        _ = await makeRunner().run(candidates(urls))
        let dates = Set(store.items().map(\.dateAdded))
        XCTAssertEqual(dates.count, urls.count)
    }

    func testArchivedCandidatesArriveArchived() async {
        _ = await makeRunner().run(
            candidates(["https://example.com/live"], archived: ["https://example.com/old"]))

        XCTAssertFalse(store.item(forURLString: "https://example.com/live")?.isArchived ?? true)
        XCTAssertTrue(store.item(forURLString: "https://example.com/old")?.isArchived ?? false)
    }

    func testImportIsNotASavePressSoItCannotTriggerADoubleSave() async {
        // The save-press window falls back to `dateAdded` when
        // `lastSaveAttemptDate` is nil, which would make a URL shared seconds
        // after its import read as the SECOND press on that item.
        _ = await makeRunner().run(candidates(["https://example.com/1"]))
        XCTAssertEqual(
            store.item(forURLString: "https://example.com/1")?.lastSaveAttemptDate,
            .distantPast)
    }

    // MARK: - Scoring

    func testReadyAndPaywalledSavesBothCountAsImported() async {
        // `.needsCaptcha` is a titled save the user unlocks by tapping it, not a
        // failure to retry.
        let summary = await makeRunner(
            outcomes: ["https://example.com/locked": .needsCaptcha]
        ).run(candidates(["https://example.com/free", "https://example.com/locked"]))

        XCTAssertEqual(summary.imported, 2)
        XCTAssertEqual(summary.recoverableFailures, 0)
        XCTAssertTrue(summary.rejected.isEmpty)
    }

    // MARK: - The web-unlock pass

    func testEveryPaywalledSaveGetsOneUnlockAttempt() async {
        let attempted = Attempts()
        LinkImportRunner.articleUnlocker = FakeArticleUnlocker { _, urlString in
            await attempted.record(urlString)
            return true
        }
        let summary = await makeRunner(
            outcomes: [
                "https://example.com/locked-1": .needsCaptcha,
                "https://example.com/locked-2": .needsCaptcha,
            ]
        ).run(candidates([
            "https://example.com/free", "https://example.com/locked-1",
            "https://example.com/locked-2",
        ]))

        let requested = await attempted.urlStrings
        XCTAssertEqual(
            requested.sorted(),
            ["https://example.com/locked-1", "https://example.com/locked-2"])
        XCTAssertEqual(summary.imported, 3)
    }

    func testAPaywalledSaveTheUnlockCouldNotOpenIsStillImportedNotAFailure() async {
        // It is titled and it opens; the user solves the CAPTCHA when they choose.
        LinkImportRunner.articleUnlocker = FakeArticleUnlocker { _, _ in false }
        let summary = await makeRunner(
            outcomes: ["https://example.com/locked": .needsCaptcha]
        ).run(candidates(["https://example.com/locked"]))

        XCTAssertEqual(summary.imported, 1)
        XCTAssertEqual(summary.recoverableFailures, 0)
        XCTAssertTrue(summary.rejected.isEmpty)
        XCTAssertEqual(store.items().first?.state, .needsCaptcha)
    }

    func testTheUnlockPassRunsOneArticleAtATime() async {
        // Each attempt is a whole WKWebView, and two of them racing archive.today
        // is the fastest way to be rate-limited.
        let concurrent = PeakConcurrency()
        LinkImportRunner.articleUnlocker = FakeArticleUnlocker { _, _ in
            await concurrent.begin()
            await Task.yield()
            await concurrent.end()
            return true
        }
        _ = await makeRunner(
            outcomes: [
                "https://example.com/a": .needsCaptcha,
                "https://example.com/b": .needsCaptcha,
                "https://example.com/c": .needsCaptcha,
            ]
        ).run(candidates(["https://example.com/a", "https://example.com/b", "https://example.com/c"]))

        let peak = await concurrent.peak
        XCTAssertEqual(peak, 1)
    }

    func testWithNoUnlockerInstalledAPaywalledSaveIsSimplyImported() async {
        // The Downloader and Price Tracker install none — there is no article save
        // to unlock there — and the pass is skipped rather than stalling the run.
        LinkImportRunner.articleUnlocker = nil
        let summary = await makeRunner(
            outcomes: ["https://example.com/locked": .needsCaptcha]
        ).run(candidates(["https://example.com/locked"]))

        XCTAssertEqual(summary.imported, 1)
    }

    func testStoppingTheRunSkipsTheRemainingUnlocksWithoutLosingTheSaves() async {
        let attempted = Attempts()
        let runner = makeRunner(
            outcomes: [
                "https://example.com/a": .needsCaptcha,
                "https://example.com/b": .needsCaptcha,
            ], concurrency: 1)
        LinkImportRunner.articleUnlocker = FakeArticleUnlocker { [weak runner] _, urlString in
            await attempted.record(urlString)
            runner?.cancel()   // Stopped during the first unlock.
            return true
        }
        let summary = await runner.run(
            candidates(["https://example.com/a", "https://example.com/b"]))

        let requested = await attempted.urlStrings
        XCTAssertEqual(requested.count, 1)
        XCTAssertTrue(summary.wasCancelled)
        // Both are still saved and both still count — a skipped unlock costs the
        // article nothing.
        XCTAssertEqual(summary.imported, 2)
        XCTAssertEqual(store.items().count, 2)
    }

    /// A stand-in unlock leg running whatever the test wrote.
    private struct FakeArticleUnlocker: LinkImportArticleUnlocking {
        let unlock: @Sendable (UUID, String) async -> Bool

        init(_ unlock: @escaping @Sendable (UUID, String) async -> Bool) {
            self.unlock = unlock
        }

        func unlockArticle(itemID: UUID, urlString: String) async -> Bool {
            await unlock(itemID, urlString)
        }
    }

    /// Records which URLs the unlock seam was asked about.
    private actor Attempts {
        var urlStrings: [String] = []
        func record(_ urlString: String) { urlStrings.append(urlString) }
    }

    /// Watches how many unlocks are in flight at once.
    private actor PeakConcurrency {
        private var current = 0
        var peak = 0

        func begin() {
            current += 1
            peak = max(peak, current)
        }

        func end() { current -= 1 }
    }

    func testForeignKindsAreRejectedAndNamed() async {
        let summary = await makeRunner(
            unsupported: ["https://example.com/video"]
        ).run(candidates(["https://example.com/article", "https://example.com/video"]))

        XCTAssertEqual(summary.imported, 1)
        XCTAssertEqual(summary.rejected.count, 1)
        XCTAssertEqual(summary.rejected.first?.urlString, "https://example.com/video")
        XCTAssertEqual(summary.rejected.first?.reason, .foreignKind(owner: .downloader))
        // A dropped kind leaves nothing behind.
        XCTAssertNil(store.item(forURLString: "https://example.com/video"))
    }

    func testAlreadySavedLinksAreReportedAsDuplicatesAndLeftAlone() async {
        let existing = store.add(urlString: "https://example.com/1")
        Self.markReady(existing, in: store)
        let before = store.items().count

        let summary = await makeRunner().run(
            candidates(["https://example.com/1", "https://example.com/2"]))

        XCTAssertEqual(summary.duplicates, 1)
        XCTAssertEqual(summary.imported, 1)
        XCTAssertEqual(store.items().count, before + 1)
    }

    func testARepeatedLinkInsideOneFileIsOnlySavedOnce() async {
        let summary = await makeRunner().run(
            candidates(["https://example.com/1", "https://example.com/1"]))
        XCTAssertEqual(summary.imported, 1)
        XCTAssertEqual(summary.duplicates, 1)
        XCTAssertEqual(store.items().count, 1)
    }

    func testTotalAlwaysAccountsForEveryCandidate() async {
        let summary = await makeRunner(
            outcomes: ["https://example.com/b": .failed],
            unsupported: ["https://example.com/c"]
        ).run(candidates([
            "https://example.com/a", "https://example.com/b",
            "https://example.com/c", "https://example.com/a",
        ]))
        XCTAssertEqual(summary.total, 4)
    }

    // MARK: - Rescue

    func testAFailureIsRetriedWithTheModelBeforeBeingCalledAFailure() async {
        let summary = await makeRunner(
            outcomes: ["https://example.com/hard": .failed],
            rescueSucceeds: { $0 == "https://example.com/hard" }
        ).run(candidates(["https://example.com/hard"]))

        XCTAssertEqual(summary.imported, 1)
        XCTAssertEqual(summary.recoverableFailures, 0)
    }

    func testAFailureTheModelCannotRecoverIsRecoverableNotRejected() async {
        // Still a real save that Luna's own launch sweep keeps retrying, so it
        // must not be reported as a rejected link.
        let summary = await makeRunner(
            outcomes: ["https://example.com/hard": .failed]
        ).run(candidates(["https://example.com/hard"]))

        XCTAssertEqual(summary.imported, 0)
        XCTAssertEqual(summary.recoverableFailures, 1)
        XCTAssertTrue(summary.rejected.isEmpty)
        XCTAssertNotNil(store.item(forURLString: "https://example.com/hard"))
    }

    func testAnItemDiscardedDuringRescueIsReportedAsAnUnnamedForeignKind() async {
        let store = store!
        let runner = LinkImportRunner(
            store: store, concurrency: 1,
            ingest: { item -> SurfaceSupport.Decision in
                store.markFailed(item.id)
                return .supported
            },
            rescue: { itemID in
                // What `applyRescued`'s gate does when a rescue lands a kind this
                // app doesn't handle: the item is gone, and the owner isn't
                // reported back through that path.
                if let item = store.item(withID: itemID) { store.delete(item) }
                return false
            },
            rescueFraction: { _ in nil })

        let summary = await runner.run(candidates(["https://example.com/1"]))
        XCTAssertEqual(summary.rejected.count, 1)
        XCTAssertEqual(summary.rejected.first?.reason, .foreignKind(owner: nil))
        XCTAssertEqual(summary.recoverableFailures, 0)
    }

    // MARK: - Progress

    func testProgressReachesOneAndCountsEveryLink() async {
        let urls = (1...6).map { "https://example.com/\($0)" }
        let runner = makeRunner(outcomes: ["https://example.com/3": .failed])
        _ = await runner.run(candidates(urls))

        let progress = runner.currentProgress()
        XCTAssertEqual(progress.fraction, 1, accuracy: 0.0001)
        XCTAssertEqual(progress.finished, 6)
        XCTAssertEqual(progress.total, 6)
        XCTAssertEqual(progress.phase, .done)
    }

    func testProgressNeverExceedsOneWhileWorkIsStillOpen() async {
        // The clock-based estimate for an open slice must stay inside that
        // slice's own share, however long the fetch takes.
        let urls = (1...4).map { "https://example.com/\($0)" }
        let observed = ObservedProgress()
        let runner = makeRunner(
            outcomes: Dictionary(uniqueKeysWithValues: urls.map { ($0, .ready) }),
            concurrency: 2,
            onIngest: { [weak observed] _ in observed?.record() })
        observed.runner = runner
        _ = await runner.run(candidates(urls))
        XCTAssertLessThanOrEqual(observed.highWaterMark, 1.0)
        XCTAssertGreaterThanOrEqual(observed.highWaterMark, 0)
    }

    func testAnEmptyCandidateListFinishesImmediately() async {
        let runner = makeRunner()
        let summary = await runner.run([])
        XCTAssertEqual(summary.total, 0)
        XCTAssertEqual(runner.currentProgress().phase, .done)
    }

    // MARK: - Cancellation

    func testCancellingMidRunStillSavesEveryLinkAndAccountsForThemAll() async {
        let urls = (1...8).map { "https://example.com/\($0)" }
        let store = store!
        // A box, because the stub has to cancel the very runner it belongs to.
        let box = RunnerBox()
        let runner = LinkImportRunner(
            store: store, concurrency: 1,
            ingest: { item -> SurfaceSupport.Decision in
                // Cancel while the second link is in flight, so six are never
                // reached at all.
                if item.urlString == "https://example.com/2" { box.runner?.cancel() }
                Self.markReady(item, in: store)
                return .supported
            },
            rescue: { _ in false }, rescueFraction: { _ in nil })
        box.runner = runner

        let summary = await runner.run(candidates(urls))

        XCTAssertTrue(summary.wasCancelled)
        // Every candidate is accounted for exactly once...
        XCTAssertEqual(summary.total, urls.count)
        // ...the ones that were reached are imported...
        XCTAssertGreaterThanOrEqual(summary.imported, 2)
        // ...and nothing was lost: the placeholders are all still in the store for
        // the ordinary launch sweep to finish.
        XCTAssertEqual(store.items().count, urls.count)
        XCTAssertEqual(summary.recoverableFailures, urls.count - summary.imported)
    }

    func testACancelledRunStillDrivesTheBarToTheEnd() async {
        let urls = (1...5).map { "https://example.com/\($0)" }
        let runner = makeRunner(concurrency: 1)
        runner.cancel()
        _ = await runner.run(candidates(urls))
        XCTAssertEqual(runner.currentProgress().fraction, 1, accuracy: 0.0001)
    }
}

/// Lets a stub reach the runner it was handed to.
private final class RunnerBox {
    weak var runner: LinkImportRunner?
}

/// Samples the runner's pulled progress from inside each ingest, so an
/// intermediate reading — not just the final one — is checked for sanity.
private final class ObservedProgress {
    weak var runner: LinkImportRunner?
    private let lock = NSLock()
    private var mark: Double = 0

    var highWaterMark: Double {
        lock.lock(); defer { lock.unlock() }
        return mark
    }

    func record() {
        guard let fraction = runner?.currentProgress().fraction else { return }
        lock.lock()
        mark = max(mark, fraction)
        lock.unlock()
    }
}
