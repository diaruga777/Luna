//
//  TranscriptionJobStoreTests.swift
//  LunaTests
//

import LunaModels
import LunaStorage
import SQLite3
import XCTest

/// The `transcriptions` table as the runner and the pending card use it
/// (`claudedocs/plans/transcription-plugins.md` §4).
final class TranscriptionJobStoreTests: XCTestCase {

    private var container: URL!
    private var saves: SavesStore!
    private var jobs: TranscriptionJobStore!

    override func setUpWithError() throws {
        container = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptionJobStore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        saves = SavesStore(containerURL: container)
        jobs = TranscriptionJobStore(saves: saves)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: container)
    }

    private static let request = TranscriptionRequest(
        mediaURL: URL(string: "https://cdn.example.com/v.mp4")!, mediaKind: .video,
        audioURL: URL(string: "https://cdn.example.com/a.m4a")!,
        requestHeaders: ["Referer": "https://example.com/"],
        expiresAt: Date(timeIntervalSince1970: 1_800_000_000), language: "en",
        title: "A talk", author: "Someone", pluginID: "app.luna.t",
        leadContent: ArticleContent(
            title: "A talk", blocks: [.init(kind: .paragraph, text: "Lead.", links: [])]))

    private func save(_ path: String = "talk") -> UUID {
        saves.add(urlString: "https://example.com/\(path)").id
    }

    // MARK: - The row

    func testEnqueueStoresTheWholeRequestAsAQueuedJob() throws {
        let id = save()
        jobs.enqueue(saveID: id, request: Self.request)

        let job = try XCTUnwrap(jobs.job(saveID: id))
        XCTAssertEqual(job.status, .queued)
        XCTAssertEqual(job.attempts, 0)
        XCTAssertNil(job.failure)
        XCTAssertNil(job.scratchPath)
        XCTAssertEqual(job.request, Self.request, "every field survives the JSON column")
        XCTAssertTrue(jobs.hasJob(saveID: id))
        XCTAssertEqual(jobs.status(saveID: id), .queued)
        XCTAssertEqual(jobs.saveIDsWithJobs(), [id])
        XCTAssertFalse(jobs.hasJob(saveID: UUID()))
    }

    func testEnqueueAgainReplacesTheRequestAndResetsTheAttempts() throws {
        let id = save()
        jobs.enqueue(saveID: id, request: Self.request)
        jobs.recordFailure(saveID: id, detail: "offline", terminal: false)
        let fresh = TranscriptionRequest(
            mediaURL: URL(string: "https://cdn.example.com/fresh.m4a")!, mediaKind: .audio,
            title: "A talk", pluginID: "app.luna.t")

        jobs.enqueue(saveID: id, request: fresh)

        let job = try XCTUnwrap(jobs.job(saveID: id))
        XCTAssertEqual(job.request, fresh)
        XCTAssertEqual(job.attempts, 0)
        XCTAssertEqual(job.status, .queued)
        XCTAssertNil(job.failure)
    }

    func testDeletingTheSaveTakesItsJob() {
        let item = saves.add(urlString: "https://example.com/gone")
        jobs.enqueue(saveID: item.id, request: Self.request)
        XCTAssertTrue(jobs.hasJob(saveID: item.id))

        saves.delete(item)

        XCTAssertFalse(jobs.hasJob(saveID: item.id))
        XCTAssertTrue(jobs.saveIDsWithJobs().isEmpty)
    }

    /// Four independently updated apps share the file: a status this build does
    /// not know must read as a safe default rather than crash a mapper.
    func testAnUnknownStatusReadsAsFailed() throws {
        let id = save()
        jobs.enqueue(saveID: id, request: Self.request)

        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(container.appendingPathComponent("saves.sqlite").path, &handle), SQLITE_OK)
        let db = try XCTUnwrap(handle)
        defer { sqlite3_close(db) }
        XCTAssertEqual(
            sqlite3_exec(db, "UPDATE transcriptions SET status = 'some-future-state'", nil, nil, nil),
            SQLITE_OK)

        XCTAssertEqual(jobs.status(saveID: id), .failed)
        XCTAssertNil(jobs.nextRunnable(), "an unreadable state is never run")
    }

    // MARK: - Status transitions

    func testStatusWritesCarryTheScratchPathUntilTheFileIsGone() throws {
        let id = save()
        jobs.enqueue(saveID: id, request: Self.request)

        jobs.setStatus(.downloading, saveID: id, scratchPath: "\(id.uuidString).m4a")
        XCTAssertEqual(jobs.liveScratchPaths(), ["\(id.uuidString).m4a"])
        XCTAssertEqual(jobs.status(saveID: id), .downloading)

        jobs.setStatus(.transcribing, saveID: id, scratchPath: "\(id.uuidString).m4a")
        XCTAssertEqual(jobs.liveScratchPaths(), ["\(id.uuidString).m4a"])

        jobs.markDone(saveID: id)
        let job = try XCTUnwrap(jobs.job(saveID: id))
        XCTAssertEqual(job.status, .done)
        XCTAssertNil(job.scratchPath)
        XCTAssertTrue(jobs.liveScratchPaths().isEmpty)
        XCTAssertNil(jobs.nextRunnable(), "a finished job is never picked up again")
        XCTAssertTrue(jobs.hasJob(saveID: id), "the row stays so the launch sweep keeps skipping the save")
    }

    func testATransientFailureRequeuesWithBackoffAndATerminalOneEndsTheJob() throws {
        let id = save()
        let start = Date(timeIntervalSinceReferenceDate: 1_000_000)
        jobs.enqueue(saveID: id, request: Self.request, now: start)
        jobs.setStatus(.downloading, saveID: id, scratchPath: "x.m4a", now: start)

        jobs.recordFailure(saveID: id, detail: "offline", terminal: false, now: start)

        var job = try XCTUnwrap(jobs.job(saveID: id))
        XCTAssertEqual(job.status, .queued)
        XCTAssertEqual(job.attempts, 1)
        XCTAssertEqual(job.failure, "offline")
        XCTAssertNil(job.scratchPath, "a failed attempt owns no file")
        XCTAssertNil(jobs.nextRunnable(now: start), "one failure waits two minutes")
        XCTAssertNil(jobs.nextRunnable(now: start.addingTimeInterval(119)))
        XCTAssertEqual(jobs.nextRunnable(now: start.addingTimeInterval(120))?.saveID, id)

        jobs.recordFailure(saveID: id, detail: "no audio", terminal: true, now: start)
        job = try XCTUnwrap(jobs.job(saveID: id))
        XCTAssertEqual(job.status, .failed)
        XCTAssertEqual(job.attempts, 2)
        XCTAssertEqual(job.failure, "no audio")
        XCTAssertNil(jobs.nextRunnable(now: start.addingTimeInterval(86_400)))
    }

    func testTheRetryPolicyDoublesAndCapsAtAnHour() {
        let at = Date(timeIntervalSinceReferenceDate: 0)
        XCTAssertEqual(TranscriptionRetryPolicy.retryDate(attempts: 0, updatedAt: at), at)
        XCTAssertEqual(TranscriptionRetryPolicy.retryDate(attempts: 1, updatedAt: at), at.addingTimeInterval(2 * 60))
        XCTAssertEqual(TranscriptionRetryPolicy.retryDate(attempts: 2, updatedAt: at), at.addingTimeInterval(4 * 60))
        XCTAssertEqual(TranscriptionRetryPolicy.retryDate(attempts: 5, updatedAt: at), at.addingTimeInterval(32 * 60))
        XCTAssertEqual(TranscriptionRetryPolicy.retryDate(attempts: 6, updatedAt: at), at.addingTimeInterval(60 * 60))
        XCTAssertEqual(TranscriptionRetryPolicy.retryDate(attempts: 9, updatedAt: at), at.addingTimeInterval(60 * 60))
    }

    // MARK: - What the runner takes next

    func testNextRunnableTakesOldestDueFirstAndResumesAnInterruptedJob() {
        let first = save("one")
        let second = save("two")
        let third = save("three")
        let start = Date(timeIntervalSinceReferenceDate: 2_000_000)
        jobs.enqueue(saveID: first, request: Self.request, now: start)
        jobs.enqueue(saveID: second, request: Self.request, now: start.addingTimeInterval(1))
        jobs.enqueue(saveID: third, request: Self.request, now: start.addingTimeInterval(2))

        XCTAssertEqual(jobs.nextRunnable(now: start.addingTimeInterval(3))?.saveID, first)

        // The first one failed and is waiting; the second was mid-download when
        // the process died. The interrupted one is taken before a fresh one.
        jobs.recordFailure(saveID: first, detail: "offline", terminal: false, now: start.addingTimeInterval(3))
        jobs.setStatus(.downloading, saveID: second, scratchPath: "two.m4a", now: start.addingTimeInterval(3))
        XCTAssertEqual(jobs.nextRunnable(now: start.addingTimeInterval(4))?.saveID, second)

        jobs.markDone(saveID: second)
        XCTAssertEqual(jobs.nextRunnable(now: start.addingTimeInterval(5))?.saveID, third)
    }

    func testUpdateRequestKeepsEverythingElse() throws {
        let id = save()
        jobs.enqueue(saveID: id, request: Self.request)
        jobs.recordFailure(saveID: id, detail: "403", terminal: false)
        let fresh = TranscriptionRequest(
            mediaURL: URL(string: "https://cdn.example.com/fresh.m4a")!, mediaKind: .audio,
            title: "A talk", pluginID: "app.luna.t")

        jobs.updateRequest(fresh, saveID: id)

        let job = try XCTUnwrap(jobs.job(saveID: id))
        XCTAssertEqual(job.request, fresh)
        XCTAssertEqual(job.attempts, 1, "a re-resolution is not a new job")
        XCTAssertEqual(job.status, .queued)
    }

    // MARK: - The change notification

    func testEveryWritePostsSavesChanged() {
        let id = save()
        let posted = expectation(forNotification: .savesChanged, object: nil)
        posted.assertForOverFulfill = false
        jobs.enqueue(saveID: id, request: Self.request)
        wait(for: [posted], timeout: 2)

        let again = expectation(forNotification: .savesChanged, object: nil)
        again.assertForOverFulfill = false
        jobs.setStatus(.transcribing, saveID: id, scratchPath: "x")
        wait(for: [again], timeout: 2)
    }

    // MARK: - The scratch sweep

    func testTheSweepRemovesEveryFileNoLiveJobNames() throws {
        let live = save("live")
        let stale = save("stale")
        jobs.enqueue(saveID: live, request: Self.request)
        jobs.enqueue(saveID: stale, request: Self.request)
        jobs.setStatus(.downloading, saveID: live, scratchPath: "\(live.uuidString).m4a")
        jobs.recordFailure(saveID: stale, detail: "gone", terminal: true)

        let directory = saves.transcriptionScratchDirectoryURL
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for name in ["\(live.uuidString).m4a", "\(stale.uuidString).mp4", "orphan.media"] {
            try Data("bytes".utf8).write(to: directory.appendingPathComponent(name))
        }

        let removed = TranscriptionScratchSweep.run(directory: directory, store: jobs)

        XCTAssertEqual(Set(removed), ["\(stale.uuidString).mp4", "orphan.media"])
        XCTAssertEqual(
            Set(try FileManager.default.contentsOfDirectory(atPath: directory.path)),
            ["\(live.uuidString).m4a"])
    }

    func testTheSweepOfAMissingDirectoryIsEmpty() {
        let directory = container.appendingPathComponent("never-created", isDirectory: true)
        XCTAssertEqual(TranscriptionScratchSweep.run(directory: directory, store: jobs), [])
    }
}
