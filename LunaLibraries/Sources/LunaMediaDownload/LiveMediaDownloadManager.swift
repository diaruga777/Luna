//
//  LiveMediaDownloadManager.swift
//  Luna
//

import LunaAppConfig
import LunaURLClassification
import AVFoundation
import Foundation
import ImageIO
import Photos
import UIKit

#if canImport(ActivityKit)
import ActivityKit
#endif

public final class LiveMediaDownloadManager: NSObject {
    public static let shared = LiveMediaDownloadManager()

    private static let sessionIdentifier = "com.hsanabria.luna.mediaDownload.background"
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
    public func start(urlString: String, title: String? = nil) async -> Bool {
        guard MediaDownloadablePlatform.supports(urlString),
              let sourceURL = URL(string: urlString),
              !AutoDownloadSettings.wasDownloaded(urlString)
        else { return false }

        guard await saver.requestAddAuthorization() else {
            await startFailedActivity(urlString: urlString, title: title, message: MediaDownloadError.permissionDenied.message)
            return false
        }

        if let existing = store.jobs().first(where: {
            $0.sourceURLString == urlString && !$0.isTerminal
        }) {
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
            resolveKind: nil,
            phase: .resolving,
            progress: 0,
            thumbnailFileName: nil,
            fileExtension: nil,
            errorMessage: nil
        )
        store.upsert(job)
        await startActivity(for: job)

        guard let resolve = Self.resolveRequest(for: sourceURL) else {
            job.fail(message: MediaDownloadError.unsupported.message)
            store.upsert(job)
            await updateActivity(for: job)
            return false
        }
        job.resolveKind = resolve.kind
        store.upsert(job)
        let task = session.downloadTask(with: resolve.request)
        task.taskDescription = "\(job.id)|resolve"
        task.resume()
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
        if asset.kind != .video {
            Task {
                var updated = job
                updated.thumbnailFileName = await makeThumbnail(from: asset.url, jobID: job.id)
                store.upsert(updated)
                await updateActivity(for: updated)
            }
        }

        var request = URLRequest(url: asset.url, timeoutInterval: 60)
        request.setValue(MediaDownloadHTTP.browserUserAgent, forHTTPHeaderField: "User-Agent")
        if sourceURL.host?.lowercased().contains("tiktok") == true {
            request.setValue("https://www.tiktok.com/", forHTTPHeaderField: "Referer")
        }
        let task = session.downloadTask(with: request)
        task.taskDescription = "\(job.id)|media"
        task.resume()
    }

    public func attachBackgroundCompletionHandler(_ completionHandler: @escaping () -> Void) {
        backgroundCompletionHandler = completionHandler
        _ = session
    }

    public func resumeLiveActivities() {
        for job in store.jobs().filter({ !$0.isTerminal }) {
            Task { await updateActivity(for: job) }
        }
    }

    private static func title(for url: URL) -> String {
        if let host = url.host(percentEncoded: false), !host.isEmpty { return host }
        return "Media download"
    }

    private static func resolveRequest(for url: URL) -> (request: URLRequest, kind: String)? {
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
            resolveURL = url
            kind = "facebook"
        default:
            return nil
        }
        var request = URLRequest(url: resolveURL, timeoutInterval: 60)
        if kind == "x" {
            request.setValue("application/json", forHTTPHeaderField: "Accept")
        } else {
            request.setValue(MediaDownloadHTTP.browserUserAgent, forHTTPHeaderField: "User-Agent")
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
        case "facebook":
            guard let html = String(data: data, encoding: .utf8) else { return nil }
            return FacebookMediaParser.assets(fromHTML: html).first
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
        var job = job
        let http = response as? HTTPURLResponse
        if let http, !(200..<300).contains(http.statusCode) {
            job.fail(message: MediaDownloadError.downloadFailed.message)
            store.upsert(job)
            Task { await updateActivity(for: job) }
            return
        }

        let kind = job.mediaAssetKind
        let ext = MediaFileDownloader.fileExtension(
            for: MediaAsset(url: URL(string: job.assetURLString ?? job.sourceURLString)!, kind: kind),
            mimeType: http?.mimeType)
        let destination = JobStore.downloadURL(fileName: "\(job.id).\(ext)")
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            if kind == .video, job.thumbnailFileName == nil {
                job.thumbnailFileName = makeVideoThumbnail(from: destination, jobID: job.id)
            }
            job.phase = .saving
            job.progress = 1
            store.upsert(job)
            Task { await updateActivity(for: job) }
            Task { await save(job: job, fileURL: destination, kind: kind) }
        } catch {
            job.fail(message: MediaDownloadError.downloadFailed.message)
            store.upsert(job)
            Task { await updateActivity(for: job) }
        }
    }

    private func finishResolve(job: LiveMediaDownloadJob, downloadedTo location: URL, response: URLResponse?) {
        var job = job
        let http = response as? HTTPURLResponse
        if let http, !(200..<300).contains(http.statusCode) {
            job.fail(message: MediaDownloadError.noMedia.message)
            store.upsert(job)
            Task { await updateActivity(for: job) }
            return
        }
        guard let data = try? Data(contentsOf: location),
              let asset = resolvedAsset(from: data, job: job) else {
            job.fail(message: MediaDownloadError.noMedia.message)
            store.upsert(job)
            Task { await updateActivity(for: job) }
            return
        }
        startMediaDownload(for: job, asset: asset)
    }

    private func save(job: LiveMediaDownloadJob, fileURL: URL, kind: MediaAsset.Kind) async {
        var job = job
        do {
            try await saver.save(fileURL: fileURL, kind: kind)
            AutoDownloadSettings.markDownloaded(job.sourceURLString)
            job.phase = .finished
            job.progress = 1
            job.errorMessage = nil
            store.upsert(job)
            await updateActivity(for: job)
            await endActivity(for: job)
            store.remove(job.id)
        } catch {
            job.fail(message: MediaDownloadError.saveFailed.message)
            store.upsert(job)
            await updateActivity(for: job)
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
              let (jobID, role) = Self.taskParts(description),
              role == "media",
              var job = store.job(id: jobID)
        else { return }
        job.phase = .downloading
        job.progress = min(1, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
        store.upsert(job)
        Task { await updateActivity(for: job) }
    }

    public func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let description = downloadTask.taskDescription,
              let (jobID, role) = Self.taskParts(description),
              let job = store.job(id: jobID)
        else { return }
        if role == "resolve" {
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
              let (jobID, _) = Self.taskParts(description),
              var job = store.job(id: jobID)
        else { return }
        job.fail(message: MediaDownloadError.downloadFailed.message)
        store.upsert(job)
        Task { await updateActivity(for: job) }
    }

    public func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async { [weak self] in
            self?.backgroundCompletionHandler?()
            self?.backgroundCompletionHandler = nil
        }
    }
}

private extension LiveMediaDownloadManager {
    static func taskParts(_ description: String) -> (String, String)? {
        let parts = description.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        return (parts[0], parts[1])
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
        case .saving: self = .saving
        case .finished: self = .finished
        case .failed: self = .failed
        }
    }
}
#endif

private extension LiveMediaDownloadManager {
    func startActivity(for job: LiveMediaDownloadJob) async {
        #if canImport(ActivityKit)
        guard #available(iOS 16.1, *), ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let attributes = LiveMediaDownloadAttributes(
            jobID: job.id,
            sourceURLString: job.sourceURLString,
            title: job.title)
        let state = activityState(for: job)
        _ = try? Activity.request(attributes: attributes, contentState: state, pushType: nil)
        #endif
    }

    func startFailedActivity(urlString: String, title: String?, message: String) async {
        var job = LiveMediaDownloadJob(
            id: UUID().uuidString,
            sourceURLString: urlString,
            assetURLString: nil,
            mediaKind: "unknown",
            title: title ?? "Media download",
            resolveKind: nil,
            phase: .failed,
            progress: 0,
            thumbnailFileName: nil,
            fileExtension: nil,
            errorMessage: message
        )
        job.fail(message: message)
        await startActivity(for: job)
        await endActivity(for: job)
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

    func endActivity(for job: LiveMediaDownloadJob) async {
        #if canImport(ActivityKit)
        guard #available(iOS 16.1, *) else { return }
        let state = activityState(for: job)
        for activity in Activity<LiveMediaDownloadAttributes>.activities
            where activity.attributes.jobID == job.id {
            await activity.end(using: state, dismissalPolicy: .after(Date(timeIntervalSinceNow: 20)))
        }
        #endif
    }

    #if canImport(ActivityKit)
    @available(iOS 16.1, *)
    func activityState(for job: LiveMediaDownloadJob) -> LiveMediaDownloadAttributes.ContentState {
        let message: String
        switch job.phase {
        case .resolving: message = "Preparing download"
        case .downloading: message = "Downloading"
        case .saving: message = "Saving to Photos"
        case .finished: message = "Saved to Photos"
        case .failed: message = job.errorMessage ?? "Download failed"
        }
        return LiveMediaDownloadAttributes.ContentState(
            phase: .init(jobPhase: job.phase),
            progress: job.progress,
            mediaKind: .init(rawJobValue: job.mediaKind),
            message: message,
            thumbnailFileName: job.thumbnailFileName
        )
    }
    #endif
}

private struct LiveMediaDownloadJob: Codable, Equatable {
    enum Phase: String, Codable {
        case resolving
        case downloading
        case saving
        case finished
        case failed
    }

    var id: String
    var sourceURLString: String
    var assetURLString: String?
    var mediaKind: String
    var title: String
    var resolveKind: String?
    var phase: Phase
    var progress: Double
    var thumbnailFileName: String?
    var fileExtension: String?
    var errorMessage: String?

    var isTerminal: Bool { phase == .finished || phase == .failed }

    var mediaAssetKind: MediaAsset.Kind {
        switch mediaKind {
        case "video": return .video
        case "animatedImage": return .gif
        default: return .image
        }
    }

    mutating func fail(message: String) {
        phase = .failed
        errorMessage = message
    }
}

private final class JobStore {
    private let lock = NSLock()

    static var directory: URL {
        let fallback = FileManager.default.temporaryDirectory
        let base = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: AppConfig.appGroupID) ?? fallback
        let dir = base.appendingPathComponent("LiveMediaDownloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
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

    func jobs() -> [LiveMediaDownloadJob] {
        lock.withLock {
            guard let data = try? Data(contentsOf: Self.jobsURL),
                  let jobs = try? JSONDecoder().decode([LiveMediaDownloadJob].self, from: data)
            else { return [] }
            return jobs
        }
    }

    func job(id: String) -> LiveMediaDownloadJob? {
        jobs().first { $0.id == id }
    }

    func upsert(_ job: LiveMediaDownloadJob) {
        lock.withLock {
            var jobs: [LiveMediaDownloadJob]
            if let data = try? Data(contentsOf: Self.jobsURL),
               let decoded = try? JSONDecoder().decode([LiveMediaDownloadJob].self, from: data) {
                jobs = decoded
            } else {
                jobs = []
            }
            if let index = jobs.firstIndex(where: { $0.id == job.id }) {
                jobs[index] = job
            } else {
                jobs.append(job)
            }
            if let data = try? JSONEncoder().encode(jobs) {
                try? data.write(to: Self.jobsURL, options: .atomic)
            }
        }
    }

    func remove(_ id: String) {
        lock.withLock {
            let current: [LiveMediaDownloadJob]
            if let data = try? Data(contentsOf: Self.jobsURL),
               let decoded = try? JSONDecoder().decode([LiveMediaDownloadJob].self, from: data) {
                current = decoded
            } else {
                current = []
            }
            let jobs = current.filter { $0.id != id }
            if let data = try? JSONEncoder().encode(jobs) {
                try? data.write(to: Self.jobsURL, options: .atomic)
            }
        }
    }
}
