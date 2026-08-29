import BackgroundTasks
import Foundation
import LunaVaultSync

/// Owns the app-process wake sources for durable Vault sync. Provider changes,
/// foreground activation, and BGProcessingTask delivery all converge on the
/// same bounded queue runner.
public final class VaultSyncRuntimeController: NSObject, @unchecked Sendable {
    private let sync: VaultSyncCoordinator
    private let taskIdentifier: String
    private let metadataQuery: NSMetadataQuery?
    private let notificationCenter: NotificationCenter
    private let lock = NSLock()
    private var observerTokens: [NSObjectProtocol] = []
    private var activeTask: Task<Void, Never>?

    public init?(services: VaultRuntimeServices, bundle: Bundle = .main,
                 notificationCenter: NotificationCenter = .default) {
        guard let sync = services.syncCoordinator,
              let bundleID = bundle.bundleIdentifier else { return nil }
        self.sync = sync
        taskIdentifier = bundleID + ".sync"
        metadataQuery = services.policy.location == .iCloud ? NSMetadataQuery() : nil
        self.notificationCenter = notificationCenter
        super.init()

        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: taskIdentifier, using: nil
        ) { [weak self] task in
            guard let self, let processing = task as? BGProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            self.handle(processing)
        }

        if let metadataQuery {
            metadataQuery.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
            // Foundation exposes these notification names as Objective-C
            // constants on some SDKs and not as Swift members on others.
            // Keep the bridge explicit so the iOS 26 SDK remains portable.
            for name in [Notification.Name("NSMetadataQueryDidFinishGatheringNotification"),
                         Notification.Name("NSMetadataQueryDidUpdateNotification")] {
                observerTokens.append(notificationCenter.addObserver(
                    forName: name, object: metadataQuery, queue: .main
                ) { [weak self] _ in self?.wake(.providerStateChanged) })
            }
            metadataQuery.start()
        }
    }

    deinit {
        activeTask?.cancel()
        metadataQuery?.stop()
        for token in observerTokens { notificationCenter.removeObserver(token) }
    }

    public func applicationDidEnterBackground() {
        scheduleIfNeeded()
    }

    public func applicationWillEnterForeground() {
        wake(.providerStateChanged)
    }

    public func wake(_ reason: VaultSyncWakeReason) {
        lock.withLock {
            guard activeTask == nil else { return }
            activeTask = Task { [weak self] in
                guard let self else { return }
                _ = await self.sync.runReadyJobs(wakeReason: reason)
                self.lock.withLock { self.activeTask = nil }
                self.scheduleIfNeeded()
            }
        }
    }

    private func handle(_ task: BGProcessingTask) {
        lock.lock()
        guard activeTask == nil else {
            lock.unlock()
            task.setTaskCompleted(success: false)
            return
        }
        task.expirationHandler = { [weak self] in self?.activeTask?.cancel() }
        activeTask = Task { [weak self] in
            guard let self else { task.setTaskCompleted(success: false); return }
            _ = await self.sync.runReadyJobs(wakeReason: .scheduled)
            let succeeded = !Task.isCancelled
            self.lock.withLock { self.activeTask = nil }
            task.setTaskCompleted(success: succeeded)
            self.scheduleIfNeeded()
        }
        lock.unlock()
    }

    private func scheduleIfNeeded() {
        guard sync.hasPendingJobs() else { return }
        let request = BGProcessingTaskRequest(identifier: taskIdentifier)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15)
        try? BGTaskScheduler.shared.submit(request)
    }
}
