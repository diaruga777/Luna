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

public final class LiveMediaDownloadManager: NSObject {
    public static let shared = LiveMediaDownloadManager()

    private static let sessionIdentifier = "com.hsanabria.luna.mediaDownload.background"
    static let failureDismissalDelay: TimeInterval = 14
    private static let maxTransientAttempts = 2
    private static let suspensionGracePeriod: TimeInterval = 5
    private let store = JobStore()
    private let saver: PhotoLibrarySaving
    private var backgroundCompletionHandler: (() -> Void)?

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
        guard let asset = assets.first, let sourceURL = URL(string: sourceURLString) else { return false }
        let ownership: LiveMediaDownloadOwnership = MediaAutoDownloader.isRunningInDownloader
            ? .downloader : .invokingApp
        // Non-Downloader saves write straight to Photos, so we need add-authorization.
        let canSave = ownership == .downloader ? true : await saver.requestAddAuthorization()
        guard canSave else {
            await startFailedActivity(
                urlString: sourceURLString, title: title,
                message: MediaDownloadError.permissionDenied.message, errorKind: .photosPermission)
            return false
        }
        let readingItem = ReadingListStore.shared.item(forURLString: sourceURLString)
        var job = LiveMediaDownloadJob(
            id: UUID().uuidString,
            sourceURLString: sourceURLString,
            assetURLString: asset.url.absoluteString,
            mediaKind: asset.kind.rawValue,
            title: title ?? readingItem?.title ?? Self.title(for: sourceURL),
            creator: readingItem?.channelName,
            resolveKind: "rescue",
            phase: .downloading,
            progress: 0,
            thumbnailFileName: nil,
            fileExtension: nil,
            expectedByteCount: asset.estimatedByteCount,
            receivedByteCount: nil,
            resumeDataFileName: nil,
            rangeStartSeconds: nil,
            rangeEndSeconds: nil,
            resolvedVideoID: nil,
            youtubeVisitorData: nil,
            errorMessage: nil,
            errorKind: nil,
            resolveAttempts: 0,
            mediaAttempts: 0,
            suspendDeadline: nil,
            ownership: ownership)
        store.upsert(job)
        if job.isDownloaderOwned { postDownloaderJobProgress(job: job, progress: 0) }
        await startActivity(for: job)
        startMediaDownload(for: job, asset: asset)
        return true
    }

    private func createAndStartJob(_ gated: GateResult, title: String?) async -> Bool {
        let jobID = UUID().uuidString
        var job = LiveMediaDownloadJob(
            id: jobID,
            sourceURLString: gated.urlString,
            assetURLString: nil,
            mediaKind: "unknown",
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
            rangeStartSeconds: nil,
            rangeEndSeconds: nil,
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
            job.rangeStartSeconds = youtube.timeRange?.startSeconds
            job.rangeEndSeconds = youtube.timeRange?.endSeconds
        }
        if let directAsset = MediaAsset.direct(url: gated.sourceURL) {
            job.resolveKind = "direct"
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
        job.resolveKind = resolve.kind
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
        Task { await prepareAndStartMediaDownload(for: job, asset: asset) }
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
        job.mediaKind = asset.kind.liveActivityKind
        job.fileExtension = MediaFileDownloader.fileExtension(for: asset, mimeType: nil)
        job.expectedByteCount = expected
        job.rangeStartSeconds = asset.timeRange?.startSeconds
        job.rangeEndSeconds = asset.timeRange?.endSeconds
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
        backgroundCompletionHandler = completionHandler
        _ = session
        Task { await reapExpiredSuspensions() }
    }

    public func resumeLiveActivities() {
        Task {
            await resumeUnfinishedDownloads()
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
            job.resolveKind = resolve.kind
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
                requiresProcessingCopy: job.rangeStartSeconds != nil
                    || job.rangeEndSeconds != nil
            ) {
                await failJob(job, message: storageError.message)
                return
            }
            job.errorMessage = nil
            job.phase = .downloading
            store.upsert(job)
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

    /// Live progress (0...1) of a non-terminal Downloader-owned job for this
    /// source URL, or `nil` if none is running — used by the grid to decide
    /// whether a cell shows the progress ring or the static "undownloaded" icon.
    public func currentDownloadProgress(forSourceURLString urlString: String) -> Double? {
        guard let job = store.job(forSourceURLString: urlString), job.isDownloaderOwned else { return nil }
        return job.progress
    }

    public func currentDownloadSnapshot(
        forSourceURLString urlString: String
    ) -> DownloaderJobSnapshot? {
        guard let job = store.job(forSourceURLString: urlString), job.isDownloaderOwned else {
            return nil
        }
        return job.downloaderSnapshot
    }

    /// Waits for a Downloader-owned background/Live Activity job to materialize
    /// its durable file. Used only for App Intent downloads below the inline size
    /// threshold; the transfer itself still runs through the same background
    /// URLSession state machine as larger handoffs.
    public func waitForDownloaderResult(
        forSourceURLString urlString: String
    ) async -> SavedMediaItem? {
        while !Task.isCancelled {
            if let item = SavedMediaStore.shared.existingDownloadedItem(
                forURLString: urlString) {
                return item
            }
            guard store.job(forSourceURLString: urlString) != nil else { return nil }
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
        if let assetURLString = job.assetURLString,
           let assetURL = URL(string: assetURLString),
           let sourceURL = URL(string: job.sourceURLString) {
            if let storageError = MediaDownloadPreflight.storageError(
                expectedByteCount: job.expectedByteCount,
                directory: JobStore.directory,
                requiresProcessingCopy: job.rangeStartSeconds != nil
                    || job.rangeEndSeconds != nil
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
            job.resolveKind = resolve.kind
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

    public func reapExpiredSuspensions() async {
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
        return "Media download"
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
        }
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

    /// The stage of a persisted background resolve. `LiveMediaDownloadJob.resolveKind`
    /// stores the raw string rather than this type, so jobs.json (and its decoding of
    /// jobs written by earlier builds) never depends on this enum's case list — this
    /// exists only to give the dispatch below compiler-checked cases instead of the
    /// hand-matched string literals it used to switch on. An unrecognized raw string
    /// (there is no known way to produce one today) simply fails to match any case
    /// below, the same as it silently failed to match any string literal before.
    private enum ResolveKind: String {
        case x
        case tiktok
        case instagramEmbed
        case facebookPlugin
        case facebookDesktop
        case facebookMobile
        case facebookCanonical
        case facebookCrawler
        case facebook
        case facebookShort
        case reddit
        case youtubeClip
        case youtubeWatch
        case youtubePlayerJavaScript
        case youtubeAndroidVR
        case youtubePlayer
        case youtubeEmbed
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
            guard let code = recognized.itemID,
                  let url = URL(string: "https://www.instagram.com/p/\(code)/embed/captioned/")
            else { return nil }
            resolveURL = url
            kind = .instagramEmbed
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
        switch job.resolveKind.flatMap(ResolveKind.init(rawValue:)) {
        case .x:
            return XMediaParser.assets(fromFxJSON: data).first
        case .tiktok:
            guard let html = String(data: data, encoding: .utf8) else { return nil }
            return TikTokMediaParser.assets(fromHTML: html).first
        case .instagramEmbed:
            guard let html = String(data: data, encoding: .utf8) else { return nil }
            return InstagramMediaParser.assetsFromEmbedContextJSON(html).first
                ?? InstagramMediaParser.assets(fromHTML: html).first
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
            let range = MediaTimeRange(
                startSeconds: job.rangeStartSeconds ?? 0,
                endSeconds: job.rangeEndSeconds)
            return YouTubePlayerResponseParser.asset(
                from: data,
                videoID: videoID,
                timeRange: range.isEffective ? range : nil)
        case .youtubeClip, .youtubeWatch, .youtubePlayerJavaScript:
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
            Task {
                await retryOrFail(
                    job: job, role: .media, response: response,
                    message: MediaDownloadError.downloadFailed.message)
            }
            return
        }

        let kind = job.mediaAssetKind
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
            Task { await failJob(job, message: MediaDownloadError.downloadFailed.message) }
        }
    }

    /// Completes a persisted local post-processing stage. The original transfer
    /// lives at `.source.<ext>` until any requested trim has successfully produced
    /// the final file. If termination occurs after the final move, the absence of
    /// the staging file proves that trimming already completed and prevents a
    /// timestamp range from being applied twice.
    private func resumeFinalization(for persistedJob: LiveMediaDownloadJob) {
        let jobID = persistedJob.id
        Task {
            guard var job = self.store.job(id: jobID), job.phase == .saving else { return }
            let ext = job.fileExtension ?? (job.mediaAssetKind == .video ? "mp4" : "jpg")
            let staging = JobStore.stagingURL(fileName: "\(job.id).source.\(ext)")
            let destination = JobStore.downloadURL(fileName: "\(job.id).\(ext)")
            do {
                if FileManager.default.fileExists(atPath: staging.path) {
                    let range = MediaTimeRange(
                        startSeconds: job.rangeStartSeconds ?? 0,
                        endSeconds: job.rangeEndSeconds)
                    let processed = try await MediaVideoTrimmer.trimIfNeeded(
                        fileURL: staging,
                        timeRange: job.mediaAssetKind == .video ? range : nil)
                    try? FileManager.default.removeItem(at: destination)
                    try FileManager.default.moveItem(at: processed, to: destination)
                    if processed != staging {
                        try? FileManager.default.removeItem(at: staging)
                    }
                }
                guard FileManager.default.fileExists(atPath: destination.path) else {
                    throw MediaDownloadError.downloadFailed
                }
                if job.mediaAssetKind == .video, job.thumbnailFileName == nil {
                    job.thumbnailFileName = makeVideoThumbnail(
                        from: destination, jobID: job.id)
                }
                store.upsert(job)
                await save(job: job, fileURL: destination, kind: job.mediaAssetKind)
            } catch {
                guard let current = self.store.job(id: jobID) else { return }
                await failJob(current, message: MediaDownloadError.downloadFailed.message)
            }
        }
    }

    /// Reddit hosts video and audio as two separate CDN files (its DASH
    /// pipeline) rather than one playable URL, so this bypasses the shared
    /// background-session task/delegate state machine above (built around one
    /// URL producing one file) and does its own plain async fetch + mux,
    /// finishing through the same `finalizeDownloadedFile` tail as everything
    /// else. Reddit clips are short, so this deliberately doesn't retrofit the
    /// resumable-background-task machinery for a two-stream case. If the
    /// audio companion (a derived URL, not one Reddit hands back directly —
    /// see `RedditMediaParser`) can't be fetched, degrades to the silent
    /// video rather than failing the whole download.
    private func startRedditMuxedDownload(
        for job: LiveMediaDownloadJob, videoURL: URL, audioURL: URL, dashManifestURL: URL?
    ) {
        let jobID = job.id
        Task {
            // Re-fetches current job state right before each terminal action
            // (rather than trusting the snapshot captured when this Task was
            // started) so a suspend that raced with these fetches is honored.
            func currentlyRunningJob() -> LiveMediaDownloadJob? {
                guard let current = self.store.job(id: jobID), current.phase != .suspended else { return nil }
                return current
            }

            do {
                let videoFile = try await plainDownload(videoURL)
                self.reportProgress(jobID: jobID, progress: 0.5)

                guard let audioFile = await RedditAudioFetcher.fetch(
                    primaryAudioURL: audioURL, dashManifestURL: dashManifestURL,
                    referer: "https://www.reddit.com/")
                else {
                    self.reportProgress(jobID: jobID, progress: 1)
                    guard let current = currentlyRunningJob() else { return }
                    finalizeDownloadedFile(job: current, temporaryLocation: videoFile, fileExtension: "mp4", kind: .video)
                    return
                }
                self.reportProgress(jobID: jobID, progress: 0.8)

                let muxedURL = MediaDownloadStorage.newFileURL(extension: "mp4")
                let finalFile: URL
                do {
                    try await MediaMuxer.mux(videoURL: videoFile, audioURL: audioFile, outputURL: muxedURL)
                    try? FileManager.default.removeItem(at: videoFile)
                    finalFile = muxedURL
                } catch {
                    finalFile = videoFile
                }
                try? FileManager.default.removeItem(at: audioFile)
                self.reportProgress(jobID: jobID, progress: 1)
                guard let current = currentlyRunningJob() else { return }
                finalizeDownloadedFile(job: current, temporaryLocation: finalFile, fileExtension: "mp4", kind: .video)
            } catch {
                guard let current = currentlyRunningJob() else { return }
                await failJob(current, message: MediaDownloadError.downloadFailed.message)
            }
        }
    }

    /// A plain (non-background-session) streamed download to a temp file,
    /// used only by the Reddit mux path above.
    private func plainDownload(_ url: URL) async throws -> URL {
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.setValue(MediaDownloadHTTP.browserUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://www.reddit.com/", forHTTPHeaderField: "Referer")
        let (location, response) = try await URLSession.shared.download(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw MediaDownloadError.downloadFailed
        }
        let destination = MediaDownloadStorage.newFileURL(extension: "mp4")
        try FileManager.default.moveItem(at: location, to: destination)
        return destination
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
            if startNextFacebookResolve(after: job, data: nil) { return }
            if startNextYouTubeResolve(after: job, data: nil) { return }
            Task {
                await retryOrFail(
                    job: job, role: .resolve, response: response,
                    message: MediaDownloadError.noMedia.message)
            }
            return
        }
        guard let data = try? Data(contentsOf: location) else {
            Task { await failJob(job, message: MediaDownloadError.noMedia.message, errorKind: .noMedia) }
            return
        }
        if job.resolveKind == ResolveKind.youtubeClip.rawValue,
           let html = String(data: data, encoding: .utf8),
           let clip = YouTubeClipParser.descriptor(fromHTML: html),
           let watchURL = YouTubeLink.watchURL(videoID: clip.videoID) {
            job.resolvedVideoID = clip.videoID
            job.rangeStartSeconds = clip.timeRange.startSeconds
            job.rangeEndSeconds = clip.timeRange.endSeconds
            job.resolveKind = ResolveKind.youtubeWatch.rawValue
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
        if startNextFacebookResolve(after: job, data: data) { return }
        if startNextYouTubeResolve(after: job, data: data) { return }
        Task { await failJob(job, message: MediaDownloadError.noMedia.message, errorKind: .noMedia) }
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
        switch persistedJob.resolveKind.flatMap(ResolveKind.init(rawValue:)) {
        case .youtubeWatch:
            if let data,
               let bootstrap = YouTubePlaybackBootstrapParser.bootstrap(
                fromWatchData: data) {
                var job = persistedJob
                job.youtubeVisitorData = bootstrap.visitorData
                job.resolveKind = ResolveKind.youtubePlayerJavaScript.rawValue
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
        job.resolveKind = kind.rawValue
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
        job.resolveKind = resolve.kind
        store.upsert(job)
        startTask(resolve.request, jobID: job.id, role: .resolve, attempt: job.resolveAttempts)
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
        switch persistedJob.resolveKind.flatMap(ResolveKind.init(rawValue:)) {
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
        job.resolveKind = next.kind.rawValue
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
                requiresProcessingCopy: freshJob.rangeStartSeconds != nil
                    || freshJob.rangeEndSeconds != nil
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
                requiresProcessingCopy: retryJob.rangeStartSeconds != nil
                    || retryJob.rangeEndSeconds != nil
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
        store.remove(job.id)
    }

    private func tearDownSuspendedJob(_ job: LiveMediaDownloadJob) async {
        await cancelTasks(jobID: job.id)
        await endActivity(for: job, dismissalDelay: 0)
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
              parts.role == .media,
              let jobID = parts.jobID,
              var job = store.job(id: jobID),
              job.phase != .suspended
        else { return }
        let previousPercent = Int(job.progress * 100)
        let phaseChanged = job.phase != .downloading
        job.phase = .downloading
        job.progress = min(1, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
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
        if parts.role == .resolve {
            finishResolve(job: job, downloadedTo: location, response: downloadTask.response)
        } else {
            finish(job: job, downloadedTo: location, response: downloadTask.response)
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
        Task {
            await retryOrFail(
                job: job,
                role: parts.role ?? .media,
                response: task.response,
                error: error,
                message: MediaDownloadError.downloadFailed.message)
        }
    }

    public func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async { [weak self] in
            self?.backgroundCompletionHandler?()
            self?.backgroundCompletionHandler = nil
        }
    }
}

private extension LiveMediaDownloadManager {
    enum TaskRole: String {
        case resolve
        case media
    }

    static func taskParts(_ description: String) -> (jobID: String?, role: TaskRole?, attempt: Int?)? {
        let parts = description.split(separator: "|").map(String.init)
        guard parts.count >= 2 else { return nil }
        return (parts[0], TaskRole(rawValue: parts[1]), parts.dropFirst(2).first.flatMap(Int.init))
    }
}
