//
//  LiveMediaDownloadManager.swift
//  Luna
//

import LunaAppConfig
import LunaModels
import LunaStorage
import LunaURLClassification
import AVFoundation
import Foundation
import ImageIO
import Photos
import UIKit

public enum LiveMediaDownloadOwnership: String, Codable {
    case downloader
    case invokingApp
}

public enum LiveMediaDownloadStartPolicy {
    public static func downloaderShouldStart(
        storageState: SavedMediaItem.StorageState?
    ) -> Bool {
        switch storageState {
        case .localFile, .photosReference: return false
        case .undownloaded, .none: return true
        }
    }
}

/// Decides whether a persisted job needs its URLSession transfer recreated after
/// process death. A background task normally survives relaunch; the restart is
/// only for the small persist-before-task window (or an otherwise lost task).
enum LiveMediaDownloadResumePolicy {
    static func shouldRestart(
        phase: LiveMediaDownloadJob.Phase, hasActiveTask: Bool
    ) -> Bool {
        guard !hasActiveTask else { return false }
        return phase == .resolving || phase == .downloading || phase == .waiting
    }
}

/// Whether a Downloader-owned start should be deferred until Wi-Fi rather than
/// starting immediately. Pulled out as a pure function so all four inputs are
/// covered by unit tests without needing a live `URLSession`/network stack.
public enum WiFiOnlyDownloadGate {
    public static func shouldDefer(
        ownership: LiveMediaDownloadOwnership, manual: Bool,
        wifiOnlyEnabled: Bool, isOnWiFi: Bool
    ) -> Bool {
        ownership == .downloader && !manual && wifiOnlyEnabled && !isOnWiFi
    }
}

extension Notification.Name {
    /// Posted with `userInfo: ["sourceURLString": String, "progress": Double,
    /// "snapshot": DownloaderJobSnapshot]` (progress/snapshot keys ABSENT means
    /// "no active job, reset to static state") each time a Downloader-owned
    /// job's live state changes, so the grid can update a single cell's ring
    /// without a full reload and the footer status view can mirror the Live
    /// Activity. Grid/footer-facing only — unrelated to `.savedMediaChanged`,
    /// which fires on durable storage-state transitions (completion/deletion),
    /// not in-flight progress ticks.
    public static let downloaderJobProgressChanged = Notification.Name("Luna.downloaderJobProgressChanged")
}

/// The phase of a Downloader-owned job, mirrored for consumers outside this
/// module (the footer status view) that can't see the internal job type.
public enum DownloaderJobPhase: String {
    case resolving
    case downloading
    case waiting
    case suspended
    case saving
    case finished
    case failed
}

/// A snapshot of a Downloader-owned job's public-facing state — everything the
/// footer status view needs to mirror the Live Activity (title, phase/message,
/// progress, thumbnail).
public struct DownloaderJobSnapshot: Equatable {
    /// Why a `.failed` job failed, when known — lets the Downloader offer the
    /// URL-rescue "Try Apple Intelligence" affordance only for `.noMedia`.
    public enum FailureKind: String, Equatable {
        case noMedia
        case other
    }
    public let sourceURLString: String
    public let title: String
    public let phase: DownloaderJobPhase
    public let progress: Double
    public let message: String
    public let thumbnailFileName: String?
    public let failureKind: FailureKind?

    /// Public so a caller outside this module can DESCRIBE a job state without
    /// running one. The synthesized memberwise init is internal, which left the
    /// download states (queued, mid-transfer, failed, no-media) reachable only
    /// by starting a real transfer and catching it at the right millisecond.
    /// Staged mode builds them directly instead (`claudedocs/staging.md`).
    public init(
        sourceURLString: String, title: String, phase: DownloaderJobPhase,
        progress: Double, message: String, thumbnailFileName: String? = nil,
        failureKind: FailureKind? = nil
    ) {
        self.sourceURLString = sourceURLString
        self.title = title
        self.phase = phase
        self.progress = progress
        self.message = message
        self.thumbnailFileName = thumbnailFileName
        self.failureKind = failureKind
    }
}

func postDownloaderJobProgress(job: LiveMediaDownloadJob, progress: Double?) {
    var userInfo: [AnyHashable: Any] = [
        "sourceURLString": job.sourceURLString,
        "snapshot": job.downloaderSnapshot,
    ]
    if let progress { userInfo["progress"] = progress }
    let post = {
        NotificationCenter.default.post(
            name: .downloaderJobProgressChanged, object: nil, userInfo: userInfo)
    }
    // NotificationCenter invokes selector observers synchronously on the posting
    // thread. The Downloader footer mutates UIKit, while progress originates from
    // async ingestion and URLSession delegate queues, so UI-facing delivery must
    // always cross to the main queue first.
    if Thread.isMainThread {
        post()
    } else {
        DispatchQueue.main.async(execute: post)
    }
}

/// Signals that a Downloader-owned job is gone with no result to show (a
/// suspended job torn down after the resume grace period expires) — the
/// footer/grid should reset to the static "undownloaded" state immediately.
private func postDownloaderJobEnded(sourceURLString: String) {
    let post = {
        NotificationCenter.default.post(
            name: .downloaderJobProgressChanged, object: nil,
            userInfo: ["sourceURLString": sourceURLString])
    }
    if Thread.isMainThread {
        post()
    } else {
        DispatchQueue.main.async(execute: post)
    }
}

/// Keeps the short app-owned legs around a background `URLSession` transfer
/// alive when the user backgrounds the app: preflight before a task is
/// registered, local mux/trim work between tasks, and final persistence after
/// the system has delivered the downloaded file. The transfer itself remains
/// owned by `URLSession`; this lease only bridges the gaps where there is no
/// system-owned task yet (or anymore).
///
/// Two things it must never do, both learned the hard way:
///
///  - **Touch `UIApplication` in an `.appex`.** The share/action extensions reach
///    the very same start path (`ShareViewController.autoDownloadThenComplete` →
///    `MediaAutoDownloader.startLiveActivityIfEnabled` → `start` →
///    `startReportingResult`), and `UIApplication.shared` returns nil in an app
///    extension — through Swift's non-optional bridge that is a trap, i.e. a
///    crash on every share-sheet media save. An extension has no app lifetime to
///    extend anyway (the host decides when it dies), so the lease is simply inert
///    there. Same `Bundle.main.bundleURL.pathExtension` test `NotificationManager`
///    and `GazeTracker` use.
///  - **Block a cooperative-pool thread on the main queue.** Leases are
///    constructed from `async` contexts, and a `DispatchQueue.main.sync` from one
///    of those is a priority inversion at exactly the busiest moment (launch,
///    where `resumeLiveActivities` now takes one). Acquisition hops
///    asynchronously instead; `end()` arriving first is handled rather than
///    raced — the begin block sees `hasEnded` and immediately returns the task it
///    was just given.
private final class MediaBackgroundTaskLease: @unchecked Sendable {
    private let lock = NSLock()
    private var identifier: UIBackgroundTaskIdentifier = .invalid
    private var hasEnded = false

    /// No `UIApplication` here — see the type's note.
    private static var isAppExtension: Bool {
        Bundle.main.bundleURL.pathExtension == "appex"
    }

    init(name: String) {
        guard !Self.isAppExtension else {
            hasEnded = true
            return
        }
        let begin = {
            let taskIdentifier = UIApplication.shared.beginBackgroundTask(
                withName: name
            ) { [weak self] in
                self?.end()
            }
            self.lock.lock()
            guard !self.hasEnded else {
                self.lock.unlock()
                if taskIdentifier != .invalid {
                    UIApplication.shared.endBackgroundTask(taskIdentifier)
                }
                return
            }
            self.identifier = taskIdentifier
            self.lock.unlock()
        }
        if Thread.isMainThread {
            begin()
        } else {
            DispatchQueue.main.async(execute: begin)
        }
    }

    func end() {
        let taskIdentifier: UIBackgroundTaskIdentifier
        lock.lock()
        guard !hasEnded else {
            lock.unlock()
            return
        }
        hasEnded = true
        taskIdentifier = identifier
        identifier = .invalid
        lock.unlock()

        guard taskIdentifier != .invalid else { return }
        let finish = {
            UIApplication.shared.endBackgroundTask(taskIdentifier)
        }
        if Thread.isMainThread {
            finish()
        } else {
            DispatchQueue.main.async(execute: finish)
        }
    }

    deinit { end() }
}

public final class LiveMediaDownloadManager: NSObject {
    /// `LiveMediaDownloadJob.ResolveKind` is the persisted type; this file's own
    /// dispatch logic is dense enough with it to keep referring to it unqualified.
    private typealias ResolveKind = LiveMediaDownloadJob.ResolveKind

    public static let shared = LiveMediaDownloadManager()

    private static let sessionIdentifier = "com.hsanabria.luna.mediaDownload.background"
    static let failureDismissalDelay: TimeInterval = 14
    private static let maxTransientAttempts = 2
    private static let suspensionGracePeriod: TimeInterval = 5
    private let store = JobStore()
    private let saver: PhotoLibrarySaving
    private var backgroundCompletionHandler: (() -> Void)?
    private let backgroundWorkLock = NSLock()
    private var pendingBackgroundWork = 0
    private var backgroundEventsFinished = false

    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.background(
            withIdentifier: Self.sessionIdentifier)
        configuration.sharedContainerIdentifier = AppConfig.appGroupID
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 7 * 24 * 60 * 60
        // YouTube's working no-token player client is bound to the guest
        // VISITOR/YSC session established by the preceding watch-page request.
        // Use the shared persistent cookie jar so that binding survives every
        // background resolve stage and an app relaunch.
        configuration.httpCookieStorage = .shared
        configuration.httpShouldSetCookies = true
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    public init(saver: PhotoLibrarySaving = PhotoLibrarySaver()) {
        self.saver = saver
        super.init()
    }

    @discardableResult
    public func start(
        urlString: String,
        title: String? = nil,
        ownership: LiveMediaDownloadOwnership? = nil,
        manual: Bool = false
    ) async -> Bool {
        if case .started = await startReportingResult(
            urlString: urlString, title: title, ownership: ownership, manual: manual) {
            return true
        }
        return false
    }

    /// `start` with the REASON a start didn't happen preserved. The Bool form
    /// above collapses "already in the library", "deferred until Wi-Fi", and a
    /// genuine failure into one `false`, which is exactly the ambiguity that let
    /// the App Intent media handoff report silent success with nothing
    /// downloaded (see `MediaIntentHandoff`). Only this method can tell them
    /// apart, because only the gate below knows which guard ended the start.
    public func startReportingResult(
        urlString: String,
        title: String? = nil,
        ownership: LiveMediaDownloadOwnership? = nil,
        manual: Bool = false
    ) async -> LiveMediaDownloadStartResult {
        // Resolution can cross several awaited gates before the named
        // background URLSession owns a task. If the app is backgrounded during
        // that window, keep the preparation alive long enough to persist and
        // register the durable transfer.
        let backgroundLease = MediaBackgroundTaskLease(name: "MediaDownloadStart")
        defer { backgroundLease.end() }
        let gated: GateResult
        switch await gateAndPrepare(
            urlString: urlString, title: title, ownership: ownership, manual: manual) {
        case let .rejected(result): return result
        case let .proceed(result): gated = result
        }

        switch await attachToExistingJobIfPresent(gated) {
        case .attached(let succeeded):
            return succeeded ? .started : .failed(message: nil)
        case .notFound: break
        }

        return await createAndStartJob(gated, title: title) ? .started : .failed(message: nil)
    }

    /// The state a resolved, gate-passed start carries into the two phases
    /// below, so neither has to re-derive it from the raw arguments.
    private struct GateResult {
        let urlString: String
        let sourceURL: URL
        let ownership: LiveMediaDownloadOwnership
        let readingItem: ReadingListItem?
    }

    /// Either the gate-passed state or the reason the start ended in the gate.
    private enum GateOutcome {
        case proceed(GateResult)
        case rejected(LiveMediaDownloadStartResult)
    }

    /// Canonicalizes the URL, checks platform support, resolves ownership, and
    /// runs every guard that can end the start before a job is ever touched:
    /// the already-downloaded check, the Downloader Wi-Fi-only defer, and the
    /// Photos add-authorization prompt. Each early return names WHY it ended, so
    /// `startReportingResult` can distinguish "nothing to do" from "this failed".
    private func gateAndPrepare(
        urlString: String, title: String?, ownership: LiveMediaDownloadOwnership?, manual: Bool
    ) async -> GateOutcome {
        await reapExpiredSuspensions()

        let urlString = await Self.canonicalRedditURLStringIfNeeded(urlString)

        guard MediaDownloadablePlatform.supports(urlString),
              let sourceURL = URL(string: urlString)
        else { return .rejected(.unsupported) }

        let ownership = ownership ?? (MediaAutoDownloader.isRunningInDownloader
            ? .downloader : .invokingApp)
        if let storageError = MediaDownloadPreflight.storageError(
            expectedByteCount: nil,
            directory: JobStore.directory
        ) {
            await startFailedActivity(
                urlString: urlString, title: title, message: storageError.message)
            return .rejected(.failed(message: storageError.message))
        }
        let readingItem = ReadingListStore.shared.item(forURLString: urlString)
        if ownership == .downloader {
            let savedItem = try? SavedMediaStore.shared.ensureUndownloaded(
                id: readingItem?.id ?? UUID(),
                sourceURLString: urlString,
                title: title ?? readingItem?.title,
                creator: readingItem?.channelName,
                dateSaved: readingItem?.dateAdded ?? Date())
            if !LiveMediaDownloadStartPolicy.downloaderShouldStart(
                storageState: savedItem?.storageState
            ) {
                // The durable Downloader library, not the legacy URL marker, is
                // authoritative for Downloader-owned completion.
                AutoDownloadSettings.markDownloaded(urlString)
                return .rejected(.alreadyDownloaded)
            } else {
                // Repair state left by an interrupted/crashed inline download or
                // by an older sibling-app Photos save. Such a marker must not
                // suppress creation/restart of the Downloader background job.
                AutoDownloadSettings.unmarkDownloaded(urlString)
            }
            if WiFiOnlyDownloadGate.shouldDefer(
                ownership: ownership, manual: manual,
                wifiOnlyEnabled: AutoDownloadSettings.wifiOnlyDownloads,
                isOnWiFi: NetworkReachability.shared.isOnWiFi
            ) {
                AutoDownloadSettings.markPendingWiFiDownload(urlString)
                return .rejected(.deferredUntilWiFi)
            }
        } else if AutoDownloadSettings.wasDownloaded(urlString) {
            return .rejected(.alreadyDownloaded)
        }

        let canSave = ownership == .downloader
            ? true
            : await saver.requestAddAuthorization()
        guard canSave else {
            await startFailedActivity(
                urlString: urlString,
                title: title,
                message: MediaDownloadError.permissionDenied.message,
                errorKind: .photosPermission)
            return .rejected(.notAuthorized)
        }

        return .proceed(GateResult(
            urlString: urlString, sourceURL: sourceURL, ownership: ownership,
            readingItem: readingItem))
    }

    private enum ExistingJobOutcome {
        case notFound
        case attached(Bool)
    }

    /// Repairs and reattaches to a non-terminal job already tracking this
    /// source URL, if one exists — a duplicate paste is treated as an
    /// explicit retry, not a no-op.
    private func attachToExistingJobIfPresent(_ gated: GateResult) async -> ExistingJobOutcome {
        guard var existing = store.jobs().first(where: {
            $0.sourceURLString == gated.urlString && !$0.isTerminal
        }) else { return .notFound }

        if gated.ownership == .downloader && !existing.isDownloaderOwned {
            existing.ownership = .downloader
            store.upsert(existing)
        }
        // A previous process may have died after persisting this job but
        // before creating its URLSession task. A duplicate paste is an
        // explicit retry and must repair that orphan instead of returning
        // success for work that can never advance.
        let activeJobIDs = await activeTaskJobIDs()
        if LiveMediaDownloadResumePolicy.shouldRestart(
            phase: existing.phase,
            hasActiveTask: activeJobIDs.contains(existing.id)
        ) {
            await restartTransfer(for: existing)
            guard let restarted = store.job(id: existing.id), !restarted.isTerminal else {
                return .attached(false)
            }
            existing = restarted
        }
        await updateActivity(for: existing)
        return .attached(true)
    }

    /// Creates the persisted job and starts its resolve task — reached only
    /// when no existing job for this source URL was found above.
    /// Downloads media assets ALREADY resolved by the URL-rescue engine
    /// (`claudedocs/url-rescue.md`), skipping the platform-support gate that
    /// normally rejects a raw CDN URL — the assets are in hand, so there is
    /// nothing to resolve. Ownership + Photos authorization still apply. Returns
    /// true when a download was started.
    public func startWithResolvedAssets(
        sourceURLString: String, title: String?, assets: [MediaAsset]
    ) async -> Bool {
        await startResultWithResolvedAssets(
            sourceURLString: sourceURLString, title: title, assets: assets) == .started
    }

    /// `startWithResolvedAssets` with the REASON a start didn't happen preserved,
    /// for the same reason `startReportingResult` exists beside `start`: Safari's
    /// hand-off has to tell "there is nothing to do here, go back to your page"
    /// apart from "nothing happened at all", and only the guards below know
    /// which.
    public func startResultWithResolvedAssets(
        sourceURLString: String, title: String?, assets: [MediaAsset]
    ) async -> LiveMediaDownloadStartResult {
        guard let asset = assets.first, let sourceURL = URL(string: sourceURLString)
        else { return .unsupported }
        let backgroundLease = MediaBackgroundTaskLease(name: "ResolvedMediaDownloadStart")
        defer { backgroundLease.end() }
        let ownership: LiveMediaDownloadOwnership = MediaAutoDownloader.isRunningInDownloader
            ? .downloader : .invokingApp
        // Non-Downloader saves write straight to Photos, so we need add-authorization.
        let canSave = ownership == .downloader ? true : await saver.requestAddAuthorization()
        guard canSave else {
            await startFailedActivity(
                urlString: sourceURLString, title: title,
                message: MediaDownloadError.permissionDenied.message, errorKind: .photosPermission)
            return .notAuthorized
        }
        let readingItem = ReadingListStore.shared.item(forURLString: sourceURLString)
        if ownership == .downloader {
            guard let pending = try? SavedMediaStore.shared.ensureUndownloaded(
                id: readingItem?.id ?? UUID(),
                sourceURLString: sourceURLString,
                title: title ?? readingItem?.title,
                creator: readingItem?.channelName,
                dateSaved: readingItem?.dateAdded ?? Date())
            else {
                await startFailedActivity(
                    urlString: sourceURLString, title: title,
                    message: MediaDownloadError.saveFailed.message)
                return .failed(message: MediaDownloadError.saveFailed.message)
            }
            guard LiveMediaDownloadStartPolicy.downloaderShouldStart(
                storageState: pending.storageState
            ) else { return .alreadyDownloaded }
        }
        if let existing = store.jobs().first(where: {
            $0.sourceURLString == sourceURLString && !$0.isTerminal
        }) {
            await updateActivity(for: existing)
            return .started
        }
        var job = LiveMediaDownloadJob(
            id: UUID().uuidString,
            sourceURLString: sourceURLString,
            assetURLString: asset.url.absoluteString,
            mediaKind: asset.kind,
            title: title ?? readingItem?.title ?? Self.title(for: sourceURL),
            creator: readingItem?.channelName,
            resolveKind: .rescue,
            phase: .downloading,
            progress: 0,
            thumbnailFileName: nil,
            fileExtension: nil,
            expectedByteCount: asset.estimatedByteCount,
            receivedByteCount: nil,
            resumeDataFileName: nil,
            timeRange: nil,
            resolvedVideoID: nil,
            youtubeVisitorData: nil,
            errorMessage: nil,
            errorKind: nil,
            resolveAttempts: 0,
            mediaAttempts: 0,
            suspendDeadline: nil,
            ownership: ownership,
            audioURLString: asset.audioURL?.absoluteString,
            dashManifestURLString: asset.dashManifestURL?.absoluteString)
        store.upsert(job)
        if job.isDownloaderOwned { postDownloaderJobProgress(job: job, progress: 0) }
        await startActivity(for: job)
        // The durable destination + job are the handoff boundary. Preflight is
        // app-owned work and therefore holds its own background lease; once it
        // registers the download task, the named background URLSession takes
        // over. This lets a Safari handoff return immediately without reopening
        // the old persist-before-task suspension hole.
        startMediaDownload(for: job, asset: asset)
        return .started
    }

    private func createAndStartJob(_ gated: GateResult, title: String?) async -> Bool {
        let jobID = UUID().uuidString
        var job = LiveMediaDownloadJob(
            id: jobID,
            sourceURLString: gated.urlString,
            assetURLString: nil,
            mediaKind: nil,
            title: title ?? Self.title(for: gated.sourceURL),
            creator: gated.readingItem?.channelName,
            resolveKind: nil,
            phase: .resolving,
            progress: 0,
            thumbnailFileName: nil,
            fileExtension: nil,
            expectedByteCount: nil,
            receivedByteCount: nil,
            resumeDataFileName: nil,
            timeRange: nil,
            resolvedVideoID: nil,
            youtubeVisitorData: nil,
            errorMessage: nil,
            errorKind: nil,
            resolveAttempts: 0,
            mediaAttempts: 0,
            suspendDeadline: nil,
            ownership: gated.ownership
        )
        if let youtube = YouTubeLink(url: gated.sourceURL) {
            job.resolvedVideoID = youtube.videoID
            job.timeRange = youtube.timeRange
        }
        if let directAsset = MediaAsset.direct(url: gated.sourceURL) {
            job.resolveKind = .direct
            store.upsert(job)
            if job.isDownloaderOwned {
                postDownloaderJobProgress(job: job, progress: 0)
            }
            await startActivity(for: job)
            startMediaDownload(for: job, asset: directAsset)
            return true
        }
        guard let resolve = Self.resolveRequest(for: gated.sourceURL) else {
            store.upsert(job)
            await failJob(job, message: MediaDownloadError.unsupported.message)
            return false
        }
        job.resolveKind = ResolveKind(rawValue: resolve.kind)
        store.upsert(job)
        // Register the durable background task before any UI-facing callback, so a
        // process death right after this point still has a real transfer to resume —
        // never just a persisted job stuck at "resolving" forever.
        startTask(resolve.request, jobID: job.id, role: .resolve, attempt: job.resolveAttempts)
        if let thumbnailURL = YouTubeLink(url: gated.sourceURL)?.thumbnailURL {
            Task { await self.fetchAndPublishThumbnail(from: thumbnailURL, jobID: job.id) }
        }
        if job.isDownloaderOwned {
            postDownloaderJobProgress(job: job, progress: 0)
        }
        await startActivity(for: job)
        return true
    }

    private func startMediaDownload(for job: LiveMediaDownloadJob, asset: MediaAsset) {
        startTrackedBackgroundWork {
            await self.prepareAndStartMediaDownload(for: job, asset: asset)
        }
    }

    /// Runs the two checks that need a resolved asset: determine its actual size
    /// and verify storage before creating the background transfer. Poster fetching
    /// runs independently so the card/Live Activity can become visual as soon as
    /// the resolver exposes a thumbnail.
    private func prepareAndStartMediaDownload(
        for persistedJob: LiveMediaDownloadJob, asset: MediaAsset
    ) async {
        guard let sourceURL = URL(string: persistedJob.sourceURLString),
              var job = store.job(id: persistedJob.id), !job.isTerminal
        else { return }

        let thumbnailURL: URL?
        switch asset.kind {
        case .image, .gif:
            thumbnailURL = asset.thumbnailURL ?? asset.url
        case .video, .audio:
            thumbnailURL = asset.thumbnailURL
        }
        if let thumbnailURL, job.thumbnailFileName == nil {
            Task { await self.fetchAndPublishThumbnail(from: thumbnailURL, jobID: job.id) }
        }

        let expected = await MediaDownloadPreflight.expectedByteCount(
            for: asset, sourceURL: sourceURL)
        guard let current = store.job(id: job.id), !current.isTerminal else { return }
        job = current
        if let storageError = MediaDownloadPreflight.storageError(
            expectedByteCount: expected,
            directory: JobStore.directory,
            requiresProcessingCopy: asset.timeRange?.isEffective == true
        ) {
            await failJob(job, message: storageError.message)
            return
        }

        job.assetURLString = asset.url.absoluteString
        job.audioURLString = asset.audioURL?.absoluteString
        job.dashManifestURLString = asset.dashManifestURL?.absoluteString
        job.mediaKind = asset.kind
        job.fileExtension = MediaFileDownloader.fileExtension(for: asset, mimeType: nil)
        job.expectedByteCount = expected
        job.timeRange = asset.timeRange
        job.phase = .downloading
        job.errorMessage = nil
        store.upsert(job)
        await updateActivity(for: job)
        if job.isDownloaderOwned {
            postDownloaderJobProgress(job: job, progress: job.progress)
        }

        if let audioURL = asset.audioURL {
            startRedditMuxedDownload(
                for: job, videoURL: asset.url, audioURL: audioURL,
                dashManifestURL: asset.dashManifestURL)
            return
        }

        startTask(
            Self.mediaAssetRequest(assetURL: asset.url, sourceURL: sourceURL),
            jobID: job.id, role: .media, attempt: job.mediaAttempts,
            expectedByteCount: expected)
    }

    private func fetchAndPublishThumbnail(from url: URL, jobID: String) async {
        guard let fileName = await makeThumbnail(from: url, jobID: jobID),
              var job = store.job(id: jobID), !job.isTerminal
        else { return }
        job.thumbnailFileName = fileName
        store.upsert(job)
        await updateActivity(for: job)
        if job.isDownloaderOwned {
            postDownloaderJobProgress(job: job, progress: job.progress)
        }
    }

    public func attachBackgroundCompletionHandler(_ completionHandler: @escaping () -> Void) {
        backgroundWorkLock.lock()
        backgroundCompletionHandler = completionHandler
        backgroundEventsFinished = false
        backgroundWorkLock.unlock()
        _ = session
        startTrackedBackgroundWork { await self.reapExpiredSuspensions() }
    }

    /// Work launched from a background-session delegate callback must finish (or
    /// register its next background task) before the AppDelegate completion
    /// handler is released. Otherwise iOS is free to freeze the process between
    /// the download reaching 100% and the file entering `SavedMediaStore`.
    private func startTrackedBackgroundWork(
        _ operation: @escaping () async -> Void
    ) {
        let appBackgroundLease = MediaBackgroundTaskLease(name: "MediaDownloadTransition")
        backgroundWorkLock.lock()
        pendingBackgroundWork += 1
        backgroundWorkLock.unlock()
        Task {
            await operation()
            self.finishTrackedBackgroundWork()
            appBackgroundLease.end()
        }
    }

    private func finishTrackedBackgroundWork() {
        let completion: (() -> Void)?
        backgroundWorkLock.lock()
        pendingBackgroundWork = max(0, pendingBackgroundWork - 1)
        completion = takeBackgroundCompletionIfReadyLocked()
        backgroundWorkLock.unlock()
        if let completion { DispatchQueue.main.async(execute: completion) }
    }

    private func markBackgroundEventsFinished() {
        let completion: (() -> Void)?
        backgroundWorkLock.lock()
        backgroundEventsFinished = true
        completion = takeBackgroundCompletionIfReadyLocked()
        backgroundWorkLock.unlock()
        if let completion { DispatchQueue.main.async(execute: completion) }
    }

    private func takeBackgroundCompletionIfReadyLocked() -> (() -> Void)? {
        guard backgroundEventsFinished, pendingBackgroundWork == 0 else { return nil }
        let completion = backgroundCompletionHandler
        backgroundCompletionHandler = nil
        backgroundEventsFinished = false
        return completion
    }

    public func resumeLiveActivities() {
        startTrackedBackgroundWork {
            await self.resumeUnfinishedDownloads()
        }
    }

    /// Restarts every persisted transfer that no longer has a live background
    /// task. Used on launch/foreground and by the overnight processing job.
    public func resumeUnfinishedDownloads() async {
        await reapExpiredSuspensions()
        let activeJobIDs = await activeTaskJobIDs()
        for job in store.jobs().filter({ !$0.isTerminal }) {
            if job.phase == .saving {
                resumeFinalization(for: job)
                continue
            }
            if LiveMediaDownloadResumePolicy.shouldRestart(
                phase: job.phase,
                hasActiveTask: activeJobIDs.contains(job.id)
            ) {
                await restartTransfer(for: job)
            }
            // Restart can reject an invalid persisted URL and remove its job;
            // never recreate UI/activity state from the stale pre-repair copy.
            guard let current = store.job(id: job.id), !current.isTerminal else { continue }
            await updateActivity(for: current)
            if current.isDownloaderOwned {
                postDownloaderJobProgress(job: current, progress: current.progress)
            }
        }
        if AutoDownloadSettings.wifiOnlyDownloads {
            await resumePendingWiFiDownloads()
        } else {
            await startPendingWiFiDownloads(manual: true)
        }
    }

    /// Job ids currently backed by a real URLSession task. `taskDescription`
    /// persists with background tasks, making it the join key to `jobs.json`.
    private func activeTaskJobIDs() async -> Set<String> {
        await withCheckedContinuation { continuation in
            session.getAllTasks { tasks in
                continuation.resume(returning: Set(tasks.compactMap { task in
                    Self.taskParts(task.taskDescription ?? "")?.jobID
                }))
            }
        }
    }

    /// Recreates the missing transfer for a persisted resolving/downloading job.
    /// Used both on launch and when the user pastes the same interrupted URL.
    private func restartTransfer(for persistedJob: LiveMediaDownloadJob) async {
        var job = persistedJob
        switch job.phase {
        case .resolving:
            guard let sourceURL = URL(string: job.sourceURLString)
            else {
                await failJob(job, message: MediaDownloadError.unsupported.message)
                return
            }
            if let directAsset = MediaAsset.direct(url: sourceURL) {
                startMediaDownload(for: job, asset: directAsset)
                return
            }
            guard let resolve = Self.resolveRequest(for: sourceURL) else {
                await failJob(job, message: MediaDownloadError.unsupported.message)
                return
            }
            job.resolveKind = ResolveKind(rawValue: resolve.kind)
            job.errorMessage = nil
            store.upsert(job)
            startTask(
                resolve.request, jobID: job.id,
                role: .resolve, attempt: job.resolveAttempts)

        case .downloading, .waiting:
            guard let assetURLString = job.assetURLString,
                  let assetURL = URL(string: assetURLString),
                  let sourceURL = URL(string: job.sourceURLString)
            else {
                // Incomplete old/corrupt downloading state can still be rebuilt
                // from the source resolver instead of remaining stuck forever.
                // This recurses into restartTransfer once, deliberately: job.phase
                // is set to .resolving right above, so the recursive call lands in
                // the .resolving case (or fails and returns there) and can never
                // reach this .downloading branch again.
                job.phase = .resolving
                job.progress = 0
                job.assetURLString = nil
                job.resolveKind = nil
                store.upsert(job)
                await restartTransfer(for: job)
                return
            }
            if let storageError = MediaDownloadPreflight.storageError(
                expectedByteCount: job.expectedByteCount,
                directory: JobStore.directory,
                requiresProcessingCopy: job.timeRange?.isEffective == true
            ) {
                await failJob(job, message: storageError.message)
                return
            }
            job.errorMessage = nil
            job.phase = .downloading
            store.upsert(job)
            if let audioURLString = job.audioURLString,
               let audioURL = URL(string: audioURLString) {
                let videoFile = Self.redditVideoStagingURL(jobID: job.id)
                let audioFile = Self.redditAudioStagingURL(jobID: job.id)
                if FileManager.default.fileExists(atPath: videoFile.path),
                   FileManager.default.fileExists(atPath: audioFile.path) {
                    startRedditMux(jobID: job.id)
                } else if FileManager.default.fileExists(atPath: videoFile.path) {
                    startTask(
                        Self.redditRequest(audioURL), jobID: job.id,
                        role: .redditAudio, attempt: job.mediaAttempts)
                } else {
                    startTask(
                        Self.mediaAssetRequest(assetURL: assetURL, sourceURL: sourceURL),
                        jobID: job.id, role: .redditVideo, attempt: job.mediaAttempts,
                        expectedByteCount: job.expectedByteCount)
                }
                return
            }
            if let resumeData = store.resumeData(for: job) {
                startTask(
                    resumeData: resumeData, jobID: job.id, role: .media,
                    attempt: job.mediaAttempts, expectedByteCount: job.expectedByteCount)
            } else {
                startTask(
                    Self.mediaAssetRequest(assetURL: assetURL, sourceURL: sourceURL),
                    jobID: job.id, role: .media, attempt: job.mediaAttempts,
                    expectedByteCount: job.expectedByteCount)
            }

        case .suspended, .saving, .finished, .failed:
            return
        }
    }

    /// Retries every download that `wifiOnlyDownloads` deferred, if the setting
    /// is still on and we're actually on Wi-Fi now. Called opportunistically on
    /// Wi-Fi reconnect, app launch/foreground, and the next background-refresh
    /// task. A no-op (not just per-item, the whole sweep) when either condition
    /// fails, so it's cheap to call from every one of those triggers.
    public func resumePendingWiFiDownloads() async {
        guard AutoDownloadSettings.wifiOnlyDownloads, NetworkReachability.shared.isOnWiFi else { return }
        await startPendingWiFiDownloads(manual: false)
    }

    /// Starts every Wi-Fi-deferred download right away, ignoring current
    /// network type — used when the user turns `wifiOnlyDownloads` back off,
    /// so already-deferred items don't keep waiting for the next opportunistic
    /// trigger.
    public func startAllPendingWiFiDownloads() async {
        await startPendingWiFiDownloads(manual: true)
    }

    private func startPendingWiFiDownloads(manual: Bool) async {
        for urlString in AutoDownloadSettings.pendingWiFiDownloadURLs() {
            _ = await start(urlString: urlString, ownership: .downloader, manual: manual)
        }
    }

    public func currentDownloadSnapshot(
        forSourceURLString urlString: String
    ) -> DownloaderJobSnapshot? {
        guard let job = store.job(forSourceURLString: urlString), job.isDownloaderOwned else {
            return nil
        }
        return job.downloaderSnapshot
    }

    /// A still-running Downloader job for this URL, for
    /// `resumeOwnProgressUI(forSourceURLString:)` — a terminal job has nothing
    /// left to show progress for. `store` is file-private, hence this accessor.
    func jobAwaitingProgressUI(
        forSourceURLString urlString: String
    ) -> LiveMediaDownloadJob? {
        guard let job = store.job(forSourceURLString: urlString),
              job.isDownloaderOwned, !job.isTerminal
        else { return nil }
        return job
    }

    /// Waits for a Downloader-owned background/Live Activity job to materialize
    /// its durable file. Used only for App Intent downloads below the inline size
    /// threshold; the transfer itself still runs through the same background
    /// URLSession state machine as larger handoffs.
    /// `onByteProgress` reports the running job's `(received, expected)` byte
    /// counts on each poll, so an awaiting App Intent can show the real transfer
    /// rather than a heartbeat estimate.
    public func waitForDownloaderResult(
        forSourceURLString urlString: String,
        onByteProgress: @escaping (Int64, Int64?) -> Void = { _, _ in }
    ) async -> SavedMediaItem? {
        while !Task.isCancelled {
            if let item = SavedMediaStore.shared.existingDownloadedItem(
                forURLString: urlString) {
                return item
            }
            guard let job = store.job(forSourceURLString: urlString) else { return nil }
            onByteProgress(job.receivedByteCount ?? 0, job.expectedByteCount)
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return nil
    }

    public func suspend(jobID: String) async {
        await reapExpiredSuspensions()
        guard var job = store.job(id: jobID),
              job.phase == .downloading || job.phase == .resolving
        else { return }

        job.phase = .suspended
        job.suspendDeadline = Date().addingTimeInterval(Self.suspensionGracePeriod)
        store.upsert(job)
        await updateActivity(for: job)
        if job.isDownloaderOwned {
            postDownloaderJobProgress(job: job, progress: job.progress)
        }
        await suspendTasks(jobID: jobID)

        Task {
            try? await Task.sleep(nanoseconds: UInt64(Self.suspensionGracePeriod * 1_000_000_000))
            await self.reapExpiredSuspensions()
        }
    }

    public func resume(jobID: String) async {
        guard var job = store.job(id: jobID),
              job.phase == .suspended || job.phase == .waiting
        else { return }
        if job.phase == .waiting {
            await restartTransfer(for: job)
            return
        }
        if let deadline = job.suspendDeadline, deadline <= Date() {
            await tearDownSuspendedJob(job)
            return
        }

        job.suspendDeadline = nil
        job.errorMessage = nil
        job.errorKind = nil
        if job.audioURLString != nil {
            job.phase = .downloading
            store.upsert(job)
            await updateActivity(for: job)
            if job.isDownloaderOwned {
                postDownloaderJobProgress(job: job, progress: job.progress)
            }
            await restartTransfer(for: job)
            return
        }
        if let assetURLString = job.assetURLString,
           let assetURL = URL(string: assetURLString),
           let sourceURL = URL(string: job.sourceURLString) {
            if let storageError = MediaDownloadPreflight.storageError(
                expectedByteCount: job.expectedByteCount,
                directory: JobStore.directory,
                requiresProcessingCopy: job.timeRange?.isEffective == true
            ) {
                await failJob(job, message: storageError.message)
                return
            }
            job.phase = .downloading
            store.upsert(job)
            await updateActivity(for: job)
            if job.isDownloaderOwned {
                postDownloaderJobProgress(job: job, progress: job.progress)
            }
            if let resumeData = store.resumeData(for: job) {
                startTask(
                    resumeData: resumeData, jobID: job.id, role: .media,
                    attempt: job.mediaAttempts, expectedByteCount: job.expectedByteCount)
            } else {
                startTask(
                    Self.mediaAssetRequest(assetURL: assetURL, sourceURL: sourceURL),
                    jobID: job.id, role: .media, attempt: job.mediaAttempts,
                    expectedByteCount: job.expectedByteCount)
            }
        } else if let sourceURL = URL(string: job.sourceURLString),
                  let resolve = Self.resolveRequest(for: sourceURL) {
            job.phase = .resolving
            job.resolveKind = ResolveKind(rawValue: resolve.kind)
            store.upsert(job)
            await updateActivity(for: job)
            if job.isDownloaderOwned {
                postDownloaderJobProgress(job: job, progress: job.progress)
            }
            startTask(resolve.request, jobID: job.id, role: .resolve, attempt: job.resolveAttempts)
        } else {
            await tearDownSuspendedJob(job)
        }
    }

    func reapExpiredSuspensions() async {
        let now = Date()
        for job in store.jobs()
            where job.phase == .suspended && (job.suspendDeadline ?? .distantPast) <= now {
            await tearDownSuspendedJob(job)
        }
    }

    /// Reddit's own app-native share links (`/r/<sub>/s/<token>`) carry no post id
    /// — the token only resolves via a live HTTP redirect (which `URLSession`
    /// follows automatically) to the canonical permalink, which every downstream
    /// step here (ensureUndownloaded's dedup key, `resolveRequest`'s `.reddit`
    /// case, etc.) needs a real post id for. A no-op for every other URL shape.
    private static func canonicalRedditURLStringIfNeeded(_ urlString: String) async -> String {
        guard let recognized = PlatformRecognizer.recognize(urlString),
              recognized.platform == .reddit, recognized.itemID == nil,
              let url = URL(string: urlString)
        else { return urlString }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue(MediaDownloadHTTP.browserUserAgent, forHTTPHeaderField: "User-Agent")
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let finalURL = response.url
        else { return urlString }
        return finalURL.absoluteString
    }

    private static func title(for url: URL) -> String {
        if let host = url.host(percentEncoded: false), !host.isEmpty { return host }
        return L10n.string("Downloader_liveActivity_defaultTitle")
    }

    /// The media-file download request for a resolved asset: browser UA, plus
    /// the TikTok CDN's Referer requirement when `sourceURL` is a TikTok post.
    /// `sourceURL` is always the already-recognized source post URL (every job is
    /// created behind `MediaDownloadablePlatform.supports`), so an anchored
    /// host-suffix match is exactly as reliable here as the old substring check.
    private static func mediaAssetRequest(assetURL: URL, sourceURL: URL) -> URLRequest {
        var request = URLRequest(url: assetURL, timeoutInterval: 60)
        request.setValue(MediaDownloadHTTP.browserUserAgent, forHTTPHeaderField: "User-Agent")
        if HostMatching.hostSuffixMatches(sourceURL.host?.lowercased() ?? "", "tiktok.com") {
            request.setValue("https://www.tiktok.com/", forHTTPHeaderField: "Referer")
        } else if PlatformRecognizer.recognize(sourceURL.absoluteString)?.platform == .youtube {
            request.setValue("https://www.youtube.com/", forHTTPHeaderField: "Referer")
        } else if PlatformRecognizer.recognize(sourceURL.absoluteString)?.platform == .reddit {
            request.setValue("https://www.reddit.com/", forHTTPHeaderField: "Referer")
        }
        return request
    }

    private static func redditRequest(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.setValue(MediaDownloadHTTP.browserUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://www.reddit.com/", forHTTPHeaderField: "Referer")
        return request
    }

    private func startTask(
        _ request: URLRequest,
        jobID: String,
        role: TaskRole,
        attempt: Int,
        expectedByteCount: Int64? = nil
    ) {
        let task = session.downloadTask(with: request)
        task.taskDescription = "\(jobID)|\(role.rawValue)|\(attempt)"
        if let expectedByteCount, expectedByteCount > 0 {
            task.countOfBytesClientExpectsToReceive = expectedByteCount
        }
        task.resume()
    }

    private func startTask(
        resumeData: Data,
        jobID: String,
        role: TaskRole,
        attempt: Int,
        expectedByteCount: Int64?
    ) {
        let task = session.downloadTask(withResumeData: resumeData)
        task.taskDescription = "\(jobID)|\(role.rawValue)|\(attempt)"
        if let expectedByteCount, expectedByteCount > 0 {
            task.countOfBytesClientExpectsToReceive = expectedByteCount
        }
        task.resume()
    }

    private func cancelTasks(jobID: String) async {
        await withCheckedContinuation { continuation in
            session.getAllTasks { tasks in
                let prefix = "\(jobID)|"
                for task in tasks where task.taskDescription?.hasPrefix(prefix) == true {
                    task.cancel()
                }
                continuation.resume()
            }
        }
    }

    /// Pauses download tasks while asking URLSession for resumable state. Resolve
    /// pages are small and simply cancel; media tasks persist their opaque resume
    /// blob beside jobs.json before this method returns.
    private func suspendTasks(jobID: String) async {
        await withCheckedContinuation { continuation in
            session.getAllTasks { tasks in
                let matching = tasks.filter { $0.taskDescription?.hasPrefix("\(jobID)|") == true }
                guard !matching.isEmpty else {
                    continuation.resume()
                    return
                }
                let group = DispatchGroup()
                for task in matching {
                    guard let downloadTask = task as? URLSessionDownloadTask,
                          Self.taskParts(task.taskDescription ?? "")?.role == .media
                    else {
                        task.cancel()
                        continue
                    }
                    group.enter()
                    downloadTask.cancel(byProducingResumeData: { resumeData in
                        if let resumeData,
                           var job = self.store.job(id: jobID),
                           let fileName = self.store.saveResumeData(resumeData, for: jobID) {
                            job.resumeDataFileName = fileName
                            self.store.upsert(job)
                        }
                        group.leave()
                    })
                }
                group.notify(queue: .global(qos: .utility)) {
                    continuation.resume()
                }
            }
        }
    }

    static func resolveRequest(for url: URL) -> (request: URLRequest, kind: String)? {
        guard let recognized = PlatformRecognizer.recognize(url.absoluteString) else { return nil }
        let resolveURL: URL
        let kind: ResolveKind
        switch recognized.platform {
        case .x:
            guard let id = recognized.itemID,
                  let url = URL(string: "https://api.fxtwitter.com/status/\(id)")
            else { return nil }
            resolveURL = url
            kind = .x
        case .tiktok:
            resolveURL = url
            kind = .tiktok
        case .instagram:
            // Mirror `SocialMediaResolver.resolveInstagram`: the persisted GraphQL
            // query is the only keyless source that still returns a reel's
            // `video_url`, so it leads and the embed page becomes the fallback stage
            // (`startNextInstagramResolve`). Whoever reorders one must reorder both.
            guard let code = recognized.itemID else { return nil }
            return (SocialMediaResolver.instagramGraphQLRequest(
                        shortcode: code, timeoutInterval: 60),
                    ResolveKind.instagramGraphQL.rawValue)
        case .facebook:
            // Match SocialMediaResolver.resolveFacebook's foreground/extension path:
            // Facebook's logged-out reel page commonly returns HTTP 400 or a poster-only
            // login wall, while the video plugin exposes the playable hd_src/sd_src MP4.
            // Keep the stage in resolveKind so a persisted background job can fall
            // through the desktop, mobile, canonical, and crawler pages below
            // (`startNextFacebookResolve`) the same way that function does. The two are
            // hand-mirrored because this engine persists each stage so it can survive
            // process death, while `SocialMediaResolver.resolveFacebook` is linear async.
            // Whoever changes one function's stage order must update the other to match.
            guard let pluginURL = SocialMediaResolver.facebookVideoPluginURL(for: url)
            else { return nil }
            resolveURL = pluginURL
            kind = .facebookPlugin
        case .reddit:
            // The public, subreddit-agnostic listing endpoint works for any
            // recognized permalink shape (a full `/r/.../comments/<id>/...`
            // permalink or a `redd.it/<id>` short link both resolve to the
            // same post id here), so there's no need to reconstruct `.json`
            // from the original URL string.
            guard let id = recognized.itemID,
                  let url = URL(string: "https://www.reddit.com/comments/\(id).json")
            else { return nil }
            resolveURL = url
            kind = .reddit
        case .youtube:
            guard let link = YouTubeLink(url: url) else { return nil }
            if link.isClip {
                resolveURL = url
                kind = .youtubeClip
            } else {
                guard let watchURL = link.canonicalWatchURL else { return nil }
                resolveURL = watchURL
                kind = .youtubeWatch
            }
        default:
            return nil
        }
        var request: URLRequest
        if kind == .x {
            request = URLRequest(url: resolveURL, timeoutInterval: 60)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
        } else if kind.rawValue.hasPrefix("facebook") {
            request = SocialMediaResolver.facebookPageRequest(
                resolveURL, userAgent: MediaDownloadHTTP.desktopBrowserUserAgent,
                timeoutInterval: 60)
        } else if kind == .youtubeWatch {
            request = YouTubeMediaResolver.watchRequest(resolveURL)
        } else if kind == .youtubeClip || kind == .youtubeEmbed {
            request = YouTubeMediaResolver.htmlRequest(resolveURL)
        } else {
            request = URLRequest(url: resolveURL, timeoutInterval: 60)
            request.setValue(MediaDownloadHTTP.browserUserAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        }
        return (request, kind.rawValue)
    }

    private func resolvedAsset(from data: Data, job: LiveMediaDownloadJob) -> MediaAsset? {
        switch job.resolveKind {
        case .x:
            return XMediaParser.assets(fromFxJSON: data).first
        case .tiktok:
            guard let html = String(data: data, encoding: .utf8) else { return nil }
            return TikTokMediaParser.assets(fromHTML: html).first
        case .instagramGraphQL:
            return InstagramMediaParser.post(fromGraphQLJSON: data)?.assets.first
        case .instagramEmbed:
            guard let html = String(data: data, encoding: .utf8) else { return nil }
            let post = InstagramMediaParser.post(fromEmbedHTML: html)
            if let asset = post?.assets.first { return asset }
            // A reel whose playable URL Instagram withheld: the loose markup scan
            // below would match its cover frame, so let the job fail as "no media"
            // rather than download a still in place of the video.
            if post?.isVideoMissingItsPlayableURL == true { return nil }
            return InstagramMediaParser.assets(fromHTML: html).first
        case .facebookPlugin, .facebookDesktop, .facebookMobile, .facebookCanonical,
             .facebookCrawler,
             .facebook, .facebookShort:
            guard let html = String(data: data, encoding: .utf8) else { return nil }
            return FacebookMediaParser.assets(fromHTML: html).first
        case .reddit:
            return RedditMediaParser.asset(fromListingJSON: data)
        case .youtubeAndroidVR, .youtubePlayer, .youtubeEmbed:
            guard let videoID = job.resolvedVideoID
                ?? URL(string: job.sourceURLString).flatMap(YouTubeLink.init(url:))?.videoID
            else { return nil }
            return YouTubePlayerResponseParser.asset(
                from: data,
                videoID: videoID,
                timeRange: job.timeRange?.isEffective == true ? job.timeRange : nil)
        case .youtubeClip, .youtubeWatch, .youtubePlayerJavaScript:
            return nil
        case .rescue, .direct:
            // Neither ever reaches this parser: a `.rescue` job already carries
            // its resolved `MediaAsset` (via `startWithResolvedAssets`), and a
            // `.direct` job's URL needed no resolve step at all.
            return nil
        case nil:
            return nil
        }
    }

    private func makeThumbnail(from url: URL, jobID: String) async -> String? {
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue(MediaDownloadHTTP.browserUserAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 420,
              ] as CFDictionary)
        else { return nil }
        return Self.writeThumbnail(cgImage, jobID: jobID)
    }

    private func makeVideoThumbnail(from fileURL: URL, jobID: String) -> String? {
        let asset = AVURLAsset(url: fileURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        guard let cgImage = try? generator.copyCGImage(at: .zero, actualTime: nil) else { return nil }
        return Self.writeThumbnail(cgImage, jobID: jobID)
    }

    /// Writes `cgImage` to `jobID`'s thumbnail JPEG, shared by the network-image
    /// and video-frame thumbnail paths above, which differ only in how they
    /// obtain the `CGImage`.
    private static func writeThumbnail(_ cgImage: CGImage, jobID: String) -> String? {
        guard let destination = CGImageDestinationCreateWithURL(
            JobStore.thumbnailURL(fileName: "\(jobID).jpg") as CFURL,
            "public.jpeg" as CFString,
            1,
            nil)
        else { return nil }
        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return "\(jobID).jpg"
    }

    private func finish(job: LiveMediaDownloadJob, downloadedTo location: URL, response: URLResponse?) {
        guard job.phase != .suspended else { return }
        let http = response as? HTTPURLResponse
        if let http, !(200..<300).contains(http.statusCode) {
            if http.statusCode == 403, restartExpiredYouTubeMedia(job) { return }
            startTrackedBackgroundWork {
                await self.retryOrFail(
                    job: job, role: .media, response: response,
                    message: MediaDownloadError.downloadFailed.message)
            }
            return
        }

        let kind = job.mediaKind ?? .image
        let ext = MediaFileDownloader.fileExtension(
            for: MediaAsset(url: URL(string: job.assetURLString ?? job.sourceURLString)!, kind: kind),
            mimeType: http?.mimeType)
        finalizeDownloadedFile(job: job, temporaryLocation: location, fileExtension: ext, kind: kind)
    }

    /// The shared move-into-place / thumbnail / save tail, common to the
    /// normal single-URL download-task flow above and the Reddit dual-stream
    /// mux flow below (which has no `URLResponse` to check against — its own
    /// two fetches already threw on failure).
    private func finalizeDownloadedFile(
        job: LiveMediaDownloadJob, temporaryLocation: URL, fileExtension ext: String, kind: MediaAsset.Kind
    ) {
        var job = job
        let staging = JobStore.stagingURL(fileName: "\(job.id).source.\(ext)")
        do {
            try? FileManager.default.removeItem(at: staging)
            try FileManager.default.moveItem(at: temporaryLocation, to: staging)
            job.fileExtension = ext
            job.phase = .saving
            job.progress = 1
            store.upsert(job)
            Task { await updateActivity(for: job) }
            if job.isDownloaderOwned {
                postDownloaderJobProgress(job: job, progress: 1)
            }
            resumeFinalization(for: job)
        } catch {
            startTrackedBackgroundWork {
                await self.failJob(job, message: MediaDownloadError.downloadFailed.message)
            }
        }
    }

    /// Completes a persisted local post-processing stage. The original transfer
    /// lives at `.source.<ext>` until any requested trim has successfully produced
    /// the final file. If termination occurs after the final move, the absence of
    /// the staging file proves that trimming already completed and prevents a
    /// timestamp range from being applied twice.
    private func resumeFinalization(for persistedJob: LiveMediaDownloadJob) {
        let jobID = persistedJob.id
        startTrackedBackgroundWork {
            guard var job = self.store.job(id: jobID), job.phase == .saving else { return }
            let ext = job.fileExtension ?? ((job.mediaKind ?? .image) == .video ? "mp4" : "jpg")
            let staging = JobStore.stagingURL(fileName: "\(job.id).source.\(ext)")
            let destination = JobStore.downloadURL(fileName: "\(job.id).\(ext)")
            do {
                if FileManager.default.fileExists(atPath: staging.path) {
                    let processed = try await MediaVideoTrimmer.trimIfNeeded(
                        fileURL: staging,
                        timeRange: (job.mediaKind ?? .image) == .video ? job.timeRange : nil)
                    try? FileManager.default.removeItem(at: destination)
                    try FileManager.default.moveItem(at: processed, to: destination)
                    if processed != staging {
                        try? FileManager.default.removeItem(at: staging)
                    }
                }
                guard FileManager.default.fileExists(atPath: destination.path) else {
                    throw MediaDownloadError.downloadFailed
                }
                if (job.mediaKind ?? .image) == .video, job.thumbnailFileName == nil {
                    job.thumbnailFileName = self.makeVideoThumbnail(
                        from: destination, jobID: job.id)
                }
                self.store.upsert(job)
                await self.save(job: job, fileURL: destination, kind: (job.mediaKind ?? .image))
            } catch {
                guard let current = self.store.job(id: jobID) else { return }
                await self.failJob(current, message: MediaDownloadError.downloadFailed.message)
            }
        }
    }

    /// Reddit's video and audio legs run sequentially in the durable background
    /// session. The staged video and persisted companion URLs make every network
    /// boundary restartable after suspension or process death; only the final,
    /// local mux runs in app execution time.
    private func startRedditMuxedDownload(
        for job: LiveMediaDownloadJob, videoURL: URL, audioURL: URL, dashManifestURL: URL?
    ) {
        var job = job
        job.audioURLString = audioURL.absoluteString
        job.dashManifestURLString = dashManifestURL?.absoluteString
        store.upsert(job)
        guard let sourceURL = URL(string: job.sourceURLString) else { return }
        startTask(
            Self.mediaAssetRequest(assetURL: videoURL, sourceURL: sourceURL),
            jobID: job.id, role: .redditVideo, attempt: job.mediaAttempts,
            expectedByteCount: job.expectedByteCount)
    }

    private static func redditVideoStagingURL(jobID: String) -> URL {
        JobStore.stagingURL(fileName: "\(jobID).reddit-video.mp4")
    }

    private static func redditAudioStagingURL(jobID: String) -> URL {
        JobStore.stagingURL(fileName: "\(jobID).reddit-audio.m4a")
    }

    private func moveRedditTrack(from location: URL, to destination: URL) throws {
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: location, to: destination)
    }

    private func finishRedditVideo(
        job: LiveMediaDownloadJob, location: URL, response: URLResponse?
    ) {
        guard (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true
        else {
            startTrackedBackgroundWork {
                await self.retryRedditVideoOrFail(job: job, response: response)
            }
            return
        }
        do {
            try moveRedditTrack(from: location, to: Self.redditVideoStagingURL(jobID: job.id))
            reportProgress(jobID: job.id, progress: 0.5)
            guard let audio = job.audioURLString.flatMap(URL.init(string:)) else {
                finishRedditWithoutAudio(jobID: job.id)
                return
            }
            startTask(Self.redditRequest(audio), jobID: job.id, role: .redditAudio, attempt: 0)
        } catch {
            startTrackedBackgroundWork {
                await self.failJob(job, message: MediaDownloadError.downloadFailed.message)
            }
        }
    }

    private func retryRedditVideoOrFail(
        job: LiveMediaDownloadJob, response: URLResponse?, error: Error? = nil
    ) async {
        guard var current = store.job(id: job.id), current.phase != .suspended else { return }
        guard isTransient(response: response, error: error),
              current.mediaAttempts + 1 < Self.maxTransientAttempts,
              let video = current.assetURLString.flatMap(URL.init(string:)),
              let source = URL(string: current.sourceURLString)
        else {
            await failJob(current, message: MediaDownloadError.downloadFailed.message)
            return
        }
        current.mediaAttempts += 1
        store.upsert(current)
        startTask(
            Self.mediaAssetRequest(assetURL: video, sourceURL: source),
            jobID: current.id, role: .redditVideo, attempt: current.mediaAttempts,
            expectedByteCount: current.expectedByteCount)
    }

    private func finishRedditAudio(
        job: LiveMediaDownloadJob, location: URL, response: URLResponse?
    ) {
        guard (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true
        else {
            startRedditManifestFallback(jobID: job.id)
            return
        }
        do {
            try moveRedditTrack(from: location, to: Self.redditAudioStagingURL(jobID: job.id))
            reportProgress(jobID: job.id, progress: 0.9)
            startRedditMux(jobID: job.id)
        } catch {
            finishRedditWithoutAudio(jobID: job.id)
        }
    }

    private func startRedditManifestFallback(jobID: String) {
        guard var job = store.job(id: jobID), job.phase != .suspended else { return }
        guard let manifest = job.dashManifestURLString.flatMap(URL.init(string:)) else {
            finishRedditWithoutAudio(jobID: jobID)
            return
        }
        job.dashManifestURLString = nil
        store.upsert(job)
        startTask(Self.redditRequest(manifest), jobID: job.id, role: .redditManifest, attempt: 0)
    }

    private func finishRedditManifest(
        job: LiveMediaDownloadJob, location: URL, response: URLResponse?
    ) {
        guard (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true,
              let data = try? Data(contentsOf: location),
              let xml = String(data: data, encoding: .utf8),
              let manifest = response?.url,
              let audio = RedditMediaParser.audioURL(
                fromDASHManifest: xml, manifestURL: manifest),
              var current = store.job(id: job.id)
        else {
            finishRedditWithoutAudio(jobID: job.id)
            return
        }
        current.audioURLString = audio.absoluteString
        store.upsert(current)
        startTask(Self.redditRequest(audio), jobID: job.id, role: .redditAudio, attempt: 1)
    }

    private func startRedditMux(jobID: String) {
        startTrackedBackgroundWork {
            guard let job = self.store.job(id: jobID), job.phase != .suspended else { return }
            let video = Self.redditVideoStagingURL(jobID: jobID)
            let audio = Self.redditAudioStagingURL(jobID: jobID)
            guard FileManager.default.fileExists(atPath: video.path),
                  FileManager.default.fileExists(atPath: audio.path) else { return }
            let muxed = MediaDownloadStorage.newFileURL(extension: "mp4")
            do {
                try await MediaMuxer.mux(videoURL: video, audioURL: audio, outputURL: muxed)
                try? FileManager.default.removeItem(at: video)
                try? FileManager.default.removeItem(at: audio)
                guard let current = self.store.job(id: jobID), current.phase != .suspended else {
                    try? FileManager.default.removeItem(at: muxed)
                    return
                }
                self.finalizeDownloadedFile(
                    job: current, temporaryLocation: muxed,
                    fileExtension: "mp4", kind: .video)
            } catch {
                try? FileManager.default.removeItem(at: audio)
                self.finishRedditWithoutAudio(jobID: jobID)
            }
        }
    }

    private func finishRedditWithoutAudio(jobID: String) {
        guard let job = store.job(id: jobID), job.phase != .suspended else { return }
        let video = Self.redditVideoStagingURL(jobID: jobID)
        guard FileManager.default.fileExists(atPath: video.path) else { return }
        try? FileManager.default.removeItem(at: Self.redditAudioStagingURL(jobID: jobID))
        finalizeDownloadedFile(
            job: job, temporaryLocation: video, fileExtension: "mp4", kind: .video)
    }

    private func removeRedditStaging(jobID: String) {
        try? FileManager.default.removeItem(at: Self.redditVideoStagingURL(jobID: jobID))
        try? FileManager.default.removeItem(at: Self.redditAudioStagingURL(jobID: jobID))
    }

    private func reportProgress(jobID: String, progress: Double) {
        guard var job = store.job(id: jobID), job.phase != .suspended else { return }
        job.phase = .downloading
        job.progress = progress
        store.upsert(job)
        if job.isDownloaderOwned {
            postDownloaderJobProgress(job: job, progress: progress)
        }
        Task { await updateActivity(for: job) }
    }

    private func finishResolve(job: LiveMediaDownloadJob, downloadedTo location: URL, response: URLResponse?) {
        var job = job
        guard job.phase != .suspended else { return }
        let http = response as? HTTPURLResponse
        if let http, !(200..<300).contains(http.statusCode) {
            if startNextInstagramResolve(after: job, data: nil) { return }
            if startNextFacebookResolve(after: job, data: nil) { return }
            if startNextYouTubeResolve(after: job, data: nil) { return }
            startTrackedBackgroundWork {
                await self.retryOrFail(
                    job: job, role: .resolve, response: response,
                    message: MediaDownloadError.noMedia.message)
            }
            return
        }
        guard let data = try? Data(contentsOf: location) else {
            startTrackedBackgroundWork {
                await self.failJob(
                    job, message: MediaDownloadError.noMedia.message, errorKind: .noMedia)
            }
            return
        }
        if job.resolveKind == .youtubeClip,
           let html = String(data: data, encoding: .utf8),
           let clip = YouTubeClipParser.descriptor(fromHTML: html),
           let watchURL = YouTubeLink.watchURL(videoID: clip.videoID) {
            job.resolvedVideoID = clip.videoID
            job.timeRange = clip.timeRange
            job.resolveKind = .youtubeWatch
            store.upsert(job)
            startTask(
                YouTubeMediaResolver.watchRequest(watchURL),
                jobID: job.id, role: .resolve, attempt: job.resolveAttempts)
            if let thumbnail = YouTubeLink.thumbnailURL(videoID: clip.videoID) {
                Task { await self.fetchAndPublishThumbnail(from: thumbnail, jobID: job.id) }
            }
            return
        }
        if let asset = resolvedAsset(from: data, job: job) {
            startMediaDownload(for: job, asset: asset)
            return
        }
        if startNextInstagramResolve(after: job, data: data) { return }
        if startNextFacebookResolve(after: job, data: data) { return }
        if startNextYouTubeResolve(after: job, data: data) { return }
        startTrackedBackgroundWork {
            await self.failJob(
                job, message: MediaDownloadError.noMedia.message, errorKind: .noMedia)
        }
        return
    }

    private func startNextYouTubeResolve(
        after persistedJob: LiveMediaDownloadJob, data: Data?
    ) -> Bool {
        guard let videoID = persistedJob.resolvedVideoID
            ?? URL(string: persistedJob.sourceURLString).flatMap(YouTubeLink.init(url:))?.videoID
        else { return false }

        let request: URLRequest
        let kind: ResolveKind
        switch persistedJob.resolveKind {
        case .youtubeWatch:
            if let data,
               let bootstrap = YouTubePlaybackBootstrapParser.bootstrap(
                fromWatchData: data) {
                var job = persistedJob
                job.youtubeVisitorData = bootstrap.visitorData
                job.resolveKind = .youtubePlayerJavaScript
                store.upsert(job)
                startTask(
                    YouTubeMediaResolver.playerJavaScriptRequest(
                        bootstrap.playerJavaScriptURL),
                    jobID: job.id, role: .resolve, attempt: job.resolveAttempts)
                return true
            } else if let data,
                      let playerRequest = YouTubeMediaResolver.playerRequest(
                        fromWatchData: data, videoID: videoID) {
                request = playerRequest
                kind = .youtubePlayer
            } else if let embedURL = YouTubeLink.embedURL(videoID: videoID) {
                request = YouTubeMediaResolver.htmlRequest(embedURL)
                kind = .youtubeEmbed
            } else { return false }
        case .youtubePlayerJavaScript:
            guard let data,
                  let visitorData = persistedJob.youtubeVisitorData,
                  let signatureTimestamp =
                    YouTubePlaybackBootstrapParser.signatureTimestamp(
                        fromPlayerJavaScript: data)
            else { return false }
            request = YouTubeMediaResolver.androidVRPlayerRequest(
                videoID: videoID,
                visitorData: visitorData,
                signatureTimestamp: signatureTimestamp)
            kind = .youtubeAndroidVR
        case .youtubeAndroidVR:
            guard let embedURL = YouTubeLink.embedURL(videoID: videoID) else {
                return false
            }
            request = YouTubeMediaResolver.htmlRequest(embedURL)
            kind = .youtubeEmbed
        case .youtubePlayer:
            guard let embedURL = YouTubeLink.embedURL(videoID: videoID) else { return false }
            request = YouTubeMediaResolver.htmlRequest(embedURL)
            kind = .youtubeEmbed
        default:
            return false
        }
        var job = persistedJob
        job.resolveKind = kind
        store.upsert(job)
        startTask(request, jobID: job.id, role: .resolve, attempt: job.resolveAttempts)
        return true
    }

    /// YouTube CDN URLs are signed and expire. A resumed transfer that receives
    /// 403 must refresh the direct URL from the original page instead of retrying
    /// the stale URL forever.
    private func restartExpiredYouTubeMedia(_ persistedJob: LiveMediaDownloadJob) -> Bool {
        guard PlatformRecognizer.recognize(persistedJob.sourceURLString)?.platform == .youtube,
              let sourceURL = URL(string: persistedJob.sourceURLString),
              let resolve = Self.resolveRequest(for: sourceURL)
        else { return false }
        var job = persistedJob
        store.removeResumeData(for: job)
        job.resumeDataFileName = nil
        job.assetURLString = nil
        job.phase = .resolving
        job.progress = 0
        job.receivedByteCount = nil
        job.resolveKind = ResolveKind(rawValue: resolve.kind)
        store.upsert(job)
        startTask(resolve.request, jobID: job.id, role: .resolve, attempt: job.resolveAttempts)
        return true
    }

    /// Advances the durable Instagram resolver from the persisted GraphQL query to the
    /// embed page, mirroring `SocialMediaResolver.resolveInstagram`'s two stages.
    /// Returns true after starting the next background task.
    ///
    /// Deliberately does NOT advance when the query already answered that the post is
    /// a video whose playable URL Instagram withheld: the embed page can only offer
    /// that reel's cover frame, and downloading a still in place of the video is the
    /// failure this ladder exists to prevent. The job fails as "no media" and the
    /// saved link stays usable.
    private func startNextInstagramResolve(
        after persistedJob: LiveMediaDownloadJob, data: Data?
    ) -> Bool {
        guard persistedJob.resolveKind == .instagramGraphQL,
              let sourceURL = URL(string: persistedJob.sourceURLString),
              let code = PlatformRecognizer.recognize(sourceURL.absoluteString)?.itemID,
              let embedURL = URL(string: "https://www.instagram.com/p/\(code)/embed/captioned/")
        else { return false }
        if let data, InstagramMediaParser.post(fromGraphQLJSON: data)?
            .isVideoMissingItsPlayableURL == true { return false }

        var job = persistedJob
        job.resolveKind = .instagramEmbed
        store.upsert(job)
        var request = URLRequest(url: embedURL, timeoutInterval: 60)
        request.setValue(MediaDownloadHTTP.browserUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        startTask(request, jobID: job.id, role: .resolve, attempt: job.resolveAttempts)
        return true
    }

    /// Advances the durable Facebook resolver through the same useful sources as
    /// `SocialMediaResolver.resolveFacebook`: plugin embed → desktop page → mobile
    /// page → desktop canonical page (when distinct) → crawler page. Returns true
    /// after starting the next background task. Hand-mirrored against that function,
    /// not shared code — see the comment on `resolveRequest`'s `.facebook` case.
    private func startNextFacebookResolve(
        after persistedJob: LiveMediaDownloadJob, data: Data?
    ) -> Bool {
        guard let sourceURL = URL(string: persistedJob.sourceURLString) else { return false }
        let resolutionURL = SocialMediaResolver.facebookResolutionURL(for: sourceURL)

        let next: (url: URL, kind: ResolveKind, userAgent: String)?
        switch persistedJob.resolveKind {
        case .facebookPlugin:
            next = (resolutionURL, .facebookDesktop, MediaDownloadHTTP.desktopBrowserUserAgent)
        case .facebookDesktop, .facebook:
            next = (resolutionURL, .facebookMobile, MediaDownloadHTTP.browserUserAgent)
        case .facebookMobile, .facebookShort:
            if let data,
               let html = String(data: data, encoding: .utf8),
               let canonical = FacebookMediaParser.canonicalVideoURL(fromHTML: html),
               canonical.absoluteString != resolutionURL.absoluteString {
                next = (canonical, .facebookCanonical, MediaDownloadHTTP.desktopBrowserUserAgent)
            } else {
                next = (resolutionURL, .facebookCrawler, MediaDownloadHTTP.facebookCrawlerUserAgent)
            }
        case .facebookCanonical:
            next = (resolutionURL, .facebookCrawler, MediaDownloadHTTP.facebookCrawlerUserAgent)
        default:
            return false
        }

        guard let next else { return false }
        var job = persistedJob
        job.resolveKind = next.kind
        store.upsert(job)
        let request = SocialMediaResolver.facebookPageRequest(
            next.url, userAgent: next.userAgent, timeoutInterval: 60)
        startTask(request, jobID: job.id, role: .resolve, attempt: job.resolveAttempts)
        return true
    }

    private func save(job: LiveMediaDownloadJob, fileURL: URL, kind: MediaAsset.Kind) async {
        var job = job
        guard job.phase != .suspended else { return }
        do {
            if job.isDownloaderOwned {
                _ = try await finishDownloaderStorage(
                    job: job, fileURL: fileURL, kind: kind)
            } else {
                _ = try await saver.save(fileURL: fileURL, kind: kind)
            }
            AutoDownloadSettings.markDownloaded(job.sourceURLString)
            AutoDownloadSettings.unmarkPendingWiFiDownload(job.sourceURLString)
            job.phase = .finished
            job.progress = 1
            job.errorMessage = nil
            store.upsert(job)
            await updateActivity(for: job)
            if job.isDownloaderOwned {
                postDownloaderJobProgress(job: job, progress: 1)
            }
            await endActivity(for: job)
            removeRedditStaging(jobID: job.id)
            store.remove(job.id)
        } catch {
            await failJob(job, message: MediaDownloadError.saveFailed.message)
        }
    }

    private func finishDownloaderStorage(
        job: LiveMediaDownloadJob, fileURL: URL, kind: MediaAsset.Kind
    ) async throws -> SavedMediaItem {
        guard let pending = SavedMediaStore.shared.matchingItem(
            forURLString: job.sourceURLString)
        else { throw CancellationError() }
        if kind.canSaveToPhotos,
           AutoDownloadSettings.autoSaveDownloadsToPhotos,
           await saver.requestReadAuthorization() {
            do {
                let identifier = try await saver.save(
                    fileURL: fileURL, kind: kind, shouldMoveFile: false)
                if let item = try SavedMediaStore.shared.transitionToPhotosReference(
                    pending.id, localIdentifier: identifier, kind: kind) {
                    try? FileManager.default.removeItem(at: fileURL)
                    return item
                }
            } catch {
                // Keep the completed transfer as an app-owned file below.
            }
        }
        return try SavedMediaStore.shared.addDownloadedFile(
            fileURL,
            kind: kind,
            sourceURLString: job.sourceURLString,
            title: job.title,
            creator: job.creator,
            fileExtension: job.fileExtension,
            requiringItemID: pending.id)
    }

    private func retryOrFail(
        job: LiveMediaDownloadJob,
        role: TaskRole,
        response: URLResponse?,
        error: Error? = nil,
        message: String
    ) async {
        let transient = isTransient(response: response, error: error)
        if !transient, role == .media,
           var freshJob = store.job(id: job.id),
           freshJob.resumeDataFileName != nil,
           let assetURLString = freshJob.assetURLString,
           let assetURL = URL(string: assetURLString),
           let sourceURL = URL(string: freshJob.sourceURLString) {
            if let storageError = MediaDownloadPreflight.storageError(
                expectedByteCount: freshJob.expectedByteCount,
                directory: JobStore.directory,
                requiresProcessingCopy: freshJob.timeRange?.isEffective == true
            ) {
                await failJob(freshJob, message: storageError.message)
                return
            }
            // Resume blobs are server/OS opaque and can become invalid. One clean
            // range-less restart is safer than permanently failing an otherwise
            // valid source; clearing the filename prevents a restart loop.
            store.removeResumeData(for: freshJob)
            freshJob.resumeDataFileName = nil
            freshJob.receivedByteCount = nil
            freshJob.progress = 0
            freshJob.mediaAttempts += 1
            store.upsert(freshJob)
            startTask(
                Self.mediaAssetRequest(assetURL: assetURL, sourceURL: sourceURL),
                jobID: freshJob.id, role: .media, attempt: freshJob.mediaAttempts,
                expectedByteCount: freshJob.expectedByteCount)
            return
        }
        guard transient else {
            await failJob(job, message: message)
            return
        }
        guard var retryJob = store.job(id: job.id) else { return }

        switch role {
        case .resolve:
            guard retryJob.resolveAttempts + 1 < Self.maxTransientAttempts,
                  let url = URL(string: retryJob.sourceURLString),
                  let resolve = Self.resolveRequest(for: url)
            else {
                await waitToResume(retryJob)
                return
            }
            retryJob.resolveAttempts += 1
            retryJob.errorMessage = nil
            store.upsert(retryJob)
            startTask(resolve.request, jobID: retryJob.id, role: .resolve, attempt: retryJob.resolveAttempts)
        case .media:
            guard retryJob.mediaAttempts + 1 < Self.maxTransientAttempts,
                  let assetURLString = retryJob.assetURLString,
                  let assetURL = URL(string: assetURLString),
                  let sourceURL = URL(string: retryJob.sourceURLString)
            else {
                await waitToResume(retryJob)
                return
            }
            if let storageError = MediaDownloadPreflight.storageError(
                expectedByteCount: retryJob.expectedByteCount,
                directory: JobStore.directory,
                requiresProcessingCopy: retryJob.timeRange?.isEffective == true
            ) {
                await failJob(retryJob, message: storageError.message)
                return
            }
            retryJob.mediaAttempts += 1
            retryJob.errorMessage = nil
            store.upsert(retryJob)
            if let resumeData = store.resumeData(for: retryJob) {
                startTask(
                    resumeData: resumeData, jobID: retryJob.id, role: .media,
                    attempt: retryJob.mediaAttempts,
                    expectedByteCount: retryJob.expectedByteCount)
            } else {
                startTask(
                    Self.mediaAssetRequest(assetURL: assetURL, sourceURL: sourceURL),
                    jobID: retryJob.id, role: .media, attempt: retryJob.mediaAttempts,
                    expectedByteCount: retryJob.expectedByteCount)
            }
        case .redditVideo:
            await retryRedditVideoOrFail(job: retryJob, response: response, error: error)
        case .redditAudio:
            startRedditManifestFallback(jobID: retryJob.id)
        case .redditManifest:
            finishRedditWithoutAudio(jobID: retryJob.id)
        }
    }

    private func waitToResume(_ persistedJob: LiveMediaDownloadJob) async {
        guard var job = store.job(id: persistedJob.id), !job.isTerminal else { return }
        job.phase = .waiting
        job.errorMessage = nil
        store.upsert(job)
        await updateActivity(for: job)
        if job.isDownloaderOwned {
            postDownloaderJobProgress(job: job, progress: job.progress)
        }
    }

    private func isTransient(response: URLResponse?, error: Error?) -> Bool {
        if let http = response as? HTTPURLResponse {
            return http.statusCode == 408 || http.statusCode == 429 || (500..<600).contains(http.statusCode)
        }
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .timedOut, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost,
             .dnsLookupFailed, .notConnectedToInternet, .internationalRoamingOff,
             .callIsActive, .dataNotAllowed:
            return true
        default:
            return false
        }
    }

    private func failJob(
        _ job: LiveMediaDownloadJob,
        message: String,
        errorKind: LiveMediaDownloadJob.ErrorKind = .download
    ) async {
        var job = job
        job.fail(message: message, kind: errorKind)
        store.upsert(job)
        if job.isDownloaderOwned {
            postDownloaderJobProgress(job: job, progress: nil)
        }
        await updateActivity(for: job)
        await endActivity(for: job, dismissalDelay: Self.failureDismissalDelay)
        removeRedditStaging(jobID: job.id)
        store.remove(job.id)
    }

    private func tearDownSuspendedJob(_ job: LiveMediaDownloadJob) async {
        await cancelTasks(jobID: job.id)
        await endActivity(for: job, dismissalDelay: 0)
        removeRedditStaging(jobID: job.id)
        store.removeFiles(for: job)
        store.remove(job.id)
        if job.isDownloaderOwned {
            postDownloaderJobEnded(sourceURLString: job.sourceURLString)
        }
    }
}

extension LiveMediaDownloadManager: URLSessionDownloadDelegate {
    public func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0,
              let description = downloadTask.taskDescription,
              let parts = Self.taskParts(description),
              let jobID = parts.jobID,
              var job = store.job(id: jobID),
              job.phase != .suspended
        else { return }
        let fraction = min(1, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
        let progress: Double
        switch parts.role {
        case .media: progress = fraction
        case .redditVideo: progress = fraction * 0.5
        case .redditAudio: progress = 0.5 + fraction * 0.4
        case .resolve, .redditManifest, .none: return
        }
        let previousPercent = Int(job.progress * 100)
        let phaseChanged = job.phase != .downloading
        job.phase = .downloading
        job.progress = progress
        job.receivedByteCount = totalBytesWritten
        job.expectedByteCount = totalBytesExpectedToWrite
        let percentChanged = Int(job.progress * 100) != previousPercent
        store.upsert(job, progressOnly: !phaseChanged)
        if job.isDownloaderOwned, percentChanged {
            postDownloaderJobProgress(job: job, progress: job.progress)
        }
        // activity.update calls burn CPU + ActivityKit's update budget, so
        // gate on the same whole-percent change as the in-process
        // notification above; always update on a phase transition.
        if phaseChanged || percentChanged {
            Task { await updateActivity(for: job) }
        }
    }

    public func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let description = downloadTask.taskDescription,
              let parts = Self.taskParts(description),
              let jobID = parts.jobID,
              let job = store.job(id: jobID)
        else { return }
        guard job.phase != .suspended else { return }
        if parts.role == .media {
            store.removeResumeData(for: job)
        }
        switch parts.role {
        case .resolve:
            finishResolve(job: job, downloadedTo: location, response: downloadTask.response)
        case .media:
            finish(job: job, downloadedTo: location, response: downloadTask.response)
        case .redditVideo:
            finishRedditVideo(job: job, location: location, response: downloadTask.response)
        case .redditAudio:
            finishRedditAudio(job: job, location: location, response: downloadTask.response)
        case .redditManifest:
            finishRedditManifest(job: job, location: location, response: downloadTask.response)
        case .none:
            break
        }
    }

    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let error,
              let description = task.taskDescription,
              let parts = Self.taskParts(description),
              let jobID = parts.jobID,
              var job = store.job(id: jobID)
        else { return }
        guard job.phase != .suspended else { return }
        if parts.role == .media,
           let resumeData = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data,
           let fileName = store.saveResumeData(resumeData, for: job.id) {
            job.resumeDataFileName = fileName
            store.upsert(job)
        }
        switch parts.role {
        case .redditVideo:
            startTrackedBackgroundWork {
                await self.retryRedditVideoOrFail(
                    job: job, response: task.response, error: error)
            }
        case .redditAudio:
            startRedditManifestFallback(jobID: job.id)
        case .redditManifest:
            finishRedditWithoutAudio(jobID: job.id)
        case .resolve, .media, .none:
            startTrackedBackgroundWork {
                await self.retryOrFail(
                    job: job,
                    role: parts.role ?? .media,
                    response: task.response,
                    error: error,
                    message: MediaDownloadError.downloadFailed.message)
            }
        }
    }

    public func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        markBackgroundEventsFinished()
    }
}

private extension LiveMediaDownloadManager {
    enum TaskRole: String {
        case resolve
        case media
        case redditVideo
        case redditAudio
        case redditManifest
    }

    static func taskParts(_ description: String) -> (jobID: String?, role: TaskRole?, attempt: Int?)? {
        let parts = description.split(separator: "|").map(String.init)
        guard parts.count >= 2 else { return nil }
        return (parts[0], TaskRole(rawValue: parts[1]), parts.dropFirst(2).first.flatMap(Int.init))
    }
}
