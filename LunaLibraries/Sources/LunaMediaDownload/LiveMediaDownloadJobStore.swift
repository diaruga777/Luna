//
//  LiveMediaDownloadJobStore.swift
//  Luna
//

import Foundation
import LunaAppConfig
import LunaModels
import LunaStorage

final class JobStore {
    enum InsertResult {
        case inserted(LiveMediaDownloadJob)
        case existing(LiveMediaDownloadJob)
    }

    /// The database the rows live in. Injectable so a test can point a store at
    /// its own scratch container instead of the real library.
    private let store: SavesStore

    /// Per-job bookkeeping for throttling writes from the per-chunk progress path
    /// (`didWriteData` fires many times/sec). Phase changes and add/remove always
    /// write; a pure progress tick writes at most ~2x/sec or when the whole-percent
    /// value changes — the only value any surface renders. Process-local, because
    /// it throttles this process's own writes and nothing else reads it.
    private let throttleLock = NSLock()
    private var lastProgressPersist: [String: (date: Date, percent: Int)] = [:]
    private static let progressPersistInterval: TimeInterval = 0.5

    init(store: SavesStore = .shared) {
        self.store = store
    }

    /// The sibling files a job owns — its download, staging copies, poster and
    /// resume blob — which stay on disk rather than in the database. They are named
    /// from the job id, and so is the background session's `taskDescription`, which
    /// is how a relaunch finds a transfer that outlived the process.
    static var directory: URL {
        let fallback = FileManager.default.temporaryDirectory
        let base = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: AppConfig.appGroupID) ?? fallback
        let dir = base.appendingPathComponent("LiveMediaDownloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        BackupPolicy.excludeFromBackups(dir)
        return dir
    }

    static func downloadURL(fileName: String) -> URL {
        directory.appendingPathComponent(fileName)
    }

    static func stagingURL(fileName: String) -> URL {
        directory.appendingPathComponent(fileName)
    }

    static func thumbnailURL(fileName: String) -> URL {
        directory.appendingPathComponent(fileName)
    }

    static func resumeDataURL(fileName: String) -> URL {
        directory.appendingPathComponent(fileName)
    }

    func jobs() -> [LiveMediaDownloadJob] {
        store.mediaDownloadJobs()
    }

    func job(id: String) -> LiveMediaDownloadJob? {
        store.mediaDownloadJob(id: id)
    }

    func job(forSourceURLString urlString: String) -> LiveMediaDownloadJob? {
        store.mediaDownloadJobs(forSourceURLString: urlString).first { !$0.isTerminal }
    }

    /// Atomically creates `job`, unless a non-terminal job already owns the same
    /// source URL. Starting a transfer has to use this rather than a lookup
    /// followed by `upsert`: the app, the share and action extensions, the Live
    /// Activity widget and the App Clip all start downloads through one background
    /// session, and simultaneous starts would otherwise both create work for a URL.
    func insertIfNoActiveJob(_ job: LiveMediaDownloadJob) -> InsertResult {
        var existing: LiveMediaDownloadJob?
        let inserted = store.insertMediaDownloadJob(
            forSourceURLString: job.sourceURLString
        ) { recorded in
            existing = recorded.first { !$0.isTerminal }
            return existing == nil ? job : nil
        }
        if let inserted { return .inserted(inserted) }
        // A write that lost the race, or a store that could not answer: either way
        // the caller must not start a second transfer for this URL.
        return .existing(existing ?? job)
    }

    /// Applies a read-modify-write update inside one transaction. Background-session
    /// delegates, retry bookkeeping and progress callbacks all arrive
    /// independently; reading a snapshot to edit and writing it back later loses
    /// unrelated fields another writer set in the gap.
    @discardableResult
    func mutate(
        id: String,
        progressOnly: Bool = false,
        _ body: (inout LiveMediaDownloadJob) -> Void
    ) -> LiveMediaDownloadJob? {
        store.mutateMediaDownloadJob(id: id) { job in
            body(&job)
            return self.shouldWrite(job, progressOnly: progressOnly)
        }
    }

    /// `progressOnly` marks a per-chunk progress tick with no phase change. Every
    /// other call — add, phase transition, terminal state — always writes, so a
    /// background relaunch can restore it.
    func upsert(_ job: LiveMediaDownloadJob, progressOnly: Bool = false) {
        guard shouldWrite(job, progressOnly: progressOnly) else { return }
        store.writeMediaDownloadJob(job)
    }

    /// Whether this update earns a write. A throttled progress tick does not: the
    /// whole-percent value a reader would see has not moved.
    private func shouldWrite(_ job: LiveMediaDownloadJob, progressOnly: Bool) -> Bool {
        throttleLock.lock()
        defer { throttleLock.unlock() }
        let percent = Int(job.progress * 100)
        if progressOnly, let last = lastProgressPersist[job.id],
           percent == last.percent,
           Date().timeIntervalSince(last.date) < Self.progressPersistInterval {
            return false
        }
        lastProgressPersist[job.id] = (Date(), percent)
        return true
    }

    func remove(_ id: String) {
        throttleLock.lock()
        lastProgressPersist.removeValue(forKey: id)
        throttleLock.unlock()
        store.deleteMediaDownloadJob(id: id)
    }

    func removeFiles(for job: LiveMediaDownloadJob) {
        let fileManager = FileManager.default
        let urls = (try? fileManager.contentsOfDirectory(
            at: Self.directory,
            includingPropertiesForKeys: nil)) ?? []
        for url in urls where url.lastPathComponent.hasPrefix("\(job.id).") {
            try? fileManager.removeItem(at: url)
        }
        if let thumbnailFileName = job.thumbnailFileName {
            try? fileManager.removeItem(at: Self.thumbnailURL(fileName: thumbnailFileName))
        }
        if let resumeDataFileName = job.resumeDataFileName {
            try? fileManager.removeItem(at: Self.resumeDataURL(fileName: resumeDataFileName))
        }
    }

    func saveResumeData(_ data: Data, for jobID: String) -> String? {
        let fileName = "\(jobID).resumeData"
        do {
            try data.write(to: Self.resumeDataURL(fileName: fileName), options: .atomic)
            return fileName
        } catch {
            return nil
        }
    }

    func resumeData(for job: LiveMediaDownloadJob) -> Data? {
        guard let fileName = job.resumeDataFileName else { return nil }
        return try? Data(contentsOf: Self.resumeDataURL(fileName: fileName))
    }

    func removeResumeData(for job: LiveMediaDownloadJob) {
        guard let fileName = job.resumeDataFileName else { return }
        try? FileManager.default.removeItem(at: Self.resumeDataURL(fileName: fileName))
    }
}
