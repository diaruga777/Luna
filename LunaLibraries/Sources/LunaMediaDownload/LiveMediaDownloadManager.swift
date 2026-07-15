//
//  LiveMediaDownloadManager.swift
//  Luna
//

import LunaAppConfig
import LunaStorage
import LunaURLClassification
import AVFoundation
import Foundation
import ImageIO
import Photos
import UIKit

#if canImport(ActivityKit)
import ActivityKit
#endif

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
        return phase == .resolving || phase == .downloading
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
    case suspended
    case saving
    case finished
    case failed
}

/// A snapshot of a Downloader-owned job's public-facing state — everything the
/// footer status view needs to mirror the Live Activity (title, phase/message,
/// progress, thumbnail).
public struct DownloaderJobSnapshot: Equatable {
    public let sourceURLString: String
    public let title: String
    public let phase: DownloaderJobPhase
    public let progress: Double
    public let message: String
    public let thumbnailFileName: String?
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
    private static let failureDismissalDelay: TimeInterval = 14
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
        await reapExpiredSuspensions()

        let urlString = await Self.canonicalRedditURLStringIfNeeded(urlString)

        guard MediaDownloadablePlatform.supports(urlString),
              let sourceURL = URL(string: urlString)
        else { return false }

        let ownership = ownership ?? (MediaAutoDownloader.isRunningInDownloader
            ? .downloader : .invokingApp)
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
                return false
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
                return false
            }
        } else if AutoDownloadSettings.wasDownloaded(urlString) {
            return false
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
            return false
        }

        if var existing = store.jobs().first(where: {
            $0.sourceURLString == urlString && !$0.isTerminal
        }) {
            if ownership == .downloader && !existing.isDownloaderOwned {
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
                    return false
                }
                existing = restarted
            }
            await updateActivity(for: existing)
            return true
        }

        let jobID = UUID().uuidString
        var job = LiveMediaDownloadJob(
            id: jobID,
            sourceURLString: urlString,
            assetURLString: nil,
            mediaKind: "unknown",
            title: title ?? Self.title(for: sourceURL),
            creator: readingItem?.channelName,
            resolveKind: nil,
            phase: .resolving,
            progress: 0,
            thumbnailFileName: nil,
            fileExtension: nil,
            errorMessage: nil,
            errorKind: nil,
            resolveAttempts: 0,
            mediaAttempts: 0,
            suspendDeadline: nil,
            ownership: ownership
        )
        guard let resolve = Self.resolveRequest(for: sourceURL) else {
            store.upsert(job)
            await failJob(job, message: MediaDownloadError.unsupported.message)
            return false
        }
        job.resolveKind = resolve.kind
        store.upsert(job)
        // Register the durable background task before any UI-facing callback.
        // This closes the persist-without-task window that used to leave a
        // forever-resolving row if the app terminated during the callback.
        startTask(resolve.request, jobID: job.id, role: .resolve, attempt: job.resolveAttempts)
        if job.isDownloaderOwned {
            postDownloaderJobProgress(job: job, progress: 0)
        }
        await startActivity(for: job)
        return true
    }

    private func startMediaDownload(for job: LiveMediaDownloadJob, asset: MediaAsset) {
        guard let sourceURL = URL(string: job.sourceURLString) else { return }
        var job = job
        job.assetURLString = asset.url.absoluteString
        job.mediaKind = asset.kind.liveActivityKind
        job.fileExtension = MediaFileDownloader.fileExtension(for: asset, mimeType: nil)
        job.phase = .downloading
        store.upsert(job)
        Task { await updateActivity(for: job) }
        if job.isDownloaderOwned {
            postDownloaderJobProgress(job: job, progress: job.progress)
        }

        if let audioURL = asset.audioURL {
            startRedditMuxedDownload(
                for: job, videoURL: asset.url, audioURL: audioURL, dashManifestURL: asset.dashManifestURL)
            return
        }

        if asset.kind != .video {
            Task {
                var updated = job
                updated.thumbnailFileName = await makeThumbnail(from: asset.url, jobID: job.id)
                store.upsert(updated)
                await updateActivity(for: updated)
                if updated.isDownloaderOwned {
                    postDownloaderJobProgress(job: updated, progress: updated.progress)
                }
            }
        }

        var request = URLRequest(url: asset.url, timeoutInterval: 60)
        request.setValue(MediaDownloadHTTP.browserUserAgent, forHTTPHeaderField: "User-Agent")
        if sourceURL.host?.lowercased().contains("tiktok") == true {
            request.setValue("https://www.tiktok.com/", forHTTPHeaderField: "Referer")
        }
        startTask(request, jobID: job.id, role: .media, attempt: job.mediaAttempts)
    }

    public func attachBackgroundCompletionHandler(_ completionHandler: @escaping () -> Void) {
        backgroundCompletionHandler = completionHandler
        _ = session
        Task { await reapExpiredSuspensions() }
    }

    public func resumeLiveActivities() {
        Task {
            await reapExpiredSuspensions()
            let activeJobIDs = await activeTaskJobIDs()
            for job in store.jobs().filter({ !$0.isTerminal }) {
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
            guard let sourceURL = URL(string: job.sourceURLString),
                  let resolve = Self.resolveRequest(for: sourceURL)
            else {
                await failJob(job, message: MediaDownloadError.unsupported.message)
                return
            }
            job.resolveKind = resolve.kind
            job.errorMessage = nil
            store.upsert(job)
            startTask(
                resolve.request, jobID: job.id,
                role: .resolve, attempt: job.resolveAttempts)

        case .downloading:
            guard let assetURLString = job.assetURLString,
                  let assetURL = URL(string: assetURLString),
                  let sourceURL = URL(string: job.sourceURLString)
            else {
                // Incomplete old/corrupt downloading state can still be rebuilt
                // from the source resolver instead of remaining stuck forever.
                job.phase = .resolving
                job.progress = 0
                job.assetURLString = nil
                job.resolveKind = nil
                store.upsert(job)
                await restartTransfer(for: job)
                return
            }
            var request = URLRequest(url: assetURL, timeoutInterval: 60)
            request.setValue(MediaDownloadHTTP.browserUserAgent, forHTTPHeaderField: "User-Agent")
            if sourceURL.host?.lowercased().contains("tiktok") == true {
                request.setValue("https://www.tiktok.com/", forHTTPHeaderField: "Referer")
            }
            job.errorMessage = nil
            store.upsert(job)
            startTask(
                request, jobID: job.id,
                role: .media, attempt: job.mediaAttempts)

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
        for urlString in AutoDownloadSettings.pendingWiFiDownloadURLs() {
            _ = await start(urlString: urlString, ownership: .downloader)
        }
    }

    /// Starts every Wi-Fi-deferred download right away, ignoring current
    /// network type — used when the user turns `wifiOnlyDownloads` back off,
    /// so already-deferred items don't keep waiting for the next opportunistic
    /// trigger.
    public func startAllPendingWiFiDownloads() async {
        for urlString in AutoDownloadSettings.pendingWiFiDownloadURLs() {
            _ = await start(urlString: urlString, ownership: .downloader, manual: true)
        }
    }

    /// Live progress (0...1) of a non-terminal Downloader-owned job for this
    /// source URL, or `nil` if none is running — used by the grid to decide
    /// whether a cell shows the progress ring or the static "undownloaded" icon.
    public func currentDownloadProgress(forSourceURLString urlString: String) -> Double? {
        guard let job = store.job(forSourceURLString: urlString), job.isDownloaderOwned else { return nil }
        return job.progress
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
        await cancelTasks(jobID: jobID)

        Task {
            try? await Task.sleep(nanoseconds: UInt64(Self.suspensionGracePeriod * 1_000_000_000))
            await self.reapExpiredSuspensions()
        }
    }

    public func resume(jobID: String) async {
        guard var job = store.job(id: jobID), job.phase == .suspended else { return }
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
            job.phase = .downloading
            store.upsert(job)
            await updateActivity(for: job)
            if job.isDownloaderOwned {
                postDownloaderJobProgress(job: job, progress: job.progress)
            }
            var request = URLRequest(url: assetURL, timeoutInterval: 60)
            request.setValue(MediaDownloadHTTP.browserUserAgent, forHTTPHeaderField: "User-Agent")
            if sourceURL.host?.lowercased().contains("tiktok") == true {
                request.setValue("https://www.tiktok.com/", forHTTPHeaderField: "Referer")
            }
            startTask(request, jobID: job.id, role: .media, attempt: job.mediaAttempts)
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

    private func startTask(_ request: URLRequest, jobID: String, role: TaskRole, attempt: Int) {
        let task = session.downloadTask(with: request)
        task.taskDescription = "\(jobID)|\(role.rawValue)|\(attempt)"
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

    static func resolveRequest(for url: URL) -> (request: URLRequest, kind: String)? {
        guard let recognized = PlatformRecognizer.recognize(url.absoluteString) else { return nil }
        let resolveURL: URL
        let kind: String
        switch recognized.platform {
        case .x:
            guard let id = recognized.itemID,
                  let url = URL(string: "https://api.fxtwitter.com/status/\(id)")
            else { return nil }
            resolveURL = url
            kind = "x"
        case .tiktok:
            resolveURL = url
            kind = "tiktok"
        case .instagram:
            guard let code = recognized.itemID,
                  let url = URL(string: "https://www.instagram.com/p/\(code)/embed/captioned/")
            else { return nil }
            resolveURL = url
            kind = "instagramEmbed"
        case .facebook:
            // Match SocialMediaResolver's foreground/extension path: Facebook's
            // logged-out reel page commonly returns HTTP 400 or a poster-only login
            // wall, while the video plugin exposes the playable hd_src/sd_src MP4.
            // Keep the stage in resolveKind so a persisted background job can fall
            // through to the desktop and mobile pages if the plugin has no asset.
            guard let pluginURL = SocialMediaResolver.facebookVideoPluginURL(for: url)
            else { return nil }
            resolveURL = pluginURL
            kind = "facebookPlugin"
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
            kind = "reddit"
        default:
            return nil
        }
        var request = URLRequest(url: resolveURL, timeoutInterval: 60)
        if kind == "x" {
            request.setValue("application/json", forHTTPHeaderField: "Accept")
        } else {
            let userAgent = kind.hasPrefix("facebook")
                ? MediaDownloadHTTP.desktopBrowserUserAgent
                : MediaDownloadHTTP.browserUserAgent
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        }
        return (request, kind)
    }

    private func resolvedAsset(from data: Data, job: LiveMediaDownloadJob) -> MediaAsset? {
        switch job.resolveKind {
        case "x":
            return XMediaParser.assets(fromFxJSON: data).first
        case "tiktok":
            guard let html = String(data: data, encoding: .utf8) else { return nil }
            return TikTokMediaParser.assets(fromHTML: html).first
        case "instagramEmbed":
            guard let html = String(data: data, encoding: .utf8) else { return nil }
            return InstagramMediaParser.assetsFromEmbedContextJSON(html).first
                ?? InstagramMediaParser.assets(fromHTML: html).first
        case "facebookPlugin", "facebookDesktop", "facebookMobile", "facebookCanonical",
             "facebook", "facebookShort":
            guard let html = String(data: data, encoding: .utf8) else { return nil }
            return FacebookMediaParser.assets(fromHTML: html).first
        case "reddit":
            return RedditMediaParser.asset(fromListingJSON: data)
        default:
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
              ] as CFDictionary),
              let destination = CGImageDestinationCreateWithURL(
                JobStore.thumbnailURL(fileName: "\(jobID).jpg") as CFURL,
                "public.jpeg" as CFString,
                1,
                nil)
        else { return nil }
        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return "\(jobID).jpg"
    }

    private func makeVideoThumbnail(from fileURL: URL, jobID: String) -> String? {
        let asset = AVURLAsset(url: fileURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        guard let cgImage = try? generator.copyCGImage(at: .zero, actualTime: nil),
              let destination = CGImageDestinationCreateWithURL(
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
        let destination = JobStore.downloadURL(fileName: "\(job.id).\(ext)")
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: temporaryLocation, to: destination)
            if kind == .video, job.thumbnailFileName == nil {
                job.thumbnailFileName = makeVideoThumbnail(from: destination, jobID: job.id)
            }
            job.phase = .saving
            job.progress = 1
            store.upsert(job)
            Task { await updateActivity(for: job) }
            if job.isDownloaderOwned {
                postDownloaderJobProgress(job: job, progress: 1)
            }
            Task { await save(job: job, fileURL: destination, kind: kind) }
        } catch {
            Task { await failJob(job, message: MediaDownloadError.downloadFailed.message) }
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
        let job = job
        guard job.phase != .suspended else { return }
        let http = response as? HTTPURLResponse
        if let http, !(200..<300).contains(http.statusCode) {
            if startNextFacebookResolve(after: job, data: nil) { return }
            Task {
                await retryOrFail(
                    job: job, role: .resolve, response: response,
                    message: MediaDownloadError.noMedia.message)
            }
            return
        }
        guard let data = try? Data(contentsOf: location) else {
            Task { await failJob(job, message: MediaDownloadError.noMedia.message) }
            return
        }
        if let asset = resolvedAsset(from: data, job: job) {
            startMediaDownload(for: job, asset: asset)
            return
        }
        if startNextFacebookResolve(after: job, data: data) { return }
        Task { await failJob(job, message: MediaDownloadError.noMedia.message) }
        return
    }

    /// Advances the durable Facebook resolver through the same useful sources as
    /// `SocialMediaResolver`: plugin embed → desktop page → mobile page → desktop
    /// canonical page. Returns true after starting the next background task.
    private func startNextFacebookResolve(
        after persistedJob: LiveMediaDownloadJob, data: Data?
    ) -> Bool {
        guard let sourceURL = URL(string: persistedJob.sourceURLString) else { return false }

        let next: (url: URL, kind: String, userAgent: String)?
        switch persistedJob.resolveKind {
        case "facebookPlugin":
            next = (sourceURL, "facebookDesktop", MediaDownloadHTTP.desktopBrowserUserAgent)
        case "facebookDesktop", "facebook":
            next = (sourceURL, "facebookMobile", MediaDownloadHTTP.browserUserAgent)
        case "facebookMobile", "facebookShort":
            guard let data,
                  let html = String(data: data, encoding: .utf8),
                  let canonical = FacebookMediaParser.canonicalVideoURL(fromHTML: html),
                  canonical.absoluteString != sourceURL.absoluteString
            else { return false }
            next = (canonical, "facebookCanonical", MediaDownloadHTTP.desktopBrowserUserAgent)
        default:
            return false
        }

        guard let next else { return false }
        var job = persistedJob
        job.resolveKind = next.kind
        store.upsert(job)
        var request = URLRequest(url: next.url, timeoutInterval: 60)
        request.setValue(next.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        startTask(request, jobID: job.id, role: .resolve, attempt: job.resolveAttempts)
        return true
    }

    private func save(job: LiveMediaDownloadJob, fileURL: URL, kind: MediaAsset.Kind) async {
        var job = job
        guard job.phase != .suspended else { return }
        do {
            if job.isDownloaderOwned {
                let item = try await finishDownloaderStorage(
                    job: job, fileURL: fileURL, kind: kind)
                await copyToClipboardIfEnabled(item)
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
        if AutoDownloadSettings.autoSaveDownloadsToPhotos,
           await saver.requestReadAuthorization(),
           let pending = SavedMediaStore.shared.matchingItem(forURLString: job.sourceURLString) {
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
            fileExtension: job.fileExtension)
    }

    @MainActor
    private func copyToClipboardIfEnabled(_ item: SavedMediaItem) {
        guard AutoDownloadSettings.autoCopyDownloadsToClipboard,
              let kind = item.kind else { return }
        switch item.storageState {
        case .localFile:
            if let url = item.fileURL { _ = MediaPasteboard.copy(.localFile(url)) }
        case .photosReference(let identifier, _, _):
            _ = MediaPasteboard.copy(.photo(localIdentifier: identifier, kind: kind))
        case .undownloaded:
            break
        }
    }

    private func retryOrFail(
        job: LiveMediaDownloadJob,
        role: TaskRole,
        response: URLResponse?,
        error: Error? = nil,
        message: String
    ) async {
        guard isTransient(response: response, error: error),
              var retryJob = store.job(id: job.id)
        else {
            await failJob(job, message: message)
            return
        }

        switch role {
        case .resolve:
            guard retryJob.resolveAttempts + 1 < Self.maxTransientAttempts,
                  let url = URL(string: retryJob.sourceURLString),
                  let resolve = Self.resolveRequest(for: url)
            else {
                await failJob(retryJob, message: message)
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
                await failJob(retryJob, message: message)
                return
            }
            retryJob.mediaAttempts += 1
            retryJob.errorMessage = nil
            store.upsert(retryJob)
            var request = URLRequest(url: assetURL, timeoutInterval: 60)
            request.setValue(MediaDownloadHTTP.browserUserAgent, forHTTPHeaderField: "User-Agent")
            if sourceURL.host?.lowercased().contains("tiktok") == true {
                request.setValue("https://www.tiktok.com/", forHTTPHeaderField: "Referer")
            }
            startTask(request, jobID: retryJob.id, role: .media, attempt: retryJob.mediaAttempts)
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
        store.upsert(job, progressOnly: !phaseChanged)
        if job.isDownloaderOwned, Int(job.progress * 100) != previousPercent {
            postDownloaderJobProgress(job: job, progress: job.progress)
        }
        Task { await updateActivity(for: job) }
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

#if canImport(ActivityKit)
@available(iOS 16.1, *)
private extension LiveMediaDownloadAttributes.MediaKind {
    init(rawJobValue: String) {
        self = LiveMediaDownloadAttributes.MediaKind(rawValue: rawJobValue) ?? .unknown
    }
}

@available(iOS 16.1, *)
private extension LiveMediaDownloadAttributes.ContentState.Phase {
    init(jobPhase: LiveMediaDownloadJob.Phase) {
        switch jobPhase {
        case .resolving: self = .resolving
        case .downloading: self = .downloading
        case .suspended: self = .suspended
        case .saving: self = .saving
        case .finished: self = .finished
        case .failed: self = .failed
        }
    }
}
#endif

private extension LiveMediaDownloadManager {
    /// `announce` fires a system alert (banner + sound) the moment the Live
    /// Activity appears, so a download starting reads as more than a silent
    /// Dynamic Island update. Suppressed for `startFailedActivity`, which
    /// never actually starts a download — only its (single) end-of-life alert
    /// should fire there.
    func startActivity(for job: LiveMediaDownloadJob, announce: Bool = true) async {
        #if canImport(ActivityKit)
        guard #available(iOS 16.1, *), ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let attributes = LiveMediaDownloadAttributes(
            jobID: job.id,
            sourceURLString: job.sourceURLString,
            title: job.title)
        let state = activityState(for: job)
        do {
            let activity = try Activity.request(attributes: attributes, contentState: state, pushType: nil)
            if announce {
                await activity.update(
                    using: state,
                    alertConfiguration: AlertConfiguration(
                        title: "Download started", body: "\(job.title)", sound: .default))
            }
        } catch {
            SharedDiagnosticLog.record(
                "live activity request failed: \(error)", category: "media-download")
        }
        #endif
    }

    func startFailedActivity(
        urlString: String,
        title: String?,
        message: String,
        errorKind: LiveMediaDownloadJob.ErrorKind = .download
    ) async {
        var job = LiveMediaDownloadJob(
            id: UUID().uuidString,
            sourceURLString: urlString,
            assetURLString: nil,
            mediaKind: "unknown",
            title: title ?? "Media download",
            creator: nil,
            resolveKind: nil,
            phase: .failed,
            progress: 0,
            thumbnailFileName: nil,
            fileExtension: nil,
            errorMessage: message,
            errorKind: errorKind,
            resolveAttempts: 0,
            mediaAttempts: 0,
            suspendDeadline: nil,
            ownership: MediaAutoDownloader.isRunningInDownloader ? .downloader : .invokingApp
        )
        job.fail(message: message, kind: errorKind)
        await startActivity(for: job, announce: false)
        await endActivity(for: job, dismissalDelay: Self.failureDismissalDelay)
    }

    func updateActivity(for job: LiveMediaDownloadJob) async {
        #if canImport(ActivityKit)
        guard #available(iOS 16.1, *) else { return }
        let state = activityState(for: job)
        for activity in Activity<LiveMediaDownloadAttributes>.activities
            where activity.attributes.jobID == job.id {
            await activity.update(using: state)
        }
        #endif
    }

    func endActivity(for job: LiveMediaDownloadJob, dismissalDelay: TimeInterval = 20) async {
        #if canImport(ActivityKit)
        guard #available(iOS 16.1, *) else { return }
        let state = activityState(for: job)
        // A final alert right before ending — a silent Dynamic Island collapse
        // is easy to miss, so both a successful finish and a failure surface
        // as a system alert (banner + sound), matching the one at start. Not
        // for a user-canceled (still `.suspended` when torn down) job — that's
        // an intentional dismissal, not a result worth alerting about.
        var alert: AlertConfiguration?
        switch job.phase {
        case .finished, .failed:
            alert = AlertConfiguration(
                title: job.phase == .failed ? "Download failed" : "Download finished",
                body: "\(job.title)",
                sound: .default)
        default:
            alert = nil
        }
        for activity in Activity<LiveMediaDownloadAttributes>.activities
            where activity.attributes.jobID == job.id {
            if let alert {
                await activity.update(using: state, alertConfiguration: alert)
            }
            await activity.end(using: state, dismissalPolicy: .after(Date(timeIntervalSinceNow: dismissalDelay)))
        }
        #endif
    }

    #if canImport(ActivityKit)
    @available(iOS 16.1, *)
    func activityState(for job: LiveMediaDownloadJob) -> LiveMediaDownloadAttributes.ContentState {
        LiveMediaDownloadAttributes.ContentState(
            phase: .init(jobPhase: job.phase),
            progress: job.progress,
            mediaKind: .init(rawJobValue: job.mediaKind),
            message: job.statusMessage,
            thumbnailFileName: job.thumbnailFileName,
            // Reopen the app this download is running in — each app registers
            // only its own scheme now, so this can't hardcode Reader's.
            actionURLString: job.errorKind == .photosPermission
                ? "\(LunaDeepLink.ownScheme)://settings/photos" : nil,
            suspendDeadline: job.suspendDeadline
        )
    }
    #endif
}

struct LiveMediaDownloadJob: Codable, Equatable {
    enum Phase: String, Codable {
        case resolving
        case downloading
        case suspended
        case saving
        case finished
        case failed
    }

    enum ErrorKind: String, Codable {
        case download
        case photosPermission
    }

    var id: String
    var sourceURLString: String
    var assetURLString: String?
    var mediaKind: String
    var title: String
    /// Best-effort creator/author name (from the reading-list item's fetched
    /// platform metadata), carried through to `SavedMediaStore` on completion.
    var creator: String?
    var resolveKind: String?
    var phase: Phase
    var progress: Double
    var thumbnailFileName: String?
    var fileExtension: String?
    var errorMessage: String?
    var errorKind: ErrorKind?
    var resolveAttempts: Int
    var mediaAttempts: Int
    var suspendDeadline: Date?
    /// Nil only for jobs written by older builds. Those retain the former
    /// Bundle.main inference while every new job carries explicit ownership.
    var ownership: LiveMediaDownloadOwnership?

    var isTerminal: Bool { phase == .finished || phase == .failed }

    var isDownloaderOwned: Bool {
        ownership == .downloader
            || (ownership == nil && MediaAutoDownloader.isRunningInDownloader)
    }

    var mediaAssetKind: MediaAsset.Kind {
        switch mediaKind {
        case "video": return .video
        case "animatedImage": return .gif
        default: return .image
        }
    }

    mutating func fail(message: String, kind: ErrorKind = .download) {
        phase = .failed
        errorMessage = message
        errorKind = kind
        suspendDeadline = nil
    }

    /// The human-readable status line shown by both the Live Activity and the
    /// Downloader footer status view — kept as one source of truth so the two
    /// surfaces never drift.
    var statusMessage: String {
        switch phase {
        case .resolving: return "Preparing download"
        case .downloading: return "Downloading"
        case .suspended: return "Paused. Resume within 5 seconds."
        case .saving: return isDownloaderOwned ? "Saving to Luna" : "Saving to Photos"
        case .finished: return isDownloaderOwned ? "Saved to Luna" : "Saved to Photos"
        case .failed: return errorMessage ?? "Download failed"
        }
    }

    var downloaderSnapshot: DownloaderJobSnapshot {
        DownloaderJobSnapshot(
            sourceURLString: sourceURLString,
            title: title,
            phase: DownloaderJobPhase(rawValue: phase.rawValue) ?? .failed,
            progress: progress,
            message: statusMessage,
            thumbnailFileName: thumbnailFileName)
    }
}

private final class JobStore {
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

    static func thumbnailURL(fileName: String) -> URL {
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
        }
    }
}
