import Foundation
import AVFoundation
import Combine
import LunaPodcastCore

public struct PodcastDownload: Codable, Equatable {
    public var episodeID: String
    public var sourceURL: URL
    public var filename: String?
    public var bytes: Int64 = 0
    public var manual: Bool
    public var status: String = "waiting"
    public var error: String?
    public var createdAt = Date()
}
@MainActor public final class PodcastDownloads: NSObject, ObservableObject {
    public static let shared = PodcastDownloads()
    public static let sessionIdentifier = (Bundle.main.bundleIdentifier ?? "LunaMusic") + ".podcast-downloads"
    @Published public private(set) var downloads: [String: PodcastDownload] = [:]
    @Published public private(set) var progress: [String: Double] = [:]
    @Published public private(set) var errorMessage: String?
    public var backgroundCompletion: (() -> Void)?
    public var hlsBackgroundCompletion: (() -> Void)?
    public static let hlsSessionIdentifier = sessionIdentifier + ".hls"
    private var tasks: [String: URLSessionTask] = [:]
    private var restoring: Task<Void, Never>?
    private var reconciles = false
    private let directory: URL
    private let library: PodcastLibraryController
    private let activeEpisodeID: () -> String?
    private let sessionConfiguration: URLSessionConfiguration
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
    init(directory: URL, library: PodcastLibraryController, sessionConfiguration: URLSessionConfiguration, activeEpisodeID: @escaping () -> String? = { nil }) {
        self.directory = directory; self.library = library; self.sessionConfiguration = sessionConfiguration
        self.activeEpisodeID = activeEpisodeID
        super.init()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var url = directory; var values = URLResourceValues(); values.isExcludedFromBackup = true; try url.setResourceValues(values)
            if FileManager.default.fileExists(atPath: manifestURL.path) { downloads = try JSONDecoder().decode([String: PodcastDownload].self, from: Data(contentsOf: manifestURL)) }
        } catch { errorMessage = error.localizedDescription }
        libraryObserver = NotificationCenter.default.addObserver(forName: .lunaPodcastsChanged, object: library.store, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.reconcile() }
        }
    }
    deinit { if let libraryObserver { NotificationCenter.default.removeObserver(libraryObserver) } }
    public func start() async {
        if let restoring { await restoring.value; return }
        restoring = Task { [weak self] in
            guard let self else { return }
            let ordinary = await session.allTasks
            let hls = sessionConfiguration.identifier == nil ? [] : await hlsSession.allTasks
            for task in ordinary + hls {
                guard let id = task.taskDescription, downloads[id] != nil else { task.cancel(); continue }
                tasks[id] = task
            }
            for id in Array(downloads.keys) {
                if downloads[id]?.status == "downloaded", localURL(id) == nil {
                    discardFile(id); downloads[id]?.status = "waiting"; downloads[id]?.error = nil
                }
                if downloads[id]?.status == "downloading", tasks[id] == nil {
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
    public var totalBytes: Int64 { downloads.values.filter { $0.status == "downloaded" }.reduce(0) { $0 + $1.bytes } }
    public func download(_ episode: PodcastEpisode, manual: Bool = true) async {
        await start()
        if manual {
            do { try library.edit { state in
                var value = state.progress[episode.id] ?? PodcastEpisodeState(); value.suppressAutomaticDownload = false; value.updatedAt = Date(); state.progress[episode.id] = value
            } } catch { errorMessage = error.localizedDescription; return }
        }
        if localURL(episode.id) != nil { if manual { downloads[episode.id]?.manual = true; persist() }; return }
        if tasks[episode.id] != nil { if manual { downloads[episode.id]?.manual = true; persist() }; return }
        downloads[episode.id] = PodcastDownload(episodeID: episode.id, sourceURL: episode.mediaURL, manual: manual)
        guard persist() else { return }
        await reconcile()
    }
    private func begin(_ episode: PodcastEpisode, manual: Bool) {
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
        guard !reconciles else { return }; reconciles = true
        defer { reconciles = false }
        let state = library.state
        let automatic = PodcastPolicies.automaticDownloads(state)
        for (id, record) in downloads where activeEpisodeID() != id && !state.queue.contains(id) {
            if PodcastPolicies.shouldRemoveDownload(episodeID: id, manual: record.manual, wanted: automatic.union(state.queue).union(state.currentEpisodeID.map { [$0] } ?? []), state: state) {
                remove(id, suppress: false)
            }
        }
        let plan = downloadPlan()
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
        for id in Array(tasks.keys) where id != nextID { discardFile(id) }
        // One transfer at a time gives queue order a real download priority.
        guard tasks.isEmpty else { return }
        guard !Task.isCancelled, let id = nextID, let episode = state.episodes[id] else { return }
        begin(episode, manual: downloads[id]?.manual ?? false)
    }
    /// Used by isolated callers/tests; the production singleton lives for the app lifetime.
    func stop() { session.invalidateAndCancel() }
    private func downloadPlan() -> PodcastDownloadPlan {
        PodcastDownloadPlan(state: library.state, sizes: downloads.mapValues(\.bytes),
            manualIDs: downloads.values.filter(\.manual).sorted { $0.createdAt < $1.createdAt }.map(\.episodeID), protectedID: protectedDownloadID)
    }
    private var protectedDownloadID: String? {
        guard let id = activeEpisodeID(), localURL(id) != nil else { return nil }
        return id
    }
    private func discardFile(_ id: String) {
        guard tasks[id] != nil || downloads[id]?.filename != nil || downloads[id]?.status == "downloading" else { return }
        tasks.removeValue(forKey: id)?.cancel(); progress[id] = nil
        guard var record = downloads[id] else { return }
        if let name = record.filename {
            let url = name.hasPrefix("hls:") ? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(String(name.dropFirst(4))) : directory.appendingPathComponent(name)
            do { if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) } }
            catch { errorMessage = error.localizedDescription; return }
        }
        record.filename = nil
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
        tasks[id] = nil; progress[id] = nil; persist()
        NotificationCenter.default.post(name: .lunaPodcastsChanged, object: nil)
        await reconcile()
    }
    private func failed(_ id: String, task: URLSessionTask, message: String) async {
        guard tasks[id] === task else { return }
        downloads[id]?.status = "failed"; downloads[id]?.error = message
        await completed(id)
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
            Task { @MainActor in await self.failed(id, task: downloadTask, message: "The server did not return a media file.") }; return
        }
        // URLSession deletes `location` after this callback returns.
        let staged = FileManager.default.temporaryDirectory.appendingPathComponent("podcast-\(UUID().uuidString)")
        do { try FileManager.default.moveItem(at: location, to: staged) }
        catch { Task { @MainActor in await self.failed(id, task: downloadTask, message: error.localizedDescription) }; return }
        Task { @MainActor in
            defer { try? FileManager.default.removeItem(at: staged) }
            guard self.tasks[id] === downloadTask, var record = self.downloads[id] else { return }
            do {
                let bytes = (try FileManager.default.attributesOfItem(atPath: staged.path)[.size] as? NSNumber)?.int64Value ?? 0
                guard bytes > 0 else { throw PodcastError("The downloaded file is empty.") }
                guard self.accepts(id, bytes: bytes) else {
                    self.discardFile(id); await self.completed(id); return
                }
                let suffix = record.sourceURL.pathExtension.lowercased()
                let name = PodcastIdentity.hash(id + record.sourceURL.absoluteString) + "." + (["mp3", "mp4", "m4a", "m4v", "aac", "ogg", "wav"].contains(suffix) ? suffix : "mp3")
                let target = self.directory.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
                try FileManager.default.moveItem(at: staged, to: target)
                record.filename = name; record.bytes = bytes; record.status = "downloaded"; record.error = nil
                self.downloads[id] = record; await self.completed(id)
            } catch { await self.failed(id, task: downloadTask, message: error.localizedDescription) }
        }
    }
    nonisolated public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let id = downloadTask.taskDescription else { return }
        Task { @MainActor in
            guard self.tasks[id] === downloadTask else { return }
            self.progress[id] = totalBytesExpectedToWrite > 0 ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) : 0
            let size = max(totalBytesWritten, totalBytesExpectedToWrite)
            if size > 0 {
                self.downloads[id]?.bytes = size
                // Abort oversized/underreported responses before filling the disk.
                let budget = self.downloadPlan().reservedBytes[id] ?? 0
                if size > budget { self.discardFile(id); await self.completed(id) }
            }
        }
    }
    nonisolated public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let id = task.taskDescription else { return }
        Task { @MainActor in
            // Successful completion is handled after atomic installation, not
            // here: delegate callbacks may otherwise race the staging Task.
            if let error { await self.failed(id, task: task, message: error.localizedDescription) }
        }
    }
    nonisolated public func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in
            if session.configuration.identifier == Self.hlsSessionIdentifier { let completion = self.hlsBackgroundCompletion; self.hlsBackgroundCompletion = nil; completion?() }
            else { let completion = self.backgroundCompletion; self.backgroundCompletion = nil; completion?() }
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
