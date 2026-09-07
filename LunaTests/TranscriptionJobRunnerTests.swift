//
//  TranscriptionJobRunnerTests.swift
//  LunaTests
//

import Foundation
import LunaModels
import LunaSaves
import LunaStorage
import LunaTranscribe
import XCTest

/// The runner over a real store and job table, with the network, the engine
/// and the plugin re-resolution stubbed (`claudedocs/plans/transcription-plugins.md` §5.4).
@MainActor
final class TranscriptionJobRunnerTests: XCTestCase {

    private var directory: URL!
    private var store: SavesStore!
    private var jobs: TranscriptionJobStore!
    private var failures: SaveFailureStore!
    private var downloader: FakeDownloader!
    private var engine: FakeEngine!
    private var reresolver: FakeReresolver!
    private var lease: FakeLease!
    private var handler: RecordingArticleHandler!
    private var previousHandler: IngestorArticleHandling?
    private var clock = Date(timeIntervalSince1970: 1_700_000_000)

    private var scratch: URL { directory.appendingPathComponent("Transcriptions") }

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptionJobRunnerTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = SavesStore(containerURL: directory)
        jobs = TranscriptionJobStore(saves: store)
        failures = SaveFailureStore(containerURL: directory)
        downloader = FakeDownloader()
        engine = FakeEngine()
        reresolver = FakeReresolver()
        lease = FakeLease()
        handler = RecordingArticleHandler(store: store)
        previousHandler = IngestorKindHandlers.article
        IngestorKindHandlers.article = handler
    }

    override func tearDown() {
        IngestorKindHandlers.article = previousHandler
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func makeRunner() -> TranscriptionJobRunner {
        TranscriptionJobRunner(
            store: store, jobs: jobs, failures: failures, downloader: downloader, engine: engine,
            reresolver: reresolver, lease: lease, scratchDirectory: scratch,
            now: { [unowned self] in self.clock })
    }

    private func request(
        url: String = "https://cdn.example.com/talk.mp4", expiresAt: Date? = nil,
        audioURL: String? = nil
    ) -> TranscriptionRequest {
        TranscriptionRequest(
            mediaURL: URL(string: url)!, mediaKind: .video,
            audioURL: audioURL.flatMap(URL.init(string:)), expiresAt: expiresAt, language: "en",
            title: "A recorded talk", author: "Someone", pluginID: "app.luna.test.transcript")
    }

    @discardableResult
    private func enqueue(_ request: TranscriptionRequest? = nil) -> SavedItem {
        let item = store.add(urlString: "https://example.com/watch?v=\(UUID().uuidString)", source: .manual)
        store.setPendingTitle(item.id, title: "A recorded talk")
        jobs.enqueue(saveID: item.id, request: request ?? self.request(), now: clock)
        return item
    }

    private func scratchFiles() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: scratch.path)) ?? []
    }

    // MARK: - Success

    func testASuccessfulJobPersistsTheTranscriptAndDeletesTheRecording() async throws {
        let item = enqueue()
        engine.segments = [
            TranscriptSegment(start: 0, end: 2, text: "Hello there."),
            TranscriptSegment(start: 2.2, end: 4, text: "Welcome to the talk."),
        ]

        await makeRunner().runUntilIdle()

        XCTAssertEqual(handler.persisted.count, 1)
        let content = try XCTUnwrap(handler.persisted.first?.content)
        XCTAssertEqual(content.title, "A recorded talk")
        XCTAssertEqual(content.blocks.map(\.text), ["Hello there. Welcome to the talk."])
        XCTAssertEqual(store.item(withID: item.id)?.state, .ready)
        XCTAssertEqual(jobs.status(saveID: item.id), .done)
        XCTAssertEqual(scratchFiles(), [], "the recording is deleted once the transcript is written")
        XCTAssertEqual(engine.fileExistedAtTranscribe, [true], "the engine saw the fetched file")
        XCTAssertEqual(lease.begun, 1)
        XCTAssertEqual(lease.ended, 1)
        XCTAssertEqual(downloader.calls.count, 1)
        XCTAssertEqual(downloader.calls.first?.fetchURL.absoluteString, "https://cdn.example.com/talk.mp4")
    }

    func testTheAudioLegIsFetchedInsteadOfTheVideoWhenThereIsOne() async {
        enqueue(request(audioURL: "https://cdn.example.com/talk/audio"))

        await makeRunner().runUntilIdle()

        XCTAssertEqual(downloader.calls.map(\.fetchURL.absoluteString), ["https://cdn.example.com/talk/audio"])
        XCTAssertEqual(handler.persisted.count, 1)
    }

    // MARK: - Failure policy

    func testATransientFailureLeavesTheJobQueuedForALaterAttempt() async {
        let item = enqueue()
        downloader.script = [.failure(.httpStatus(503))]

        await makeRunner().runUntilIdle()

        let job = jobs.job(saveID: item.id)
        XCTAssertEqual(job?.status, .queued)
        XCTAssertEqual(job?.attempts, 1)
        XCTAssertEqual(store.item(withID: item.id)?.state, .pending)
        XCTAssertTrue(handler.persisted.isEmpty)
        XCTAssertEqual(scratchFiles(), [])
        XCTAssertNil(failures.record(for: item.id)?.reason)
    }

    func testThreeTransientFailuresBecomeTerminal() async {
        let item = enqueue()
        downloader.script = [.failure(.httpStatus(503)), .failure(.transport("reset")), .failure(.httpStatus(500))]
        let runner = makeRunner()

        await runner.runUntilIdle()
        XCTAssertEqual(jobs.status(saveID: item.id), .queued)
        // Not yet due: the backoff holds the row back.
        await runner.runUntilIdle()
        XCTAssertEqual(jobs.job(saveID: item.id)?.attempts, 1)

        clock = clock.addingTimeInterval(3 * 60 * 60)
        await runner.runUntilIdle()
        XCTAssertEqual(jobs.job(saveID: item.id)?.attempts, 2)
        XCTAssertEqual(jobs.status(saveID: item.id), .queued)

        clock = clock.addingTimeInterval(3 * 60 * 60)
        await runner.runUntilIdle()
        XCTAssertEqual(jobs.job(saveID: item.id)?.attempts, 3)
        XCTAssertEqual(jobs.status(saveID: item.id), .failed)
        XCTAssertEqual(store.item(withID: item.id)?.state, .failed)
        XCTAssertEqual(
            failures.record(for: item.id)?.reason,
            .transcriptionFailed(L10n.string("Transcription_failed")))
        XCTAssertEqual(downloader.calls.count, 3)
    }

    func testATerminalEngineFailureMarksTheSaveFailedWithItsReason() async {
        let item = enqueue()
        engine.failure = .noAudioTrack

        await makeRunner().runUntilIdle()

        XCTAssertEqual(jobs.status(saveID: item.id), .failed)
        XCTAssertEqual(store.item(withID: item.id)?.state, .failed)
        XCTAssertEqual(
            failures.record(for: item.id)?.reason,
            .transcriptionFailed(L10n.string("Transcription_noAudioTrack")))
        XCTAssertEqual(scratchFiles(), [], "a failed job leaves no recording behind")
        XCTAssertTrue(handler.persisted.isEmpty)
        XCTAssertEqual(downloader.calls.count, 1)
    }

    func testAnUnsupportedOSFailsBeforeAnyDownload() async {
        let item = enqueue()
        engine.availability = .unsupportedOS

        await makeRunner().runUntilIdle()

        XCTAssertTrue(downloader.calls.isEmpty)
        XCTAssertEqual(jobs.status(saveID: item.id), .failed)
        XCTAssertEqual(store.item(withID: item.id)?.state, .failed)
        XCTAssertEqual(
            failures.record(for: item.id)?.reason,
            .transcriptionFailed(L10n.string("Transcription_needsIOS26")))
    }

    func testAnEmptyTranscriptIsATerminalFailure() async {
        let item = enqueue()
        engine.segments = []

        await makeRunner().runUntilIdle()

        XCTAssertEqual(jobs.status(saveID: item.id), .failed)
        XCTAssertEqual(
            failures.record(for: item.id)?.reason,
            .transcriptionFailed(L10n.string("Transcription_noSpeech")))
    }

    // MARK: - Re-resolution

    func testARefusedFetchReresolvesOnceAndRetriesWithTheFreshRequest() async {
        let item = enqueue()
        let fresh = request(url: "https://cdn.example.com/talk-fresh.mp4")
        downloader.script = [.failure(.sourceUnavailable)]
        reresolver.answer = .request(fresh)

        await makeRunner().runUntilIdle()

        XCTAssertEqual(reresolver.calls.map(\.pluginID), ["app.luna.test.transcript"])
        XCTAssertEqual(
            downloader.calls.map(\.fetchURL.absoluteString),
            ["https://cdn.example.com/talk.mp4", "https://cdn.example.com/talk-fresh.mp4"])
        XCTAssertEqual(jobs.job(saveID: item.id)?.request, fresh, "the row now carries the fresh request")
        XCTAssertEqual(handler.persisted.count, 1)
        XCTAssertEqual(jobs.status(saveID: item.id), .done)
    }

    func testAnExpiredRequestReresolvesBeforeFetching() async {
        enqueue(request(expiresAt: clock.addingTimeInterval(-60)))
        let fresh = request(url: "https://cdn.example.com/talk-fresh.mp4")
        reresolver.answer = .request(fresh)

        await makeRunner().runUntilIdle()

        XCTAssertEqual(reresolver.calls.count, 1)
        XCTAssertEqual(downloader.calls.map(\.fetchURL.absoluteString), ["https://cdn.example.com/talk-fresh.mp4"])
        XCTAssertEqual(handler.persisted.count, 1)
    }

    func testAReresolutionThatHandsBackAnArticlePersistsItWithoutADownload() async throws {
        let item = enqueue(request(expiresAt: clock.addingTimeInterval(-60)))
        var captions = ArticleContent(title: "A recorded talk", author: nil, blocks: [])
        captions.blocks = [ArticleContent.Block(kind: .paragraph, text: "From captions.", links: [])]
        reresolver.answer = .article(captions)

        await makeRunner().runUntilIdle()

        XCTAssertTrue(downloader.calls.isEmpty)
        XCTAssertEqual(engine.fileExistedAtTranscribe, [])
        XCTAssertEqual(handler.persisted.first?.content.blocks.map(\.text), ["From captions."])
        XCTAssertEqual(store.item(withID: item.id)?.state, .ready)
        XCTAssertEqual(jobs.status(saveID: item.id), .done)
    }

    func testARefusedFetchWithNoReresolutionIsATransientFailure() async {
        let item = enqueue()
        downloader.script = [.failure(.sourceUnavailable)]
        reresolver.answer = nil

        await makeRunner().runUntilIdle()

        XCTAssertEqual(reresolver.calls.count, 1)
        XCTAssertEqual(jobs.status(saveID: item.id), .queued)
        XCTAssertEqual(jobs.job(saveID: item.id)?.attempts, 1)
        XCTAssertEqual(downloader.calls.count, 1, "a second fetch needs a fresh request")
    }

    // MARK: - The save moving under the job

    func testASaveDeletedMidJobWritesNothing() async {
        let item = enqueue()
        engine.onTranscribe = { [store] in
            if let live = store?.item(withID: item.id) { store?.delete(live) }
        }

        await makeRunner().runUntilIdle()

        XCTAssertTrue(handler.persisted.isEmpty)
        XCTAssertNil(jobs.job(saveID: item.id), "the row cascaded away with the save")
        XCTAssertEqual(scratchFiles(), [])
    }

    func testAJobWhoseSaveIsAlreadyReadyIsClosedWithoutWork() async {
        let item = enqueue()
        _ = store.saveContent(ArticleContent(title: "Done elsewhere", author: nil, blocks: []), for: item)

        await makeRunner().runUntilIdle()

        XCTAssertTrue(downloader.calls.isEmpty)
        XCTAssertEqual(jobs.status(saveID: item.id), .done)
    }

    // MARK: - Single flight

    func testAKickWhileRunningStartsNoSecondDrain() async {
        enqueue()
        let runner = makeRunner()
        var wasRunningDuringJob = false
        var kickedDuring = false
        engine.onTranscribe = {
            wasRunningDuringJob = runner.isRunning
            runner.kick()
            kickedDuring = true
        }

        await runner.runUntilIdle()

        XCTAssertTrue(kickedDuring)
        XCTAssertTrue(wasRunningDuringJob)
        XCTAssertEqual(handler.persisted.count, 1, "the kick inside the run started nothing new")
        XCTAssertEqual(lease.begun, 1)
    }

    func testTheScratchNameKeepsAPlainExtensionOnly() {
        let id = UUID()
        XCTAssertEqual(
            TranscriptionJobRunner.scratchName(for: id, fetchURL: URL(string: "https://x/a/b.m4a?sig=1")!),
            "\(id.uuidString).m4a")
        XCTAssertEqual(
            TranscriptionJobRunner.scratchName(for: id, fetchURL: URL(string: "https://v.redd.it/abc/audio")!),
            "\(id.uuidString).media")
        XCTAssertEqual(
            TranscriptionJobRunner.scratchName(for: id, fetchURL: URL(string: "https://x/f.tar.gz.backup")!),
            "\(id.uuidString).media")
    }
}

// MARK: - Fakes

private final class FakeDownloader: TranscriptionSourceDownloading {
    var script: [Result<Void, TranscriptionError>] = []
    private(set) var calls: [TranscriptionRequest] = []

    func download(_ request: TranscriptionRequest, to destination: URL) async throws {
        calls.append(request)
        let step: Result<Void, TranscriptionError> = script.isEmpty ? .success(()) : script.removeFirst()
        switch step {
        case .success:
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("recording".utf8).write(to: destination)
        case let .failure(error):
            throw error
        }
    }
}

private final class FakeEngine: TranscriptionEngine {
    var availability: TranscriptionAvailability = .available
    var segments: [TranscriptSegment] = [TranscriptSegment(start: 0, end: 1, text: "Hello.")]
    var failure: TranscriptionError?
    var onTranscribe: (() -> Void)?
    private(set) var fileExistedAtTranscribe: [Bool] = []

    func transcribe(
        audioFileURL: URL, mediaKind: TranscriptionRequest.MediaKind, language: String?,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> [TranscriptSegment] {
        fileExistedAtTranscribe.append(FileManager.default.fileExists(atPath: audioFileURL.path))
        onTranscribe?()
        if let failure { throw failure }
        progress(1)
        return segments
    }
}

private final class FakeReresolver: TranscriptionReresolving {
    var answer: TranscriptionReresolution?
    private(set) var calls: [(sourceURL: URL, pluginID: String, saveID: UUID)] = []

    func reresolve(sourceURL: URL, pluginID: String, saveID: UUID) async -> TranscriptionReresolution? {
        calls.append((sourceURL, pluginID, saveID))
        return answer
    }
}

private final class FakeLease: TranscriptionBackgroundLeasing {
    private(set) var begun = 0
    private(set) var ended = 0

    func begin() -> TranscriptionLeaseToken? {
        begun += 1
        return TranscriptionLeaseToken(rawValue: begun)
    }

    func end(_ token: TranscriptionLeaseToken) {
        ended += 1
    }
}

/// Persists like the real handler's one visible effect: the content is saved
/// and the item flips `.ready`.
private final class RecordingArticleHandler: IngestorArticleHandling {
    private weak var store: SavesStore?
    private(set) var persisted: [(item: SavedItem, content: ArticleContent)] = []

    init(store: SavesStore) {
        self.store = store
    }

    func persistArticle(
        _ content: ArticleContent, html: String, for item: SavedItem, url: URL, store: SavesStore
    ) async {
        persisted.append((item, content))
        _ = store.saveContent(content, for: item)
    }

    func ingestDocument(_ item: SavedItem, store: SavesStore) async {}
    func backfillMissingWebArchives(store: SavesStore) {}
    func backfillMissingThumbnails(store: SavesStore) {}
    func preloadPasteboard(content: ArticleContent, sourceURL: URL) {}
    func doubleSaveDestinationIDs() -> [String] { [] }
    func sendToDestination(_ item: SavedItem, destinationID: String) async {}
    func isDestinationConfigured(_ destinationID: String) -> Bool { false }
}
