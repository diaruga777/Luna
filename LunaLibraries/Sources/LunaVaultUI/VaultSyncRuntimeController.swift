import BackgroundTasks
import Foundation
import LunaStorage
import LunaVaultSync

/// Owns the app-process wake sources for durable Vault sync. Provider changes,
/// foreground activation, and BGProcessingTask delivery all converge on the
/// same bounded queue runner.
public final class VaultSyncRuntimeController: NSObject, @unchecked Sendable {
    private let sync: VaultSyncCoordinator
    private let taskIdentifier: String
    private let metadataQuery: NSMetadataQuery?
    private let notificationCenter: NotificationCenter
    private let wifiOnlyUploads: @Sendable () -> Bool
    private let lock = NSLock()
    private var observerTokens: [NSObjectProtocol] = []
    private var activeTask: Task<Void, Never>?

    /// The BGTask identifier this controller submits and handles. The app
    /// registers this string with `BGTaskScheduler` exactly once at launch
    /// (before any runtime instance exists); this controller only submits
    /// requests and answers deliveries routed to it, and never registers.
    public static func taskIdentifier(bundle: Bundle = .main) -> String? {
        bundle.bundleIdentifier.map { $0 + ".sync" }
    }

    public init?(services: VaultRuntimeServices, bundle: Bundle = .main,
                 notificationCenter: NotificationCenter = .default,
                 wifiOnlyUploads: @escaping @Sendable () -> Bool = { false }) {
        guard let sync = services.syncCoordinator,
              let identifier = Self.taskIdentifier(bundle: bundle) else { return nil }
        self.sync = sync
        taskIdentifier = identifier
        metadataQuery = services.policy.location == .iCloud ? NSMetadataQuery() : nil
        self.notificationCenter = notificationCenter
        self.wifiOnlyUploads = wifiOnlyUploads
        super.init()

        _ = NetworkReachability.shared
        observerTokens.append(notificationCenter.addObserver(
            forName: NetworkReachability.wifiAvailableNotification, object: nil, queue: nil
        ) { [weak self] _ in self?.wake(.providerStateChanged) })

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
                _ = await self.sync.runReadyJobs(wakeReason: reason,
                                                 uploadsAllowed: self.uploadsAllowed)
                self.lock.withLock { self.activeTask = nil }
                self.scheduleIfNeeded()
            }
        }
    }

    /// Answers a delivered `BGProcessingTask` for this controller's task
    /// identifier. The app's launch handler is the only caller; it looks up
    /// the current controller through `VaultWiring` each time the system
    /// fires the task, since a Settings change can replace this instance.
    public func handle(_ task: BGProcessingTask) {
        lock.lock()
        guard activeTask == nil else {
            lock.unlock()
            task.setTaskCompleted(success: false)
            return
        }
        task.expirationHandler = { [weak self] in self?.activeTask?.cancel() }
        activeTask = Task { [weak self] in
            guard let self else { task.setTaskCompleted(success: false); return }
            _ = await self.sync.runReadyJobs(wakeReason: .scheduled,
                                             uploadsAllowed: self.uploadsAllowed)
            let succeeded = !Task.isCancelled
            self.lock.withLock { self.activeTask = nil }
            task.setTaskCompleted(success: succeeded)
            self.scheduleIfNeeded()
        }
        lock.unlock()
    }

    private func scheduleIfNeeded() {
        guard sync.hasPendingJobs(uploadsAllowed: uploadsAllowed) else { return }
        let request = BGProcessingTaskRequest(identifier: taskIdentifier)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15)
        try? BGTaskScheduler.shared.submit(request)
    }

    private var uploadsAllowed: Bool {
        !wifiOnlyUploads() || NetworkReachability.shared.isOnWiFi
    }
}
