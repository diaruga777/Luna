//
//  LiveMediaDownloadJobStore.swift
//  Luna
//

import Foundation
import LunaAppConfig
import LunaStorage

final class JobStore {
    private let lock = NSLock()

    /// Authoritative in-memory copy of jobs.json, loaded lazily on first
    /// access under `lock`. jobs.json has no other writer process, so once
    /// loaded this cache never needs to re-read the file — every mutation
    /// updates it directly and persistence below is purely "flush to disk
    /// for relaunch recovery", not a source of truth for reads.
    private var cachedJobs: [LiveMediaDownloadJob]?

    /// Per-job bookkeeping for throttling disk writes from the per-chunk
    /// progress path (`didWriteData` fires many times/sec). Phase changes
    /// and add/remove always persist immediately; pure progress updates
    /// persist at most ~2x/sec or when the whole-percent value changes.
    private var lastProgressPersist: [String: (date: Date, percent: Int)] = [:]
    private static let progressPersistInterval: TimeInterval = 0.5

    static var directory: URL {
        let fallback = FileManager.default.temporaryDirectory
        let base = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: AppConfig.appGroupID) ?? fallback
        let dir = base.appendingPathComponent("LiveMediaDownloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        BackupPolicy.excludeFromBackups(dir)
        return dir
    }

    private static var jobsURL: URL {
        directory.appendingPathComponent("jobs.json")
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

    /// Must be called under `lock`. Loads jobs.json on the first call in the
    /// process's lifetime; every call after that returns the in-memory copy.
    private func loadJobsLocked() -> [LiveMediaDownloadJob] {
        if let cachedJobs { return cachedJobs }
        let loaded: [LiveMediaDownloadJob]
        if let data = try? Data(contentsOf: Self.jobsURL),
           let decoded = try? JSONDecoder().decode([LiveMediaDownloadJob].self, from: data) {
            loaded = decoded
        } else {
            loaded = []
        }
        cachedJobs = loaded
        return loaded
    }

    private func persistLocked(_ jobs: [LiveMediaDownloadJob]) {
        guard let data = try? JSONEncoder().encode(jobs) else { return }
        try? data.write(to: Self.jobsURL, options: .atomic)
    }

    func jobs() -> [LiveMediaDownloadJob] {
        lock.withLock { loadJobsLocked() }
    }

    func job(id: String) -> LiveMediaDownloadJob? {
        jobs().first { $0.id == id }
    }

    func job(forSourceURLString urlString: String) -> LiveMediaDownloadJob? {
        jobs().first { $0.sourceURLString == urlString && !$0.isTerminal }
    }

    /// `progressOnly` marks a per-chunk progress tick with no phase change —
    /// those persist to disk at most ~2x/sec or on a whole-percent change.
    /// Every other call (add, phase transition, terminal state) always
    /// persists immediately so a background relaunch can restore it.
    func upsert(_ job: LiveMediaDownloadJob, progressOnly: Bool = false) {
        lock.withLock {
            var jobs = loadJobsLocked()
            if let index = jobs.firstIndex(where: { $0.id == job.id }) {
                jobs[index] = job
            } else {
                jobs.append(job)
            }
            cachedJobs = jobs
            if progressOnly, !shouldPersistProgressLocked(for: job) {
                return
            }
            lastProgressPersist[job.id] = (Date(), Int(job.progress * 100))
            persistLocked(jobs)
        }
    }

    /// Must be called under `lock`.
    private func shouldPersistProgressLocked(for job: LiveMediaDownloadJob) -> Bool {
        let percent = Int(job.progress * 100)
        guard let last = lastProgressPersist[job.id] else { return true }
        if percent != last.percent { return true }
        return Date().timeIntervalSince(last.date) >= Self.progressPersistInterval
    }

    func remove(_ id: String) {
        lock.withLock {
            let jobs = loadJobsLocked().filter { $0.id != id }
            cachedJobs = jobs
            lastProgressPersist.removeValue(forKey: id)
            persistLocked(jobs)
        }
    }

    func removeFiles(for job: LiveMediaDownloadJob) {
        lock.withLock {
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
