//
//  TranscriptionJobRunner.swift
//  LunaTranscribe
//

import Foundation
import LunaModels
import LunaSaves
import LunaStorage

/// Keeps the process alive while a job runs. The app shell installs a witness
/// over `UIApplication.beginBackgroundTask`; tests and extensions leave it nil.
public protocol TranscriptionBackgroundLeasing: AnyObject {
    func begin() -> TranscriptionLeaseToken?
    func end(_ token: TranscriptionLeaseToken)
}

public struct TranscriptionLeaseToken: Equatable, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }
}

/// Finishes the transcription jobs the ingest walk parked
/// (`claudedocs/plans/transcription-plugins.md` §5.4).
///
/// One job at a time: download the recording, transcribe it, persist the
/// transcript through the article handler, delete the recording. The job row
/// is the whole state, so a killed process resumes from it at the next
/// `kick()`. A save leaves `.pending` only through `persistArticle`.
@MainActor
public final class TranscriptionJobRunner {

    public static let shared = TranscriptionJobRunner()

    public var lease: (any TranscriptionBackgroundLeasing)?
    /// Nil reads `PluginTranscriptionSeams.reresolver` at the moment of need.
    public var reresolver: (any TranscriptionReresolving)?

    private let store: SavesStore
    private let jobs: TranscriptionJobStore
    private let failures: SaveFailureStore
    private let downloader: any TranscriptionSourceDownloading
    private let engine: any TranscriptionEngine
    private let scratchDirectory: URL
    private let now: () -> Date

    public private(set) var isRunning = false
    /// The recording the job in flight fetched, so it can be unlinked whatever
    /// the row says afterwards: `markDone`, `recordFailure` and the cascade of
    /// a deleted save all clear or remove the row's own `scratch_path`.
    private var scratchInFlight: String?

    public init(
        store: SavesStore = .shared,
        jobs: TranscriptionJobStore = .shared,
        failures: SaveFailureStore = .shared,
        downloader: any TranscriptionSourceDownloading = URLSessionTranscriptionDownloader(),
        engine: any TranscriptionEngine = TranscriptionEngineFactory.make(),
        reresolver: (any TranscriptionReresolving)? = nil,
        lease: (any TranscriptionBackgroundLeasing)? = nil,
        scratchDirectory: URL? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        self.store = store
        self.jobs = jobs
        self.failures = failures
        self.downloader = downloader
        self.engine = engine
        self.reresolver = reresolver
        self.lease = lease
        self.scratchDirectory = scratchDirectory ?? store.transcriptionScratchDirectoryURL
        self.now = now
    }

    /// Starts draining the queue unless a drain is already running.
    public func kick() {
        guard !isRunning else { return }
        Task { await runUntilIdle() }
    }

    /// Drains the queue and returns when no job is runnable. A no-op while a
    /// drain started by `kick()` is running.
    public func runUntilIdle() async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }
        var seen: Set<UUID> = []
        while let job = jobs.nextRunnable(now: now()) {
            // A row that is still runnable after its run would spin the loop.
            guard seen.insert(job.saveID).inserted else { break }
            let token = lease?.begin()
            await run(job)
            if let token { lease?.end(token) }
        }
    }

    // MARK: - One job

    private func run(_ job: TranscriptionJob) async {
        guard let item = store.item(withID: job.saveID) else {
            jobs.delete(saveID: job.saveID)
            return
        }
        let recorder = SaveDiagnosticsRecorder(itemID: item.id)
        scratchInFlight = job.scratchPath
        defer {
            unlinkScratch(named: scratchInFlight)
            scratchInFlight = nil
            flush(recorder)
        }
        guard item.state == .pending else {
            recorder.record(
                "transcription: save is \(item.state.rawValue), nothing to do", category: "transcription")
            jobs.markDone(saveID: job.saveID)
            return
        }
        recorder.record(
            "transcription: attempt \(job.attempts + 1) for \(SaveDiagnostics.url(job.request.fetchURL)) "
                + "(\(job.request.mediaKind.rawValue))",
            category: "transcription")

        do {
            let content = try await produceContent(for: job, item: item, recorder: recorder)
            try await persist(content, for: job, recorder: recorder)
        } catch let error as TranscriptionError {
            fail(job, error: error, recorder: recorder)
        } catch {
            fail(job, error: .transport(error.localizedDescription), recorder: recorder)
        }
    }

    /// The transcript as article content, or the article a re-resolution
    /// handed back directly.
    private func produceContent(
        for job: TranscriptionJob, item: SavedItem, recorder: SaveDiagnosticsRecorder
    ) async throws -> ArticleContent {
        guard engine.availability != .unsupportedOS else { throw TranscriptionError.unsupportedOS }
        var request = job.request
        var reresolved = false

        if let expiresAt = request.expiresAt, expiresAt <= now() {
            recorder.record("transcription: request expired, re-resolving", category: "transcription")
            switch try await reresolve(job, item: item) {
            case let .request(fresh): request = fresh
            case let .article(content): return content
            }
            reresolved = true
        }

        let scratchName = Self.scratchName(for: job.saveID, fetchURL: request.fetchURL)
        let scratchURL = scratchDirectory.appendingPathComponent(scratchName)
        if let previous = scratchInFlight, previous != scratchName { unlinkScratch(named: previous) }
        scratchInFlight = scratchName
        try FileManager.default.createDirectory(at: scratchDirectory, withIntermediateDirectories: true)
        jobs.setStatus(.downloading, saveID: job.saveID, scratchPath: scratchName, now: now())

        do {
            try await downloader.download(request, to: scratchURL)
        } catch TranscriptionError.sourceUnavailable where !reresolved {
            recorder.record("transcription: source refused the fetch, re-resolving", category: "transcription")
            switch try await reresolve(job, item: item) {
            case let .request(fresh): request = fresh
            case let .article(content): return content
            }
            try await downloader.download(request, to: scratchURL)
        }
        recorder.record("transcription: recording fetched", category: "transcription")

        jobs.setStatus(.transcribing, saveID: job.saveID, scratchPath: scratchName, now: now())
        let segments = try await engine.transcribe(
            audioFileURL: scratchURL, mediaKind: request.mediaKind, language: request.language,
            progress: { _ in })
        recorder.record("transcription: \(segments.count) segment(s)", category: "transcription")
        return try TranscriptArticleBuilder.make(segments: segments, request: request)
    }

    private func reresolve(_ job: TranscriptionJob, item: SavedItem) async throws -> TranscriptionReresolution {
        guard let url = item.url,
              let resolver = reresolver ?? PluginTranscriptionSeams.reresolver,
              let resolution = await resolver.reresolve(
                sourceURL: url, pluginID: job.request.pluginID, saveID: job.saveID)
        else { throw TranscriptionError.sourceUnavailable }
        if case let .request(fresh) = resolution {
            jobs.updateRequest(fresh, saveID: job.saveID, now: now())
        }
        return resolution
    }

    private func persist(
        _ content: ArticleContent, for job: TranscriptionJob, recorder: SaveDiagnosticsRecorder
    ) async throws {
        // The save may have gone, or been finished by another process, while
        // the recording was transcribing.
        guard let item = store.item(withID: job.saveID) else {
            recorder.record("transcription: save deleted mid-job", category: "transcription")
            return
        }
        guard item.state == .pending, let url = item.url else {
            recorder.record("transcription: save no longer pending", category: "transcription")
            jobs.markDone(saveID: job.saveID, now: now())
            return
        }
        guard let handler = IngestorKindHandlers.article else {
            throw TranscriptionError.transport("no article handler installed")
        }
        await handler.persistArticle(content, html: "", for: item, url: url, store: store)
        jobs.markDone(saveID: job.saveID, now: now())
        recorder.record("transcription: article persisted", category: "transcription")
    }

    private func fail(_ job: TranscriptionJob, error: TranscriptionError, recorder: SaveDiagnosticsRecorder) {
        let attempts = job.attempts + 1
        let terminal = error.isTerminal || attempts >= TranscriptionRetryPolicy.maxAttempts
        recorder.record(
            "transcription: \(terminal ? "failed" : "retrying later") — \(error)", category: "transcription")
        jobs.recordFailure(saveID: job.saveID, detail: "\(error)", terminal: terminal, now: now())
        guard terminal else { return }
        let reason = SaveFailureReason.transcriptionFailed(error.userFacingDetail)
        recorder.markTerminalFailure(reason)
        store.markFailed(job.saveID)
        failures.recordFailure(job.saveID, reason: reason)
    }

    // MARK: - Files and diagnostics

    /// `<save id>.<extension>`, with the recording's own extension when it has
    /// a plain one and `media` otherwise.
    public static func scratchName(for saveID: UUID, fetchURL: URL) -> String {
        let ext = fetchURL.pathExtension.lowercased()
        let plain = !ext.isEmpty && ext.count <= 5 && ext.allSatisfy { $0.isLetter || $0.isNumber }
        return "\(saveID.uuidString).\(plain ? ext : "media")"
    }

    private func unlinkScratch(named name: String?) {
        guard let name else { return }
        try? FileManager.default.removeItem(at: scratchDirectory.appendingPathComponent(name))
    }

    private func flush(_ recorder: SaveDiagnosticsRecorder) {
        let lines = recorder.drainLines()
        guard !lines.isEmpty else { return }
        SaveDiagnosticsStore.shared.appendLines(lines, for: recorder.itemID)
    }
}
