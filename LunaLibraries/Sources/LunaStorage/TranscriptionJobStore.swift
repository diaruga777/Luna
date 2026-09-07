//
//  TranscriptionJobStore.swift
//  LunaStorage
//

import Foundation
import LunaModels

/// Where a transcription job is in its life. Stored as the raw string with no
/// CHECK constraint; a value this build does not know reads as `.failed`.
public enum TranscriptionJobStatus: String, Equatable, Sendable {
    /// Waiting for the runner. Also the state a transient failure returns to.
    case queued
    case downloading
    case transcribing
    /// The transcript was persisted as the article. The row stays so the launch
    /// sweep keeps skipping the save.
    case done
    /// Terminal. The save is `.failed` with a `SaveFailureReason`.
    case failed

    /// `rawValue` with the unknown-value rule the shared file needs.
    public init(raw: String?) {
        self = raw.flatMap(TranscriptionJobStatus.init(rawValue:)) ?? .failed
    }

    /// Whether a scratch file may legitimately exist for a job in this state.
    public var holdsScratchFile: Bool {
        self == .downloading || self == .transcribing
    }
}

/// One row of `transcriptions`.
public struct TranscriptionJob: Equatable, Sendable {
    public let saveID: UUID
    public let status: TranscriptionJobStatus
    public let request: TranscriptionRequest
    public let attempts: Int
    public let failure: String?
    /// The scratch file's name under the transcription directory while one
    /// exists.
    public let scratchPath: String?
    public let createdAt: Date
    public let updatedAt: Date

    public init(
        saveID: UUID, status: TranscriptionJobStatus, request: TranscriptionRequest,
        attempts: Int, failure: String?, scratchPath: String?, createdAt: Date, updatedAt: Date
    ) {
        self.saveID = saveID
        self.status = status
        self.request = request
        self.attempts = attempts
        self.failure = failure
        self.scratchPath = scratchPath
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// When a job that failed transiently may run again
/// (`claudedocs/plans/transcription-plugins.md` §5.4).
public enum TranscriptionRetryPolicy {
    /// Attempts after which a transient failure becomes terminal.
    public static let maxAttempts = 3

    /// `min(2^attempts, 60)` minutes after the last update; zero for a job that
    /// has never run.
    public static func retryDate(attempts: Int, updatedAt: Date) -> Date {
        guard attempts > 0 else { return updatedAt }
        let minutes = min(pow(2.0, Double(attempts)), 60)
        return updatedAt.addingTimeInterval(minutes * 60)
    }
}

/// The `transcriptions` table (`claudedocs/plans/transcription-plugins.md` §4).
///
/// One row per save, keyed by the save's id and cascading away with it. The
/// row is the job's whole state: a killed process leaves `downloading` or
/// `transcribing` behind and the next runner picks it up again. Every write
/// posts `.savesChanged`, so the pending card re-reads its status line.
///
/// It lives in LunaStorage for the same reason `PendingPluginModelStore` does:
/// the rows are in `saves.sqlite`, and one process opens one connection.
public final class TranscriptionJobStore {
    public static let shared = TranscriptionJobStore()

    private let saves: SavesStore

    public init(saves: SavesStore = .shared) {
        self.saves = saves
    }

    // MARK: - Writes

    /// Queues `request` for `saveID`. A second call for the same save replaces
    /// the request and returns the job to `queued` with its attempts reset.
    public func enqueue(saveID: UUID, request: TranscriptionRequest, now: Date = Date()) {
        guard let json = Self.encode(request) else { return }
        mutate { db in
            try db.run(
                """
                INSERT INTO transcriptions
                    (save_id, status, request_json, attempts, failure, scratch_path,
                     created_at, updated_at)
                VALUES (?, ?, ?, 0, NULL, NULL, ?, ?)
                ON CONFLICT(save_id) DO UPDATE SET
                    status = excluded.status,
                    request_json = excluded.request_json,
                    attempts = 0,
                    failure = NULL,
                    scratch_path = NULL,
                    updated_at = excluded.updated_at
                """
            ) { row in
                try row.bind(1, uuid: saveID)
                try row.bind(2, TranscriptionJobStatus.queued.rawValue)
                try row.bind(3, json)
                try row.bind(4, date: now)
                try row.bind(5, date: now)
            }
        }
    }

    /// Moves a job to `status`. `scratchPath` is written as given, nil included,
    /// so a caller names the file BEFORE the bytes start arriving and clears it
    /// once the file is gone.
    public func setStatus(
        _ status: TranscriptionJobStatus, saveID: UUID, scratchPath: String?, now: Date = Date()
    ) {
        mutate { db in
            try db.run(
                "UPDATE transcriptions SET status = ?, scratch_path = ?, updated_at = ? "
                    + "WHERE save_id = ?"
            ) { row in
                try row.bind(1, status.rawValue)
                try row.bind(2, scratchPath)
                try row.bind(3, date: now)
                try row.bind(4, uuid: saveID)
            }
        }
    }

    /// Replaces the stored request after a re-resolution.
    public func updateRequest(_ request: TranscriptionRequest, saveID: UUID, now: Date = Date()) {
        guard let json = Self.encode(request) else { return }
        mutate { db in
            try db.run(
                "UPDATE transcriptions SET request_json = ?, updated_at = ? WHERE save_id = ?"
            ) { row in
                try row.bind(1, json)
                try row.bind(2, date: now)
                try row.bind(3, uuid: saveID)
            }
        }
    }

    /// Records one failed attempt. A transient failure returns the job to
    /// `queued` for the retry policy to re-time; a terminal one ends it.
    public func recordFailure(saveID: UUID, detail: String, terminal: Bool, now: Date = Date()) {
        let status: TranscriptionJobStatus = terminal ? .failed : .queued
        mutate { db in
            try db.run(
                """
                UPDATE transcriptions
                SET status = ?, attempts = attempts + 1, failure = ?, scratch_path = NULL,
                    updated_at = ?
                WHERE save_id = ?
                """
            ) { row in
                try row.bind(1, status.rawValue)
                try row.bind(2, detail)
                try row.bind(3, date: now)
                try row.bind(4, uuid: saveID)
            }
        }
    }

    public func markDone(saveID: UUID, now: Date = Date()) {
        mutate { db in
            try db.run(
                "UPDATE transcriptions SET status = ?, scratch_path = NULL, failure = NULL, "
                    + "updated_at = ? WHERE save_id = ?"
            ) { row in
                try row.bind(1, TranscriptionJobStatus.done.rawValue)
                try row.bind(2, date: now)
                try row.bind(3, uuid: saveID)
            }
        }
    }

    public func delete(saveID: UUID) {
        mutate { db in
            try db.run("DELETE FROM transcriptions WHERE save_id = ?") { row in
                try row.bind(1, uuid: saveID)
            }
        }
    }

    // MARK: - Reads

    public func hasJob(saveID: UUID) -> Bool {
        job(saveID: saveID) != nil
    }

    public func status(saveID: UUID) -> TranscriptionJobStatus? {
        job(saveID: saveID)?.status
    }

    public func job(saveID: UUID) -> TranscriptionJob? {
        read(where: "save_id = ?", bind: { try $0.bind(1, uuid: saveID) }).first
    }

    /// Every save that has a row, whatever its status. The launch sweep reads
    /// this once and leaves those saves to the runner.
    public func saveIDsWithJobs() -> Set<UUID> {
        saves.pluginSidecar { db in
            var ids: Set<UUID> = []
            try db.query("SELECT save_id FROM transcriptions") { row in
                if let text = row.string(0), let id = UUID(uuidString: text) { ids.insert(id) }
            }
            return ids
        } ?? []
    }

    /// The job the runner should take next, oldest first: a `downloading` or
    /// `transcribing` row a killed process left behind, or a `queued` row whose
    /// retry time has come. Nil when nothing is due.
    public func nextRunnable(now: Date = Date()) -> TranscriptionJob? {
        let candidates = read(
            where: "status IN (?, ?, ?)",
            bind: { row in
                try row.bind(1, TranscriptionJobStatus.queued.rawValue)
                try row.bind(2, TranscriptionJobStatus.downloading.rawValue)
                try row.bind(3, TranscriptionJobStatus.transcribing.rawValue)
            })
        return candidates.first { job in
            switch job.status {
            case .downloading, .transcribing:
                return true
            case .queued:
                return TranscriptionRetryPolicy.retryDate(
                    attempts: job.attempts, updatedAt: job.updatedAt) <= now
            case .done, .failed:
                return false
            }
        }
    }

    /// The scratch file names a live job still owns. Everything else under the
    /// scratch directory is sweepable.
    public func liveScratchPaths() -> Set<String> {
        saves.pluginSidecar { db in
            var paths: Set<String> = []
            try db.query(
                "SELECT scratch_path FROM transcriptions WHERE status IN (?, ?) "
                    + "AND scratch_path IS NOT NULL",
                { row in
                    try row.bind(1, TranscriptionJobStatus.downloading.rawValue)
                    try row.bind(2, TranscriptionJobStatus.transcribing.rawValue)
                }
            ) { row in
                if let path = row.string(0) { paths.insert(path) }
            }
            return paths
        } ?? []
    }

    /// Every row, oldest first. Diagnostics and tests.
    public func allJobs() -> [TranscriptionJob] {
        read(where: "1", bind: { _ in })
    }

    // MARK: - Plumbing

    private func mutate(_ body: (SavesDatabase) throws -> Void) {
        saves.pluginSidecar(body)
        saves.notifySidecarChanged()
    }

    private func read(
        where clause: String, bind: @escaping (SavesStatement) throws -> Void
    ) -> [TranscriptionJob] {
        saves.pluginSidecar { db in
            var jobs: [TranscriptionJob] = []
            try db.query(
                """
                SELECT save_id, status, request_json, attempts, failure, scratch_path,
                       created_at, updated_at
                FROM transcriptions WHERE \(clause) ORDER BY created_at
                """,
                bind
            ) { row in
                guard let idText = row.string(0), let id = UUID(uuidString: idText),
                      let json = row.string(2), let request = Self.decode(json)
                else { return }
                let now = Date()
                jobs.append(TranscriptionJob(
                    saveID: id,
                    status: TranscriptionJobStatus(raw: row.string(1)),
                    request: request,
                    attempts: row.int(3) ?? 0,
                    failure: row.string(4),
                    scratchPath: row.string(5),
                    createdAt: row.date(6) ?? now,
                    updatedAt: row.date(7) ?? now))
            }
            return jobs
        } ?? []
    }

    private static func encode(_ request: TranscriptionRequest) -> String? {
        guard let data = try? JSONEncoder().encode(request) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func decode(_ json: String) -> TranscriptionRequest? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(TranscriptionRequest.self, from: data)
    }
}
