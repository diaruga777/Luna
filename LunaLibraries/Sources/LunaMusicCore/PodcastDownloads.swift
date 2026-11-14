import Foundation
import AVFoundation
import Combine
import UIKit
import Network
import LunaPodcastCore
import LunaMusicFiles
import LunaCompanionShareCore
import LunaMusicSharing

public struct PodcastDownload: Codable, Equatable {
    public var episodeID: String
    public var sourceURL: URL
    public var filename: String?
    public var bytes: Int64 = 0
    public var manual: Bool
    public var status: String = "waiting"
    public var error: String?
    public var createdAt = Date()
    public var preparationVersion: Int?
    public var preparedDuration: Double?
    public var preparedChapters: [PodcastChapter]?
}
@MainActor public final class PodcastDownloads: NSObject, ObservableObject {
    public static let shared = PodcastDownloads()
    private static let youtubePreparationVersion = 2
    public static let sessionIdentifier = (Bundle.main.bundleIdentifier ?? "LunaMusic") + ".podcast-downloads"
    @Published public private(set) var downloads: [String: PodcastDownload] = [:]
    @Published public private(set) var progress: [String: Double] = [:]
    @Published public private(set) var errorMessage: String?
    @Published public private(set) var youtubePhase: [String: YouTubePhase] = [:]
    public enum YouTubePhase { case resolving, transferring, fetchingOnMac }
    @Published private var onCellular = false
    private let network = NWPathMonitor()
    public func waitsForWiFi(_ id: String) -> Bool {
        youtubePhase[id] == .transferring && onCellular && !library.state.settings.cellularDownloads
    }
    public var backgroundCompletion: (() -> Void)?
    public var hlsBackgroundCompletion: (() -> Void)?
    public static let hlsSessionIdentifier = sessionIdentifier + ".hls"
    private var tasks: [String: URLSessionTask] = [:]
    private var externalTasks: [String: Task<Void, Never>] = [:]
    private var externalVersions: [String: UUID] = [:]
    var youtubeController: YouTubePodcastController?
    var youtubeDownload: ((PodcastEpisode, Int64, @escaping @Sendable (Double) -> Void) async throws -> YouTubeDownloadedAudio)?
    private var youtubeDirectResults: [String: CheckedContinuation<URL, Error>] = [:]
    private var youtubeDirectBudgets: [String: Int64] = [:]
    private var youtubeBackgroundTasks: [UUID: UIBackgroundTaskIdentifier] = [:]
    private var transferBudgets: [String: Int64] = [:]
    private var preparationTasks: [String: Task<PodcastAudioPreparation.Result, Error>] = [:]
    private var preparingBackgroundEvents = false
    private var isPreparingExisting = false
    private var restoring: Task<Void, Never>?
    private var reconciles = false
    private var isStopped = false
    private let directory: URL
    private let library: PodcastLibraryController
    private let activeEpisodeID: () -> String?
    private let sessionConfiguration: URLSessionConfiguration
    private let prepareAudio: @Sendable (URL, String, String) async throws -> PodcastAudioPreparation.Result
    private var libraryObserver: NSObjectProtocol?
    private var manifestURL: URL { directory.appendingPathComponent("downloads.json") }
    private lazy var session: URLSession = {
        let config = sessionConfiguration
        config.sessionSendsLaunchEvents = true; config.isDiscretionary = false
        config.waitsForConnectivity = true; config.httpMaximumConnectionsPerHost = 3
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()
    private lazy var hlsSession: AVAssetDownloadURLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: Self.hlsSessionIdentifier)
        config.sessionSendsLaunchEvents = true
        return AVAssetDownloadURLSession(configuration: config, assetDownloadDelegate: self, delegateQueue: .main)
    }()
    private override convenience init() {
        self.init(directory: PodcastLibraryController.directory.appendingPathComponent("Downloads", isDirectory: true),
                  library: .shared, sessionConfiguration: .background(withIdentifier: Self.sessionIdentifier),
                  activeEpisodeID: { PodcastPlaybackController.shared.player.currentItem == nil ? nil : PodcastPlaybackController.shared.currentEpisode?.id })
    }
    init(directory: URL, library: PodcastLibraryController, sessionConfiguration: URLSessionConfiguration, activeEpisodeID: @escaping () -> String? = { nil },
         prepareAudio: @escaping @Sendable (URL, String, String) async throws -> PodcastAudioPreparation.Result = { try await PodcastAudioPreparation.prepare($0, mediaType: $1, suffix: $2) }) {
        self.directory = directory; self.library = library; self.sessionConfiguration = sessionConfiguration
        self.activeEpisodeID = activeEpisodeID; self.prepareAudio = prepareAudio
        super.init()
        network.pathUpdateHandler = { [weak self] path in
            let cellular = path.usesInterfaceType(.cellular)
            Task { @MainActor [weak self] in
                if let self, onCellular != cellular { onCellular = cellular }
            }
        }
        network.start(queue: DispatchQueue(label: "LunaMusic.downloads.network"))
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var url = directory; var values = URLResourceValues(); values.isExcludedFromBackup = true; try url.setResourceValues(values)
            if FileManager.default.fileExists(atPath: manifestURL.path) { downloads = try JSONDecoder().decode([String: PodcastDownload].self, from: Data(contentsOf: manifestURL)) }
        } catch { errorMessage = error.localizedDescription }
        libraryObserver = NotificationCenter.default.addObserver(forName: .lunaPodcastsChanged, object: library.store, queue: .main) { [weak self] notification in
            guard notification.userInfo?["positionOnly"] as? Bool != true else { return }
            Task { @MainActor in await self?.reconcile() }
        }
    }
    deinit {
        network.cancel()
        if let libraryObserver { NotificationCenter.default.removeObserver(libraryObserver) }
    }
    public func start() async {
        guard !isStopped else { return }
        if let restoring { await restoring.value; return }
        restoring = Task { [weak self] in
            guard let self else { return }
            let ordinary = await session.allTasks
            let hls = sessionConfiguration.identifier == nil ? [] : await hlsSession.allTasks
            // A preference change may leave a cancelled request and its
            // replacement in the session when the process is terminated.
            for task in (ordinary + hls).sorted(by: { $0.taskIdentifier > $1.taskIdentifier }) {
                guard let id = task.taskDescription, downloads[id]?.status == "downloading",
                      task.state != .canceling, tasks[id] == nil else { task.cancel(); continue }
                tasks[id] = task
                if library.state.episodes[id]?.youtubeVideoID != nil, let request = task.originalRequest {
                    let bounded = YouTubeAudioTransfer.bounded(request)
                    youtubePhase[id] = .transferring
                    if bounded != request, task.state != .completed {
                        task.cancel()
                        beginYouTubeRange(id, request: bounded)
                    }
                }
            }
            for id in Array(downloads.keys) {
                if downloads[id]?.status == "downloaded", localURL(id) == nil {
                    discardFile(id); downloads[id]?.status = "waiting"; downloads[id]?.error = nil
                }
                if downloads[id]?.status == "downloading", tasks[id] == nil {
                    clearYouTubeTransfer(id)
                    downloads[id]?.status = "waiting"; downloads[id]?.error = nil
                }
            }
            persist()
        }
        await restoring?.value
    }
    public func localURL(_ id: String) -> URL? {
        guard let record = downloads[id], let name = record.filename, record.status == "downloaded" else { return nil }
        if name.hasPrefix("hls:") {
            let url = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(String(name.dropFirst(4)))
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
        let url = directory.appendingPathComponent(name)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path), (attributes[.size] as? NSNumber)?.int64Value == record.bytes, record.bytes > 0 else { return nil }
        return url
    }
    /// The manifest is already loaded. Reading timing never opens an audio asset.
    public func cachedDuration(_ id: String) -> Double? {
        guard downloads[id]?.status == "downloaded", let value = downloads[id]?.preparedDuration, value.isFinite, value > 0 else { return nil }
        return value
    }
    func youtubePlaybackDuration(_ id: String, url: URL) async throws -> Double {
        if downloads[id]?.preparationVersion == Self.youtubePreparationVersion, let duration = cachedDuration(id) {
            return duration
        }
        let original = downloads[id]
        let duration = try await YouTubePodcastController.validateAudio(url)
        try Task.checkCancellation()
        if downloads[id] == original, localURL(id) == url {
            downloads[id]?.preparationVersion = Self.youtubePreparationVersion
            cacheDuration(duration, for: id)
        }
        return duration
    }
    func cachedChapters(_ id: String) -> [PodcastChapter] { downloads[id]?.preparedChapters ?? [] }
    func cacheDuration(_ duration: Double, for id: String) {
        guard duration.isFinite, duration > 0, downloads[id]?.status == "downloaded" else { return }
        downloads[id]?.preparedDuration = duration; persist()
    }
    /// Upgrade legacy files only in background/maintenance, never on launch or
    /// Play. An asset already open in the player is left untouched.
    public func prepareExistingDownloads() async {
        guard !isStopped, !isPreparingExisting else { return }
        isPreparingExisting = true
        defer { isPreparingExisting = false }
        let priority = [library.state.currentEpisodeID].compactMap { $0 } + library.state.queue + downloads.keys.sorted()
        var seen = Set<String>()
        var preparedCount = 0
        for id in priority {
            guard !isStopped, !Task.isCancelled, preparedCount < 5 else { return }
            guard seen.insert(id).inserted, activeEpisodeID() != id,
                  let record = downloads[id], record.preparationVersion == nil,
                  let filename = record.filename, !filename.hasPrefix("hls:"), let original = localURL(id), preparationTasks[id] == nil else { continue }
            preparedCount += 1
            let job = Task.detached(priority: .utility) { [prepareAudio] in
                try await prepareAudio(original, "", original.pathExtension.lowercased())
            }
            preparationTasks[id] = job
            let background = UIApplication.shared.beginBackgroundTask(withName: "Prepare Downloaded Podcast") { job.cancel() }
            defer {
                preparationTasks[id] = nil
                if background != .invalid { UIApplication.shared.endBackgroundTask(background) }
                finishPreparationEvents()
            }
            guard let prepared = try? await job.value else { continue }
            defer { if prepared.url != original { try? FileManager.default.removeItem(at: prepared.url) } }
            guard !isStopped, !Task.isCancelled, downloads[id] == record, activeEpisodeID() != id else { continue }
            var updated = record
            updated.preparationVersion = 1; updated.preparedDuration = prepared.duration; updated.preparedChapters = prepared.chapters
            var replacement: URL?
            if prepared.url != original,
               let size = (try? FileManager.default.attributesOfItem(atPath: prepared.url.path)[.size] as? NSNumber)?.int64Value,
               size > 0, totalBytes - record.bytes <= library.state.settings.maximumDownloadBytes - size {
                let target = directory.appendingPathComponent(original.deletingPathExtension().lastPathComponent + ".indexed.mov")
                do {
                    try FileManager.default.moveItem(at: prepared.url, to: target)
                    updated.filename = target.lastPathComponent; updated.bytes = size; replacement = target
                } catch { errorMessage = error.localizedDescription; continue }
            }
            downloads[id] = updated
            if persist() {
                if replacement != nil { try? FileManager.default.removeItem(at: original) }
            } else {
                downloads[id] = record
                if let replacement { try? FileManager.default.removeItem(at: replacement) }
            }
        }
    }
    public var totalBytes: Int64 { downloads.values.filter { $0.status == "downloaded" }.reduce(0) { $0 + $1.bytes } }
    public func download(_ episode: PodcastEpisode, manual: Bool = true) async {
        guard !episode.mediaURL.isFileURL else { return }
        await start()
        if manual {
            do { try library.edit { state in
                var value = state.progress[episode.id] ?? PodcastEpisodeState(); value.suppressAutomaticDownload = false; value.updatedAt = Date(); state.progress[episode.id] = value
            } } catch { errorMessage = error.localizedDescription; return }
        }
        if localURL(episode.id) != nil { if manual { downloads[episode.id]?.manual = true; persist() }; return }
        if tasks[episode.id] != nil || externalTasks[episode.id] != nil { if manual { downloads[episode.id]?.manual = true; persist() }; return }
        downloads[episode.id] = PodcastDownload(episodeID: episode.id, sourceURL: episode.mediaURL, manual: manual)
        guard persist() else { return }
        await reconcile()
    }
    /// Adopt an extension-owned background transfer into the ordinary manifest.
    /// Library mutation stays in this process; inbox replay is keyed by video ID.
    func importSharedYouTube(_ capture: CompanionShareCapture, inbox: CompanionShareInbox) async throws {
        guard capture.kind == .podcast, let metadata = capture.youtube else { throw MusicYouTubeShare.unsupported() }
        let result = try MusicYouTubeShare.result(for: capture, inbox: inbox)
        if case .pending = result { return }
        await start()
        let id = PodcastIdentity.episode(showID: YouTubePodcastController.showID, guid: metadata.videoID)
        var audio: (URL, Double, Int64)?
        var failure: (String, Bool)?
        if localURL(id) == nil {
            switch result {
            case .downloaded(let url):
                do {
                    let duration = try await YouTubePodcastController.validateAudio(url)
                    let bytes = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
                    guard bytes > 0, bytes <= metadata.maximumBytes, totalBytes <= library.state.settings.maximumDownloadBytes - bytes else { throw PodcastError("The audio exceeds your download limit.") }
                    audio = (url, duration, bytes)
                } catch { failure = (error.localizedDescription, YouTubeAudioFailurePolicy.shouldUseMac(error)) }
            case .failed(let message, let mediaRejected): failure = (message, mediaRejected)
            case .pending: return
            }
        }
        let controller = youtubeController ?? YouTubePodcastController(library: library)
        let episode = try controller.enqueueResolved(video: metadata.videoID, title: capture.title, author: metadata.author,
                                                    duration: metadata.duration, next: capture.playNext)
        if localURL(id) != nil { downloads[id]?.manual = true; guard persist() else { throw PodcastError(errorMessage ?? "The download couldn’t be saved.") }; return }
        // An explicit in-app request may already be downloading this same video.
        if tasks[id] != nil || externalTasks[id] != nil { return }
        var record = PodcastDownload(episodeID: id, sourceURL: episode.mediaURL, manual: true)
        if let (url, duration, bytes) = audio {
            let name = PodcastIdentity.hash(id + episode.mediaURL.absoluteString) + ".m4a"
            let target = directory.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
            // Keep the inbox original until the manifest commits, allowing replay.
            try FileManager.default.copyItem(at: url, to: target)
            record.filename = name; record.bytes = bytes; record.status = "downloaded"
            record.preparationVersion = Self.youtubePreparationVersion; record.preparedDuration = duration
        } else {
            record.status = "failed"; record.error = failure?.0 ?? "The download was interrupted. Try again."
        }
        downloads[id] = record
        guard persist() else { throw PodcastError(errorMessage ?? "The download couldn’t be saved.") }
        if failure?.1 == true { beginYouTube(episode, manual: true, macOnly: true) }
        NotificationCenter.default.post(name: .lunaPodcastsChanged, object: nil)
    }
    private func begin(_ episode: PodcastEpisode, manual: Bool) {
        if episode.youtubeVideoID != nil { beginYouTube(episode, manual: manual); return }
        let knownBytes = downloads[episode.id]?.bytes ?? 0
        if episode.mediaURL.pathExtension.lowercased() == "m3u8" || episode.mediaType.lowercased().contains("mpegurl") {
            let cellular = library.state.settings.cellularDownloads
            let asset = AVURLAsset(url: episode.mediaURL, options: [AVURLAssetAllowsCellularAccessKey: cellular])
            guard let task = hlsSession.makeAssetDownloadTask(asset: asset, assetTitle: episode.title, assetArtworkData: nil, options: nil) else {
                errorMessage = "This stream cannot be downloaded for offline playback."; return
            }
            task.taskDescription = episode.id
            downloads[episode.id] = PodcastDownload(episodeID: episode.id, sourceURL: episode.mediaURL, bytes: knownBytes, manual: manual, status: "downloading")
            tasks[episode.id] = task
            guard persist() else { tasks[episode.id] = nil; task.cancel(); return }
            task.resume(); return
        }
        var request = URLRequest(url: episode.mediaURL)
        request.allowsCellularAccess = library.state.settings.cellularDownloads
        request.allowsExpensiveNetworkAccess = request.allowsCellularAccess
        let task = session.downloadTask(with: request); task.taskDescription = episode.id
        downloads[episode.id] = PodcastDownload(episodeID: episode.id, sourceURL: episode.mediaURL, bytes: knownBytes, manual: manual, status: "downloading")
        tasks[episode.id] = task
        guard persist() else { tasks[episode.id] = nil; task.cancel(); return }
        task.resume()
    }
    public func remove(_ id: String, suppress: Bool = true) {
        preparationTasks.removeValue(forKey: id)?.cancel()
        cancelYouTubeDirect(id)
        clearYouTubeTransfer(id)
        externalVersions[id] = nil; externalTasks.removeValue(forKey: id)?.cancel()
        tasks.removeValue(forKey: id)?.cancel(); progress[id] = nil
        if let name = downloads[id]?.filename {
            let url = name.hasPrefix("hls:") ? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(String(name.dropFirst(4))) : directory.appendingPathComponent(name)
            do { if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) } }
            catch { errorMessage = error.localizedDescription; return }
        }
        downloads[id] = nil
        if suppress {
            do { try library.edit { state in
                var value = state.progress[id] ?? PodcastEpisodeState(); value.suppressAutomaticDownload = true; value.updatedAt = Date(); state.progress[id] = value
            } } catch { errorMessage = error.localizedDescription }
        }
        persist()
    }
    public func reconcile() async {
        await start()
        library.reloadState()
        guard !isStopped, !reconciles else { return }; reconciles = true
        defer { reconciles = false }
        let state = library.state
        let automatic = PodcastPolicies.automaticDownloads(state)
        for (id, record) in downloads where activeEpisodeID() != id && !state.queue.contains(id) {
            let expired = PodcastPolicies.isExpiredAutomaticDownload(episodeID: id, manual: record.manual, createdAt: record.createdAt, state: state)
            if expired || PodcastPolicies.shouldRemoveDownload(episodeID: id, manual: record.manual, wanted: automatic.union(state.queue).union(state.currentEpisodeID.map { [$0] } ?? []), state: state) {
                // Expiry is durable: an unchanged subscription must not fetch
                // the same unstarted episode again on the next reconciliation.
                remove(id, suppress: expired)
            }
        }
        let plan = downloadPlan()
        transferBudgets = plan.reservedBytes
        let retained = Set(plan.episodeIDs)
        for id in Array(downloads.keys) where !retained.contains(id) && protectedDownloadID != id {
            // Preserve the request/known size so it can be refilled after space frees.
            discardFile(id)
        }
        // Reordering must preempt a lower-priority transfer, even if both fit.
        let nextID = plan.episodeIDs.first { id in
            guard localURL(id) == nil else { return false }
            if let record = downloads[id], record.status == "failed", Date().timeIntervalSince(record.createdAt) < 900 { return false }
            return true
        }
        for id in Array(Set(tasks.keys).union(externalTasks.keys)) where id != nextID { discardFile(id) }
        // One transfer at a time gives queue order a real download priority.
        guard tasks.isEmpty, externalTasks.isEmpty else { return }
        guard !Task.isCancelled, let id = nextID, let episode = state.episodes[id] else { return }
        begin(episode, manual: downloads[id]?.manual ?? false)
    }
    /// Used by isolated callers/tests; the production singleton lives for the app lifetime.
    func stop() { isStopped = true; restoring?.cancel(); Array(youtubeDirectResults.keys).forEach { cancelYouTubeDirect($0) }; externalTasks.values.forEach { $0.cancel() }; preparationTasks.values.forEach { $0.cancel() }; session.invalidateAndCancel() }
    private func downloadPlan() -> PodcastDownloadPlan {
        PodcastDownloadPlan(state: library.state, sizes: downloads.mapValues(\.bytes),
            manualIDs: downloads.values.filter(\.manual).sorted { $0.createdAt < $1.createdAt }.map(\.episodeID), protectedID: protectedDownloadID)
    }
    private var protectedDownloadID: String? {
        guard let id = activeEpisodeID(), localURL(id) != nil else { return nil }
        return id
    }
    private func discardFile(_ id: String) {
        guard tasks[id] != nil || externalTasks[id] != nil || downloads[id]?.filename != nil || downloads[id]?.status == "downloading" else { return }
        preparationTasks.removeValue(forKey: id)?.cancel()
        cancelYouTubeDirect(id)
        clearYouTubeTransfer(id)
        externalVersions[id] = nil; externalTasks.removeValue(forKey: id)?.cancel()
        tasks.removeValue(forKey: id)?.cancel(); progress[id] = nil
        guard var record = downloads[id] else { return }
        if let name = record.filename {
            let url = name.hasPrefix("hls:") ? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(String(name.dropFirst(4))) : directory.appendingPathComponent(name)
            do { if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) } }
            catch { errorMessage = error.localizedDescription; return }
        }
        record.filename = nil; record.preparationVersion = nil; record.preparedDuration = nil; record.preparedChapters = nil
        // Failed transfers keep their retry delay until the next poll.
        if record.status != "failed" { record.status = "waiting" }
        downloads[id] = record; persist()
    }
    private func accepts(_ id: String, bytes: Int64) -> Bool {
        downloads[id]?.bytes = bytes
        library.reloadState()
        let plan = downloadPlan()
        return bytes > 0 && plan.episodeIDs.contains(id) && totalBytes <= library.state.settings.maximumDownloadBytes - bytes
    }
    private func completed(_ id: String) async {
        clearYouTubeTransfer(id)
        tasks[id] = nil; externalTasks[id] = nil; externalVersions[id] = nil; progress[id] = nil; persist()
        finishPreparationEvents()
        NotificationCenter.default.post(name: .lunaPodcastsChanged, object: nil)
        await reconcile()
    }
    private func failed(_ id: String, task: URLSessionTask, message: String) async {
        guard tasks[id] === task else { return }
        downloads[id]?.status = "failed"; downloads[id]?.error = message
        await completed(id)
    }
    private func beginYouTube(_ episode: PodcastEpisode, manual: Bool, macOnly: Bool = false) {
        let id = episode.id, version = UUID()
        let budget = transferBudgets[id] ?? max(0, library.state.settings.maximumDownloadBytes - totalBytes)
        guard budget > 0 else { return }
        downloads[id] = PodcastDownload(episodeID: id, sourceURL: episode.mediaURL, manual: manual, status: "downloading")
        guard persist() else { return }
        externalVersions[id] = version
        youtubePhase[id] = macOnly ? .fetchingOnMac : .resolving
        let job = Task { [self] in
            do {
                let report: @Sendable (Double) -> Void = { [weak self] value in
                    Task { @MainActor in
                        guard let self, self.externalVersions[id] == version else { return }
                        self.progress[id] = value
                    }
                }
                let audio: YouTubeDownloadedAudio
                if let youtubeDownload { audio = try await youtubeDownload(episode, budget, report) }
                else {
                    audio = try await (youtubeController ?? .shared).download(episode, maximumBytes: budget, progress: report,
                        onMacDownload: { [weak self] in
                            guard let self, self.externalVersions[id] == version else { return }
                            self.youtubePhase[id] = .fetchingOnMac
                            self.progress[id] = nil
                        },
                        directDownload: { [weak self] request, maximumBytes, _ in
                            guard let self else { throw CancellationError() }
                            if macOnly { throw YouTubeMediaRejection() }
                            return try await self.downloadYouTubeDirect(id, request: request, budget: maximumBytes)
                        })
                }
                defer { try? FileManager.default.removeItem(at: audio.url) }
                try Task.checkCancellation()
                guard externalVersions[id] == version, var record = downloads[id] else { return }
                let bytes = (try FileManager.default.attributesOfItem(atPath: audio.url.path)[.size] as? NSNumber)?.int64Value ?? 0
                guard bytes > 0, accepts(id, bytes: bytes) else { throw PodcastError("The audio exceeds your download limit.") }
                let name = PodcastIdentity.hash(id + record.sourceURL.absoluteString) + ".m4a"
                let target = directory.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
                try FileManager.default.moveItem(at: audio.url, to: target)
                record.filename = name; record.bytes = bytes; record.status = "downloaded"; record.error = nil
                record.preparationVersion = Self.youtubePreparationVersion; record.preparedDuration = audio.duration
                downloads[id] = record
                await completed(id)
            } catch {
                guard externalVersions[id] == version else { return }
                downloads[id]?.status = "failed"; downloads[id]?.createdAt = Date()
                downloads[id]?.error = error is CancellationError ? "The download was interrupted. Try again." : error.localizedDescription
                await completed(id)
            }
        }
        externalTasks[id] = job
        if macOnly { beginYouTubeBackgroundTask(id, version: version) }
        Task {
            await job.value
            if let background = youtubeBackgroundTasks.removeValue(forKey: version), background != .invalid {
                UIApplication.shared.endBackgroundTask(background)
            }
        }
    }
    /// The direct leg uses the same background session as RSS downloads. A
    /// terminated app restores the task normally; successful audio can install
    /// without a continuation, and media rejection starts a fresh Mac job.
    private func downloadYouTubeDirect(_ id: String, request: URLRequest, budget: Int64) async throws -> URL {
        try Task.checkCancellation()
        let version = externalVersions[id]
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                youtubeDirectResults[id] = continuation
                youtubeDirectBudgets[id] = budget
                beginYouTubeRange(id, request: request)
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, self.externalVersions[id] == version else { return }
                self.cancelYouTubeDirect(id)
            }
        }
    }
    private func beginYouTubeRange(_ id: String, request: URLRequest) {
        let task = session.downloadTask(with: request)
        task.taskDescription = id
        tasks[id] = task
        if youtubePhase[id] != .transferring { youtubePhase[id] = .transferring }
        task.resume()
        finishPreparationEvents()
    }
    private func youtubePartial(_ id: String) -> URL {
        directory.appendingPathComponent(PodcastIdentity.hash(id) + ".youtube-part.m4a")
    }
    private func clearYouTubeTransfer(_ id: String) {
        let wasYouTube = youtubePhase.removeValue(forKey: id) != nil || library.state.episodes[id]?.youtubeVideoID != nil
        if wasYouTube {
            try? FileManager.default.removeItem(at: youtubePartial(id))
        }
    }
    public func setCellularDownloads(_ allowed: Bool) async throws {
        guard allowed != library.state.settings.cellularDownloads else { return }
        try library.edit { $0.settings.cellularDownloads = allowed }
        // Existing tasks keep the policy they were created with. Reissue them
        // so enabling cellular also unblocks a transfer already waiting for Wi-Fi.
        await start()
        for id in Array(tasks.keys) {
            guard let task = tasks[id], task.state != .completed,
                  var request = task.originalRequest, request.allowsCellularAccess != allowed else { continue }
            if library.state.episodes[id]?.youtubeVideoID != nil {
                request.allowsCellularAccess = allowed
                beginYouTubeRange(id, request: request)
                task.cancel()
            } else {
                discardFile(id)
            }
        }
        await reconcile()
    }
    private func cancelYouTubeDirect(_ id: String) {
        guard let continuation = youtubeDirectResults.removeValue(forKey: id) else { return }
        youtubeDirectBudgets[id] = nil
        tasks.removeValue(forKey: id)?.cancel(); continuation.resume(throwing: CancellationError())
    }
    private func finishYouTubeDirect(_ id: String, task: URLSessionTask, result: Result<URL, Error>) -> Bool {
        guard tasks[id] === task, let continuation = youtubeDirectResults.removeValue(forKey: id) else { return false }
        tasks[id] = nil; youtubeDirectBudgets[id] = nil
        if let version = externalVersions[id] { beginYouTubeBackgroundTask(id, version: version) }
        continuation.resume(with: result)
        return true
    }
    private func beginYouTubeBackgroundTask(_ id: String, version: UUID) {
        guard youtubeBackgroundTasks[version] == nil else { return }
        youtubeBackgroundTasks[version] = UIApplication.shared.beginBackgroundTask(withName: "Transfer YouTube Audio") { [weak self] in
            Task { @MainActor in
                guard let self, self.externalVersions[id] == version else { return }
                self.externalTasks[id]?.cancel()
            }
        }
    }
    private func fallbackToMac(_ id: String, task: URLSessionTask) async {
        guard tasks[id] === task, let episode = library.state.episodes[id], episode.youtubeVideoID != nil else { return }
        tasks[id] = nil; task.cancel()
        clearYouTubeTransfer(id)
        beginYouTube(episode, manual: downloads[id]?.manual ?? false, macOnly: true)
    }
    private func finishPreparationEvents() {
        guard preparingBackgroundEvents, preparationTasks.isEmpty,
              externalTasks.keys.allSatisfy({ tasks[$0]?.state == .running }) else { return }
        preparingBackgroundEvents = false
        let completion = backgroundCompletion; backgroundCompletion = nil; completion?()
    }
    @discardableResult private func persist() -> Bool {
        do { try JSONEncoder().encode(downloads).write(to: manifestURL, options: [.atomic]); return true }
        catch { errorMessage = error.localizedDescription; return false }
    }
}
extension PodcastDownloads: URLSessionDownloadDelegate {
    nonisolated public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let id = downloadTask.taskDescription else { return }
        let http = downloadTask.response as? HTTPURLResponse
        let type = http?.mimeType ?? "application/octet-stream"
        guard let status = http?.statusCode, (200..<300).contains(status), !type.contains("html"), !type.contains("json"), !type.contains("xml") else {
            Task { @MainActor in
                if self.finishYouTubeDirect(id, task: downloadTask, result: .failure(YouTubeMediaRejection())) { return }
                if self.library.state.episodes[id]?.youtubeVideoID != nil { await self.fallbackToMac(id, task: downloadTask); return }
                await self.failed(id, task: downloadTask, message: "The server did not return a media file.")
            }; return
        }
        // URLSession deletes `location` after this callback returns.
        let mimeSuffix = ["audio/mpeg": "mp3", "audio/mp3": "mp3", "audio/mp4": "m4a", "audio/x-m4a": "m4a",
                          "video/mp4": "mp4", "audio/aac": "aac", "audio/wav": "wav", "audio/x-wav": "wav", "audio/ogg": "ogg"][type]
        let sourceSuffix = downloadTask.originalRequest?.url?.pathExtension.lowercased() ?? ""
        let suffix = mimeSuffix ?? (["mp3", "mp4", "m4a", "m4v", "aac", "ogg", "wav"].contains(sourceSuffix) ? sourceSuffix : "mp3")
        let staged = FileManager.default.temporaryDirectory.appendingPathComponent("podcast-\(UUID().uuidString)").appendingPathExtension(suffix)
        do { try FileManager.default.moveItem(at: location, to: staged) }
        catch { Task { @MainActor in
            if self.finishYouTubeDirect(id, task: downloadTask, result: .failure(error)) { return }
            await self.failed(id, task: downloadTask, message: error.localizedDescription)
        }; return }
        Task { @MainActor in
            var audio = staged
            var handedOff = false
            defer {
                if !handedOff || audio != staged { try? FileManager.default.removeItem(at: staged) }
                if !handedOff, audio != staged { try? FileManager.default.removeItem(at: audio) }
            }
            guard self.tasks[id] === downloadTask, var record = self.downloads[id] else { return }
            do {
                let isYouTube = self.library.state.episodes[id]?.youtubeVideoID != nil
                var youtubeDuration: Double?
                if isYouTube {
                    do {
                        let budget = self.youtubeDirectBudgets[id] ?? max(0, self.library.state.settings.maximumDownloadBytes - self.totalBytes)
                        switch try YouTubeAudioTransfer.receive(staged, response: http, request: downloadTask.originalRequest,
                                                               partial: self.youtubePartial(id), maximumBytes: budget) {
                        case .next(var request, let fraction):
                            request.allowsCellularAccess = self.library.state.settings.cellularDownloads
                            self.progress[id] = fraction
                            self.beginYouTubeRange(id, request: request)
                            return
                        case .complete(let file): audio = file
                        }
                    } catch {
                        if self.finishYouTubeDirect(id, task: downloadTask, result: .failure(error)) { return }
                        if YouTubeAudioFailurePolicy.shouldUseMac(error) { await self.fallbackToMac(id, task: downloadTask); return }
                        throw error
                    }
                    if audio != staged {
                        // A new attempt can reuse the partial path while the old job validates.
                        let assembled = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
                        try FileManager.default.moveItem(at: audio, to: assembled)
                        audio = assembled
                    }
                    handedOff = self.finishYouTubeDirect(id, task: downloadTask, result: .success(audio))
                    if handedOff { return }
                    do { youtubeDuration = try await YouTubePodcastController.validateAudio(audio) }
                    catch {
                        guard YouTubeAudioFailurePolicy.shouldUseMac(error) else { throw error }
                        await self.fallbackToMac(id, task: downloadTask)
                        return
                    }
                    guard !self.isStopped, self.tasks[id] === downloadTask else { return }
                }
                let bytes = (try FileManager.default.attributesOfItem(atPath: audio.path)[.size] as? NSNumber)?.int64Value ?? 0
                guard bytes > 0 else { throw PodcastError("The downloaded file is empty.") }
                guard self.accepts(id, bytes: bytes) else {
                    self.discardFile(id); await self.completed(id); return
                }
                let prepareAudio = self.prepareAudio
                let source = audio
                let verifiedDuration = youtubeDuration
                let preparation = Task.detached(priority: .utility) {
                    if let verifiedDuration {
                        return PodcastAudioPreparation.Result(url: source, duration: verifiedDuration, chapters: [])
                    }
                    return try await prepareAudio(source, type, suffix)
                }
                self.preparationTasks[id] = preparation
                let background = UIApplication.shared.beginBackgroundTask(withName: "Prepare Podcast Download") {
                    preparation.cancel()
                }
                defer {
                    self.preparationTasks[id] = nil
                    if background != .invalid { UIApplication.shared.endBackgroundTask(background) }
                    self.finishPreparationEvents()
                }
                let prepared: PodcastAudioPreparation.Result
                do { prepared = try await preparation.value }
                catch {
                    // Expiration/cancellation of optional indexing must not lose
                    // a completed transfer. Explicit Remove still wins below.
                    prepared = .init(url: audio, duration: nil, chapters: [])
                }
                defer { if prepared.url != audio { try? FileManager.default.removeItem(at: prepared.url) } }
                guard !self.isStopped, self.tasks[id] === downloadTask, let latest = self.downloads[id] else { return }
                record = latest
                var ready = prepared.url
                var installedBytes = (try FileManager.default.attributesOfItem(atPath: ready.path)[.size] as? NSNumber)?.int64Value ?? 0
                if ready != audio, !self.accepts(id, bytes: installedBytes) {
                    // Container overhead must not discard an otherwise fitting
                    // episode or exceed the user's storage cap.
                    ready = audio; installedBytes = bytes
                }
                guard self.accepts(id, bytes: installedBytes) else {
                    self.discardFile(id); await self.completed(id); return
                }
                let ext = isYouTube ? "m4a" : ready != audio ? "mov" : (["mp3", "mp4", "m4a", "m4v", "aac", "ogg", "wav"].contains(suffix) ? suffix : "mp3")
                let name = PodcastIdentity.hash(id + record.sourceURL.absoluteString) + "." + ext
                let target = self.directory.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
                try FileManager.default.moveItem(at: ready, to: target)
                record.filename = name; record.bytes = installedBytes; record.status = "downloaded"; record.error = nil
                record.preparationVersion = isYouTube ? Self.youtubePreparationVersion : prepared.duration == nil ? nil : 1
                record.preparedDuration = prepared.duration; record.preparedChapters = prepared.chapters
                self.downloads[id] = record; await self.completed(id)
            } catch {
                if self.finishYouTubeDirect(id, task: downloadTask, result: .failure(error)) { return }
                await self.failed(id, task: downloadTask, message: error.localizedDescription)
            }
        }
    }
    nonisolated public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let id = downloadTask.taskDescription else { return }
        Task { @MainActor in
            guard self.tasks[id] === downloadTask else { return }
            if self.library.state.episodes[id]?.youtubeVideoID != nil {
                let budget = self.youtubeDirectBudgets[id] ?? max(0, self.library.state.settings.maximumDownloadBytes - self.totalBytes)
                do {
                    if let fraction = try YouTubeAudioTransfer.progress(response: downloadTask.response, request: downloadTask.originalRequest,
                        written: totalBytesWritten, expected: totalBytesExpectedToWrite, maximumBytes: budget) {
                        self.progress[id] = fraction
                    }
                } catch {
                    downloadTask.cancel()
                    if self.finishYouTubeDirect(id, task: downloadTask, result: .failure(error)) { return }
                    if YouTubeAudioFailurePolicy.shouldUseMac(error) {
                        await self.fallbackToMac(id, task: downloadTask)
                    } else {
                        await self.failed(id, task: downloadTask, message: error.localizedDescription)
                    }
                }
                return
            }
            self.progress[id] = totalBytesExpectedToWrite > 0 ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) : 0
            let size = max(totalBytesWritten, totalBytesExpectedToWrite)
            if size > 0, self.downloads[id]?.bytes != size {
                self.downloads[id]?.bytes = size
                // The reservation stays valid as bytes arrive. Rebuild the
                // library-wide plan only if the server exceeds it, or reconcile
                // changes queue/settings; never sort all feeds per network chunk.
                if size > (self.transferBudgets[id] ?? 0) {
                    self.transferBudgets = self.downloadPlan().reservedBytes
                    if size > (self.transferBudgets[id] ?? 0) { self.discardFile(id); await self.completed(id) }
                }
            }
        }
    }
    nonisolated public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let id = task.taskDescription else { return }
        Task { @MainActor in
            // Successful completion is handled after atomic installation, not
            // here: delegate callbacks may otherwise race the staging Task.
            if let error {
                if self.finishYouTubeDirect(id, task: task, result: .failure(error)) { return }
                if self.library.state.episodes[id]?.youtubeVideoID != nil, YouTubeAudioFailurePolicy.shouldUseMac(error) {
                    await self.fallbackToMac(id, task: task); return
                }
                await self.failed(id, task: task, message: error.localizedDescription)
            }
        }
    }
    nonisolated public func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in
            if session.configuration.identifier == Self.hlsSessionIdentifier { let completion = self.hlsBackgroundCompletion; self.hlsBackgroundCompletion = nil; completion?() }
            else { self.preparingBackgroundEvents = true; self.finishPreparationEvents() }
        }
    }
}


extension PodcastDownloads: AVAssetDownloadDelegate {
    nonisolated public func urlSession(_ session: URLSession, assetDownloadTask: AVAssetDownloadTask, didFinishDownloadingTo location: URL) {
        guard let id = assetDownloadTask.taskDescription else { return }
        Task { @MainActor in
            guard var record = self.downloads[id], self.tasks[id] === assetDownloadTask else {
                try? FileManager.default.removeItem(at: location); return
            }
            let prefix = NSHomeDirectory() + "/"
            guard location.path.hasPrefix(prefix) else { await self.failed(id, task: assetDownloadTask, message: "The downloaded stream has an invalid location."); return }
            record.filename = "hls:" + location.path.dropFirst(prefix.count)
            let enumerator = FileManager.default.enumerator(at: location, includingPropertiesForKeys: [.fileSizeKey])
            var bytes: Int64 = 0
            while let file = enumerator?.nextObject() as? URL { bytes += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
            guard self.accepts(id, bytes: bytes) else {
                try? FileManager.default.removeItem(at: location)
                self.discardFile(id); await self.completed(id); return
            }
            record.bytes = bytes; record.status = "downloaded"; record.error = nil
            self.downloads[id] = record; await self.completed(id)
        }
    }
    nonisolated public func urlSession(_ session: URLSession, assetDownloadTask: AVAssetDownloadTask, didLoad timeRange: CMTimeRange, totalTimeRangesLoaded loadedTimeRanges: [NSValue], timeRangeExpectedToLoad: CMTimeRange) {
        guard let id = assetDownloadTask.taskDescription else { return }
        let total = timeRangeExpectedToLoad.duration.seconds
        let loaded = loadedTimeRanges.reduce(0.0) { $0 + $1.timeRangeValue.duration.seconds }
        Task { @MainActor in guard self.tasks[id] === assetDownloadTask else { return }; self.progress[id] = total > 0 && total.isFinite ? min(1, loaded / total) : 0 }
    }
}
