import BackgroundTasks
import Foundation
import UIKit
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
    private var lastProgressAt = Date()
    private var lastProgressSnapshot: (bytes: Int64, count: Int)?
    private var intakeCount = 0
    private var continuedSubmitted = false
    private var continuedIdentifier: String?
    private var backgroundLease: UIBackgroundTaskIdentifier = .invalid
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

    /// Resume durable uploads when Vault is opened. A continued task is only
    /// submitted for a new user-initiated import.
    func resumeFromUserOpen() {
        start()
    }

    func start(userInitiated: Bool = false) {
        if userInitiated { submitContinuedRequest() }
        scheduleProcessingIfNeeded()
        guard worker == nil else { return }
        guard hasWork || intakeCount > 0 || !continued.isEmpty || !processing.isEmpty else { return }
        lastPending = [:]
        completedBytes = 0
        progressTotal = 1
        progressCompleted = 0
        lastProgressAt = Date()
        lastProgressSnapshot = nil
        beginBackgroundLease()
        worker = Task { [weak self] in
            guard let self else { return }
            await self.drain()
        }
    }

    func handle(_ task: BGTask) {
        if let continuedTask = task as? BGContinuedProcessingTask {
            if continuedTask.identifier == continuedIdentifier {
                continuedSubmitted = false
                continuedIdentifier = nil
            }
            continued.append(continuedTask)
            continuedTask.progress.totalUnitCount = progressTotal
            continuedTask.progress.completedUnitCount = progressCompleted
        } else { processing.append(task) }
        task.expirationHandler = { [weak self, weak task] in
            Task { @MainActor in
                guard let self, let task else { return }
                self.expire(task)
            }
        }
        if let continuedTask = task as? BGContinuedProcessingTask {
            Task { [weak self, weak continuedTask] in
                while true {
                    try? await Task.sleep(for: .seconds(30))
                    guard let self, let continuedTask,
                          self.continued.contains(where: { $0 === continuedTask }) else { return }
                    // Expire an idle activity, never a healthy large upload
                    // simply because three minutes elapsed since submission.
                    if Date().timeIntervalSince(self.lastProgressAt) >= 180 {
                        self.expire(continuedTask)
                        return
                    }
                }
            }
        }
        start()
    }

    private func expire(_ task: BGTask) {
        guard continued.contains(where: { $0 === task }) || processing.contains(where: { $0 === task }) else { return }
        continued.removeAll { $0 === task }
        processing.removeAll { $0 === task }
        task.setTaskCompleted(success: false)
        // Foreground transfers do not depend on a background task's lifetime.
        if UIApplication.shared.applicationState == .background,
           continued.isEmpty, processing.isEmpty, backgroundLease == .invalid {
            worker?.cancel()
        }
        scheduleProcessingIfNeeded()
    }

    private func submitContinuedRequest() {
        guard continued.isEmpty && !continuedSubmitted else { return }
        guard (try? runtime.store.peer()?.lastConnectedAt) != nil else { return }
        let identifier = identifierPrefix + ".transfer." + UUID().uuidString
        guard BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil, launchHandler: { task in
            Task { @MainActor in VaultConnectedWiring.handleSyncBackgroundTask(task) }
        }) else { return }
        let request = BGContinuedProcessingTaskRequest(
            identifier: identifier, title: "Syncing to Mac", subtitle: "Preparing Vault files")
        request.strategy = .fail
        do {
            try BGTaskScheduler.shared.submit(request)
            continuedSubmitted = true
            continuedIdentifier = identifier
        }
        catch { scheduleProcessingIfNeeded() }
    }

    private var hasWork: Bool {
        ((try? queue.items().isEmpty) == false) || ((try? runtime.store.pendingLocalChanges().isEmpty) == false)
    }

    private func beginBackgroundLease() {
        guard backgroundLease == .invalid, UIApplication.shared.applicationState != .background else { return }
        backgroundLease = UIApplication.shared.beginBackgroundTask(withName: "Vault transfer") { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.endBackgroundLease()
                if UIApplication.shared.applicationState == .background,
                   self.continued.isEmpty && self.processing.isEmpty {
                    self.worker?.cancel()
                    self.scheduleProcessingIfNeeded()
                }
            }
        }
    }

    private func endBackgroundLease() {
        guard backgroundLease != .invalid else { return }
        let value = backgroundLease
        backgroundLease = .invalid
        UIApplication.shared.endBackgroundTask(value)
    }

    private func scheduleProcessingIfNeeded() {
        guard hasWork, (try? runtime.store.peer()?.lastConnectedAt) != nil else { return }
        let request = BGProcessingTaskRequest(identifier: identifierPrefix + ".sync")
        request.requiresNetworkConnectivity = true
        try? BGTaskScheduler.shared.submit(request)
    }

    private func drain() async {
        var succeeded = false
        defer {
            worker = nil
            endBackgroundLease()
            let handledShareTask = continued.contains { $0.identifier == identifierPrefix + ".share.transfer" }
            for task in continued { task.setTaskCompleted(success: succeeded) }
            for task in processing { task.setTaskCompleted(success: succeeded) }
            continued.removeAll(); processing.removeAll()
            if let continuedIdentifier {
                BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: continuedIdentifier)
                self.continuedIdentifier = nil
                continuedSubmitted = false
            }
            if !hasWork && !handledShareTask {
                BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifierPrefix + ".share.transfer")
            }
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
                if Date().timeIntervalSince(lastProgressAt) > (intakeCount > 0 ? 300 : 120) {
                    guard UIApplication.shared.applicationState != .background else { return }
                    // Pings can keep a dead transfer looking connected. A new
                    // session re-announces durable changes and resumes blocks.
                    await runtime.reconnect(force: true)
                    lastProgressAt = Date()
                }
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
                    if retry == .notPaired { return }
                    if retry == .offline {
                        guard UIApplication.shared.applicationState != .background else { return }
                        try await Task.sleep(for: .seconds(5))
                        continue
                    }
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
        if lastProgressSnapshot?.bytes != progressCompleted || lastProgressSnapshot?.count != count {
            lastProgressAt = Date()
            lastProgressSnapshot = (progressCompleted, count)
        }
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
