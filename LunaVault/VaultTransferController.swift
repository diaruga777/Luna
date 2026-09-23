import BackgroundTasks
import Foundation
import LunaVaultStore
import LunaVaultSync
import LunaVaultUI

/// One app-process drain for the extension inbox and the Mac's durable pending
/// changes. Every continued-processing request joins this same queue.
@MainActor final class VaultTransferController {
    private let runtime: VaultConnectedRuntime
    private let queue: VaultIncomingQueue
    private let identifierPrefix: String
    private var worker: Task<Void, Never>?
    private var continued: [BGContinuedProcessingTask] = []
    private var processing: [BGTask] = []
    private var lastPending: [String: Int64] = [:]
    private var completedBytes: Int64 = 0
    private var progressTotal: Int64 = 1
    private var progressCompleted: Int64 = 0
    private var intakeCount = 0
    private var continuedSubmitted = false
    var didChange: (() -> Void)?

    init(runtime: VaultConnectedRuntime, queue: VaultIncomingQueue, bundleID: String) {
        self.runtime = runtime
        self.queue = queue
        identifierPrefix = bundleID
    }

    var isRunning: Bool { worker != nil }

    func beginIntake() {
        intakeCount += 1
        start(userInitiated: true)
    }

    func endIntake() { intakeCount = max(0, intakeCount - 1) }

    func start(userInitiated: Bool = false) {
        if userInitiated { submitContinuedRequest() }
        scheduleProcessingIfNeeded()
        guard worker == nil else { return }
        lastPending = [:]
        completedBytes = 0
        progressTotal = 1
        progressCompleted = 0
        worker = Task { [weak self] in
            guard let self else { return }
            await self.drain()
        }
    }

    func handle(_ task: BGTask) {
        if let continuedTask = task as? BGContinuedProcessingTask {
            continuedSubmitted = false
            continued.append(continuedTask)
            continuedTask.progress.totalUnitCount = progressTotal
            continuedTask.progress.completedUnitCount = progressCompleted
        } else { processing.append(task) }
        task.expirationHandler = { [weak self] in
            Task { @MainActor in
                self?.worker?.cancel()
                self?.scheduleProcessingIfNeeded()
            }
        }
        start()
    }

    private func submitContinuedRequest() {
        guard continued.isEmpty && !continuedSubmitted else { return }
        let identifier = identifierPrefix + ".transfer." + UUID().uuidString
        let request = BGContinuedProcessingTaskRequest(
            identifier: identifier, title: "Syncing to Mac", subtitle: "Preparing Vault files")
        request.strategy = .queue
        do { try BGTaskScheduler.shared.submit(request); continuedSubmitted = true }
        catch { scheduleProcessingIfNeeded() }
    }

    private func scheduleProcessingIfNeeded() {
        let hasWork = ((try? queue.items().isEmpty) == false) || ((try? runtime.store.pendingLocalChanges().isEmpty) == false)
        guard hasWork, (try? runtime.store.peer()?.lastConnectedAt) != nil else { return }
        let request = BGProcessingTaskRequest(identifier: identifierPrefix + ".sync")
        request.requiresNetworkConnectivity = true
        try? BGTaskScheduler.shared.submit(request)
    }

    private func drain() async {
        var succeeded = false
        defer {
            worker = nil
            for task in continued { task.setTaskCompleted(success: succeeded) }
            for task in processing { task.setTaskCompleted(success: succeeded) }
            continued.removeAll(); processing.removeAll()
            if !succeeded { scheduleProcessingIfNeeded() }
            didChange?()
        }
        do {
            var blocked = Set<String>()
            while !Task.isCancelled {
                let items = try queue.items()
                let pendingBefore = try await runtime.pendingUploads()
                if pendingBefore.isEmpty {
                    for item in items where !blocked.contains(item.id) {
                        try Task.checkCancellation()
                        do {
                            try await stage(item)
                            didChange?()
                            break // Announce one file, then await the Mac's confirmation.
                        } catch {
                            blocked.insert(item.id)
                        }
                    }
                }
                let uploads = try await runtime.pendingUploads()
                let remaining = try queue.items()
                updateProgress(uploads: uploads, queued: remaining)
                if uploads.isEmpty && remaining.isEmpty && intakeCount == 0 {
                    succeeded = true
                    return
                }
                if uploads.isEmpty && intakeCount == 0 && remaining.allSatisfy({ blocked.contains($0.id) }) {
                    return
                }
                if uploads.isEmpty && remaining.isEmpty {
                    try await Task.sleep(for: .milliseconds(250))
                    continue
                }
                let status = await runtime.connectionStatus()
                if status == .notPaired || status == .offline {
                    await runtime.reconnect()
                    let retry = await runtime.connectionStatus()
                    if retry == .notPaired || retry == .offline { return }
                }
                try await Task.sleep(for: .milliseconds(500))
            }
        } catch {
            // The payload and pending local changes remain durable for a later
            // foreground launch or system processing wake.
        }
    }

    private func stage(_ item: VaultIncomingQueue.Item) async throws {
        let name: String
        if let prepared = item.destinationName {
            name = prepared
            if let existing = try runtime.store.file(named: name), !existing.deleted {
                try queue.remove(item)
                return
            }
        } else {
            let desired = item.relativeName
            if let existing = try runtime.store.file(named: desired), !existing.deleted {
                let path = desired as NSString
                let ext = path.pathExtension
                let base = ext.isEmpty ? path.lastPathComponent : (path.lastPathComponent as NSString).deletingPathExtension
                let parent = path.deletingLastPathComponent
                let suffix = " (" + String(item.id.suffix(8)) + ")"
                let alternate = base + suffix + (ext.isEmpty ? "" : "." + ext)
                name = parent == "." ? alternate : parent + "/" + alternate
            } else { name = desired }
            _ = try queue.prepare(item, destinationName: name)
        }
        if item.isDirectory { try await runtime.importDirectory(named: name) }
        else { try await runtime.importFile(at: queue.payloadURL(for: item), named: name) }
        try queue.remove(item)
    }

    private func updateProgress(uploads: [VaultPendingUpload], queued: [VaultIncomingQueue.Item]) {
        let current = Dictionary(uniqueKeysWithValues: uploads.map { ($0.name, max($0.totalBytes, 1)) })
        for (name, size) in lastPending where current[name] == nil { completedBytes += size }
        lastPending = current
        let remainingBytes = current.values.reduce(Int64(0), +)
            + queued.reduce(Int64(0)) { $0 + max($1.byteCount, 1) }
        progressTotal = max(1, completedBytes + remainingBytes)
        progressCompleted = min(progressTotal, completedBytes + uploads.reduce(Int64(0)) { $0 + $1.sentBytes })
        let count = uploads.count + queued.count
        let title = "Syncing to Mac"
        let subtitle = count == 1 ? "1 file remaining" : "\(count) files remaining"
        for task in continued {
            task.progress.totalUnitCount = progressTotal
            task.progress.completedUnitCount = progressCompleted
            task.updateTitle(title, subtitle: subtitle)
        }
        didChange?()
    }
}
