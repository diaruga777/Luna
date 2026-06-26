//
//  VoiceModelDownloadManager.swift
//  ReaderKit
//

import Foundation

/// Downloads neural-voice model files (Piper, Kokoro) from Hugging Face into the
/// App Group, reporting aggregate progress and surfacing failures. One manager
/// instance drives one engine's download; the UI keeps a manager per in-flight
/// engine.
///
/// Files are fetched sequentially with `URLSession` download tasks and moved
/// into `VoiceModelStore.modelDirectory(for:)`. A download is only considered
/// complete once EVERY file is on disk; a failed/partial download deletes
/// whatever landed so `VoiceModelStore.isDownloaded` never reports a half model.
final class VoiceModelDownloadManager: NSObject {

    /// Download lifecycle states, surfaced to the settings UI on the main queue.
    enum State: Equatable {
        case idle
        case downloading(fractionCompleted: Double)
        case finished
        case failed(message: String)
    }

    let kind: VoiceEngineKind
    /// Called on the main queue whenever `state` changes.
    var onStateChange: ((State) -> Void)?

    private(set) var state: State = .idle {
        didSet {
            let snapshot = state
            DispatchQueue.main.async { [weak self] in self?.onStateChange?(snapshot) }
        }
    }

    private lazy var session = URLSession(
        configuration: .default, delegate: self, delegateQueue: nil)
    private var files: [VoiceModelFile] = []
    private var currentFileIndex = 0
    private var task: URLSessionDownloadTask?
    private var isCancelled = false

    init(kind: VoiceEngineKind) {
        self.kind = kind
        super.init()
    }

    /// Begins downloading every file for the engine. No-ops if already complete.
    func start() {
        guard kind.requiresDownload else {
            state = .failed(message: "This engine has no downloadable model.")
            return
        }
        guard let files = VoiceModelRegistry.files(for: kind),
              VoiceModelStore.ensureModelDirectory(for: kind) != nil else {
            state = .failed(message: "Voice storage is unavailable.")
            return
        }
        if VoiceModelStore.isDownloaded(kind) {
            state = .finished
            return
        }
        self.files = files
        currentFileIndex = 0
        isCancelled = false
        state = .downloading(fractionCompleted: 0)
        downloadNextFile()
    }

    /// Cancels an in-flight download and removes any partial files.
    func cancel() {
        isCancelled = true
        task?.cancel()
        task = nil
        VoiceModelStore.deleteModel(for: kind)
        state = .idle
    }

    private func downloadNextFile() {
        guard !isCancelled else { return }
        guard currentFileIndex < files.count else {
            // Verify completeness before declaring success.
            if VoiceModelStore.isDownloaded(kind) {
                state = .finished
            } else {
                VoiceModelStore.deleteModel(for: kind)
                state = .failed(message: "Some files failed to download.")
            }
            return
        }
        let file = files[currentFileIndex]
        let task = session.downloadTask(with: file.remoteURL)
        // Tag the task with its file index so the delegate knows where to move it.
        task.taskDescription = String(currentFileIndex)
        self.task = task
        task.resume()
    }

    /// Aggregate fraction across all files, weighting the in-flight file by its
    /// own progress and counting completed files as whole.
    private func aggregateFraction(currentFileFraction: Double) -> Double {
        guard !files.isEmpty else { return 0 }
        let completed = Double(currentFileIndex)
        return min(1.0, (completed + currentFileFraction) / Double(files.count))
    }
}

extension VoiceModelDownloadManager: URLSessionDownloadDelegate {
    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        state = .downloading(fractionCompleted: aggregateFraction(currentFileFraction: fraction))
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard !isCancelled else { return }
        // Validate the HTTP status — Hugging Face returns 200 for resolved LFS
        // files; an error page would otherwise be saved as the "model".
        if let http = downloadTask.response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            VoiceModelStore.deleteModel(for: kind)
            state = .failed(message: "Download failed (HTTP \(http.statusCode)).")
            return
        }
        guard let indexString = downloadTask.taskDescription,
              let index = Int(indexString),
              files.indices.contains(index),
              let destination = VoiceModelStore.localURL(for: files[index], kind: kind) else {
            state = .failed(message: "Could not place the downloaded file.")
            return
        }
        let fm = FileManager.default
        do {
            try? fm.removeItem(at: destination)
            try fm.moveItem(at: location, to: destination)
        } catch {
            state = .failed(message: "Could not save the voice model.")
            return
        }
        currentFileIndex += 1
        downloadNextFile()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let error, !isCancelled else { return }
        // `cancel()` surfaces an error too; ignore that case via `isCancelled`.
        VoiceModelStore.deleteModel(for: kind)
        state = .failed(message: error.localizedDescription)
    }
}
