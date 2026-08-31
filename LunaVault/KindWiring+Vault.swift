import BackgroundTasks
import Foundation
import UIKit
import UniformTypeIdentifiers
import LunaAppConfig
import LunaVaultBackend
import LunaVaultCrypto
import LunaVaultModels
import LunaVaultSearch
import LunaVaultSetup
import LunaVaultStorage
import LunaVaultSync
import LunaVaultTailscale
import LunaVaultUI

/// The composition seam for Luna Vault. The app owns construction of the
/// repository, root-key manager, and optional paired-Mac backend here. The
/// scene receives only the resulting runtime instead of locating services.
@MainActor enum VaultWiring {
    private static var services: VaultRuntimeServices?
    private static var syncRuntime: VaultSyncRuntimeController?
    /// Bumps on explicit credential lifecycle changes. This keeps a save of
    /// an otherwise identical credential from reusing a live backend actor.
    private static var runtimeGeneration: UInt64 = 0
    /// The Mac credential loaded for `runtimeGeneration`, and the generation
    /// it was loaded under. `renderState()` calls `makeServices()` on every
    /// `viewWillAppear`, which would otherwise mean a Keychain query per
    /// render; a credential only actually changes on the explicit lifecycle
    /// events that bump `runtimeGeneration`, not on every render.
    private static var cachedMacCredential: VaultMacPairingCredential?
    private static var cachedMacCredentialGeneration: UInt64?
    private static let setupCoordinator = VaultSetupCoordinator(
        configuration: VaultSetupConfiguration(
            keychainAccessGroup: Bundle.main.object(forInfoDictionaryKey: "LunaVaultKeychainAccessGroup") as? String),
        store: UserDefaultsVaultSetupStore(
            defaults: UserDefaults(suiteName: AppConfig.appGroupID) ?? .standard))
    private static var backgroundScheduler: VaultBackgroundTaskScheduler?
    private static var importCoordinator: VaultImportCoordinator?
    private static var indexWorker: VaultIndexWorker?
    private static var thumbnailStore: VaultThumbnailStore?
    private static var previewRouter: VaultPreviewRouter?
    private static var documentImporter: VaultDocumentImportPresenter?
    private static var objectPreviewPresenter: VaultObjectPreviewPresenter?
    private static let identityConfirmer = VaultMacIdentityConfirmationPresenter()
    /// One embedded tsnet node per process, created lazily: the node costs
    /// memory and network activity, so nothing starts it until a Tailscale
    /// endpoint dial or the settings screen needs it.
    private static var tailnetRunner: VaultTailnetNodeRunner?

    static func install() {
        _ = setupCoordinator.load()
        _ = makeServices()
    }

    /// The launch handler's stable entry point for the sync BGTask. The app
    /// registers the identifier once in `didFinishLaunching`, before any
    /// runtime instance exists; this seam looks up whichever
    /// `VaultSyncRuntimeController` is current when the system fires the
    /// task, since a Settings change replaces the runtime without
    /// re-registering. No runtime yet (first run unfinished, or a provider
    /// failure) completes the task as not-succeeded rather than crashing.
    static func handleSyncBackgroundTask(_ task: BGTask) {
        guard let processing = task as? BGProcessingTask, let syncRuntime else {
            task.setTaskCompleted(success: false)
            return
        }
        syncRuntime.handle(processing)
    }

    /// The launch handler's stable entry point for the local-maintenance
    /// BGTasks (import repair, index, thumbnail maintenance). Same
    /// register-once contract as `handleSyncBackgroundTask`.
    static func handleMaintenanceBackgroundTask(_ task: BGTask, kind: VaultBackgroundTaskKind) {
        guard let processing = task as? BGProcessingTask, let backgroundScheduler else {
            task.setTaskCompleted(success: false)
            return
        }
        backgroundScheduler.handleSystemTask(processing, kind: kind)
    }

    static func applicationDidEnterBackground() {
        syncRuntime?.applicationDidEnterBackground()
        // Only submit the system request here. Starting the operation
        // in-process at backgrounding raced the real delivery: a suspend
        // mid-work left `handleMaintenanceBackgroundTask`'s later call
        // finding the kind already occupied, completing immediately without
        // doing anything.
        for kind in [VaultBackgroundTaskKind.importRepair, .index, .thumbnailMaintenance] {
            try? backgroundScheduler?.submit(kind: kind)
        }
    }

    static func applicationWillEnterForeground() {
        syncRuntime?.applicationWillEnterForeground()
        _ = backgroundScheduler?.run(kind: .importRepair)
        _ = backgroundScheduler?.run(kind: .index)
        _ = backgroundScheduler?.run(kind: .thumbnailMaintenance)
    }

    static func makeRootViewController() -> UIViewController {
        // Index/storage construction is intentionally deferred until setup is
        // ready. The provider callbacks let the root lazily recover after a
        // first-run completion or a transient provider failure.
        let index = setupCoordinator.state.isReady ? makeSearchIndex() : nil
        let importer = VaultDocumentImportPresenter(
            coordinatorProvider: { importCoordinator })
        let opener = VaultObjectPreviewPresenter(
            routerProvider: { previewRouter },
            servicesProvider: { services })
        let root = VaultRootViewController(
            services: makeServices(), setupCoordinator: setupCoordinator,
            searchIndex: index, searchIndexProvider: makeSearchIndex,
            servicesProvider: makeServices,
            importHandler: { [weak importer] in importer?.present() },
            openHandler: { [weak opener] objectID in opener?.open(objectID) },
            settingsActions: makeSettingsActions())
        importer.presenter = root
        opener.presenter = root
        documentImporter = importer
        objectPreviewPresenter = opener
        identityConfirmer.attach(to: root)
        return root
    }

    private static func makeSettingsActions() -> VaultSettingsActions {
        VaultSettingsActions(
            clearCache: {
                guard let value = services ?? makeServices() else {
                    throw VaultRuntimeError.providerUnavailable
                }
                // A closure literal formed inside this `@MainActor` enum
                // inherits its isolation, so the eviction scan below would
                // otherwise run ON the main actor despite the spinner text.
                // `Task.detached` is the same off-main seam
                // `VaultHomeViewController.scheduleSearch` already uses for
                // this queue-confined, `@unchecked Sendable` repository.
                let repository = value.repository
                try await Task.detached(priority: .utility) {
                    try repository.evictExpired()
                }.value
            },
            rebuildIndex: {
                guard let index = makeSearchIndex() else {
                    throw VaultSearchError.sqlite("Vault index is unavailable")
                }
                try await Task.detached(priority: .utility) {
                    try index.rebuild()
                }.value
            },
            requestICloudEviction: requestICloudEviction,
            reconfigureRuntime: {
                invalidateRuntime()
                _ = makeServices()
            },
            revokeMacCredential: { _ in
                // Vault's wire protocol has no unauthenticated revoke call.
                // Drop the local runtime immediately; the UI reports the
                // remote operation as local-only and instructs the user to
                // revoke the companion before pairing again.
                invalidateRuntime()
                return .localOnly(reason: "The paired Mac must be revoked from its companion process.")
            },
            tailnet: makeTailnetRunner()
        )
    }

    private static func makeTailnetRunner() -> VaultTailnetNodeRunner {
        if let tailnetRunner { return tailnetRunner }
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let runner = VaultTailnetNodeRunner(configuration: VaultTailnetConfiguration(
            stateDirectory: base.appendingPathComponent("LunaVault/Tailscale", isDirectory: true),
            hostName: "luna-vault-iphone"))
        tailnetRunner = runner
        return runner
    }

    private static func makeServices() -> VaultRuntimeServices? {
        guard let policy = setupCoordinator.state.policy else {
            clearMediaRuntime()
            return nil
        }
        let credential: VaultMacPairingCredential?
        do {
            credential = policy.location == .mac ? try loadMacCredential() : nil
        } catch {
            clearMediaRuntime()
            return nil
        }
        let runtimeIdentity = makeRuntimeIdentity(policy: policy, credential: credential)
        if let services, services.runtimeIdentity == runtimeIdentity { return services }
        // A Settings policy or credential change must rebuild the provider.
        // Keeping the previous service here would make a newly-selected Mac
        // or credential appear ready until the next process launch.
        clearMediaRuntime()
        do {
            let value: VaultRuntimeServices
            if policy.location == .mac {
                value = try makeMacServices(policy: policy, credential: credential,
                    runtimeIdentity: runtimeIdentity)
            }
            else {
                value = try VaultRuntimeServices.production(policy: policy,
                    runtimeIdentity: runtimeIdentity)
            }
            services = value
            syncRuntime = VaultSyncRuntimeController(services: value)
            installBackgroundRuntime(for: value)
            return value
        } catch {
            return nil
        }
    }

    private static func invalidateRuntime() {
        runtimeGeneration &+= 1
        clearMediaRuntime()
    }

    private static func clearMediaRuntime() {
        services = nil
        syncRuntime = nil
        importCoordinator = nil
        indexWorker = nil
        thumbnailStore = nil
        previewRouter = nil
        backgroundScheduler = nil
    }

    private static func loadMacCredential() throws -> VaultMacPairingCredential? {
        if cachedMacCredentialGeneration == runtimeGeneration { return cachedMacCredential }
        guard let accessGroup = Bundle.main.object(forInfoDictionaryKey: "LunaVaultKeychainAccessGroup") as? String,
              !accessGroup.isEmpty else { throw VaultMacProtocolError.unavailable }
        let store = VaultMacKeychainCredentialStore(accessGroup: accessGroup,
            service: "\(Bundle.main.bundleIdentifier ?? "com.hsanabria.luna.vault").mac-pairing")
        let value = try store.load()
        cachedMacCredential = value
        cachedMacCredentialGeneration = runtimeGeneration
        return value
    }

    private static func makeRuntimeIdentity(policy: VaultStoragePolicy,
                                             credential: VaultMacPairingCredential?) -> VaultRuntimeIdentity {
        let backendIdentity: VaultBackendIdentity?
        switch policy.location {
        case .device:
            backendIdentity = nil
        case .iCloud:
            backendIdentity = VaultBackendIdentity(location: .iCloud,
                containerIdentifier: AppConfig.vaultICloudContainerID, vaultID: "default")
        case .mac:
            backendIdentity = credential.map {
                VaultBackendIdentity(location: .mac,
                    containerIdentifier: $0.endpointBinding, vaultID: "default")
            }
        }
        return VaultRuntimeIdentity(policy: policy, backendIdentity: backendIdentity,
            credentialGeneration: credential?.epoch,
            credentialFingerprint: credential?.fingerprint,
            runtimeGeneration: runtimeGeneration)
    }

    /// Registers the local maintenance path at launch. It deliberately uses
    /// only repository, metadata, search, and thumbnail services; no backend
    /// or URLSession is constructed for import repair or indexing.
    private static func installBackgroundRuntime(for services: VaultRuntimeServices) {
        let root = services.repository.contentDirectory.deletingLastPathComponent()
        do {
            let metadata = try VaultImportedFileMetadataStore(
                rootURL: root.appendingPathComponent("VaultImportStaging/Metadata", isDirectory: true))
            let worker = VaultIndexWorker(
                repository: services.repository,
                metadataStore: metadata,
                searchIndex: try VaultSearchIndex(
                    databaseURL: root.appendingPathComponent("vault-index.sqlite")),
                owner: "vault-local-index")
            let thumbnails = try VaultThumbnailStore(
                rootURL: root.appendingPathComponent("VaultThumbnails", isDirectory: true),
                repository: services.repository)
            let coordinator = try VaultImportCoordinator(
                repository: services.repository, metadataStore: metadata,
                configuration: services.importConfiguration)
            let scheduler = VaultBackgroundTaskScheduler(
                identifierPrefix: Bundle.main.bundleIdentifier ?? "com.hsanabria.luna.vault")
            scheduler.register(kind: .importRepair) { [weak coordinator] in
                guard let coordinator else { return false }
                return (try? coordinator.repairInterruptedImports()) != nil
            }
            scheduler.register(kind: .index) { [weak worker] in
                guard let worker else { return false }
                var processed = 0
                while !Task.isCancelled && processed < 64 {
                    guard await worker.processNext() != nil else { break }
                    processed += 1
                }
                return !Task.isCancelled
            }
            scheduler.register(kind: .thumbnailMaintenance) { [weak thumbnails] in
                guard let thumbnails else { return false }
                return (try? thumbnails.evictExpired()) != nil
            }
            // The system BGTask identifiers are registered once at launch
            // (`VaultAppDelegate.registerBackgroundTasks`); this scheduler
            // only receives operations to run, never registers.
            importCoordinator = coordinator
            indexWorker = worker
            thumbnailStore = thumbnails
            let requester = services.syncCoordinator.map(VaultSyncDownloadRequester.init(sync:))
            previewRouter = VaultPreviewRouter(
                repository: services.repository,
                cache: VaultCacheCoordinator(repository: services.repository),
                backend: services.remoteBackend,
                downloadRequester: requester,
                metadataStore: metadata)
            backgroundScheduler = scheduler
        } catch {
            // Storage setup already fails closed. Keep the UI usable while
            // leaving maintenance unregistered until the next launch.
            backgroundScheduler = nil
        }
    }

    private static func makeMacServices(policy: VaultStoragePolicy,
                                        credential: VaultMacPairingCredential?,
                                        runtimeIdentity: VaultRuntimeIdentity) throws -> VaultRuntimeServices {
        let accessGroup = Bundle.main.object(forInfoDictionaryKey: "LunaVaultKeychainAccessGroup") as? String
        guard let accessGroup, !accessGroup.isEmpty else { throw VaultMacProtocolError.unavailable }
        let rootKeys = VaultRootKeyManager(configuration:
            VaultCryptoConfiguration(keychainAccessGroup: accessGroup))
        let currentRoot = try rootKeys.loadOrCreate()
        let repository = try VaultRepository()
        let device = VaultDeviceBackend(store: repository)
        let backend: (any VaultBackendTransport)?
        if let credential, credential.revokedAt == nil {
            backend = try VaultMacRemoteBackend(
                endpoint: VaultMacEndpoint(binding: credential.endpointBinding),
                credential: credential,
                connector: VaultTailscaleMacConnector(runner: makeTailnetRunner(),
                                                      lan: VaultMacNWConnector()),
                identityConfirmer: identityConfirmer)
        } else {
            backend = nil
        }
        let sync: VaultSyncCoordinator?
        if let backend {
            let staging = repository.contentDirectory.deletingLastPathComponent()
                .appendingPathComponent("VaultSyncCiphertext", isDirectory: true)
            let payloadStore = try VaultFileSyncPayloadStore(
                rootURL: staging, vaultID: "default", repository: repository,
                rootKey: { try rootKeys.key(version: $0) })
            sync = VaultSyncCoordinator(repository: repository, backend: backend,
                payloadSource: payloadStore, owner: "iphone-mac-host",
                configuration: VaultSyncConfiguration(location: .mac))
        } else {
            sync = nil
        }
        return VaultRuntimeServices(
            policy: policy, repository: repository,
            deviceBackend: device, remoteBackend: backend, syncCoordinator: sync,
            runtimeIdentity: runtimeIdentity,
            remoteImportConfiguration: backend.map {
                VaultImportRemoteConfiguration(
                    backendKey: $0.identity.stableKey, vaultID: "default",
                    root: currentRoot,
                    rootKey: { try rootKeys.key(version: $0) },
                    payloadDirectory: repository.contentDirectory.deletingLastPathComponent()
                        .appendingPathComponent("VaultSyncCiphertext/uploads", isDirectory: true))
            },
            remoteImportBackendKey: backend?.identity.stableKey ?? "mac:unavailable")
    }

    private static func makeSearchIndex() -> VaultSearchIndex? {
        guard let container = AppConfig.sharedContainerURL() else { return nil }
        return try? VaultSearchIndex(databaseURL: container.appendingPathComponent("vault-index.sqlite"))
    }

    /// Requests eviction for every local object the iCloud backend can
    /// identify remotely, not just the most recently synced one, so the
    /// reported outcome matches the "whole local working copy" the Settings
    /// screen describes.
    private static func requestICloudEviction() async -> VaultICloudLocalState {
        guard let value = services ?? makeServices(),
              value.policy.location == .iCloud,
              let backend = value.remoteBackend as? VaultICloudBackend else { return .unavailable }
        let identities = remoteIdentities(for: value)
        let objects = (try? value.repository.objects()) ?? []
        let evictable = objects.compactMap { identities[$0.id] }
        var outcomes: [Result<VaultEvictionOutcome, Error>] = []
        for identity in evictable {
            do { outcomes.append(.success(try await backend.evictionOutcome(for: identity))) }
            catch { outcomes.append(.failure(error)) }
        }
        return .aggregating(outcomes)
    }

    /// The newest remote identity per object, from the sync job log, scoped
    /// to the given backend.
    private static func remoteIdentities(for services: VaultRuntimeServices)
        -> [VaultObjectID: VaultRemoteObjectIdentity] {
        guard let backend = services.remoteBackend else { return [:] }
        let jobs = (try? services.repository.jobs()) ?? []
        var result: [VaultObjectID: VaultRemoteObjectIdentity] = [:]
        for job in jobs.sorted(by: { $0.updatedAt > $1.updatedAt }) {
            guard job.backendKey == backend.identity.stableKey,
                  job.kind == .download || job.kind == .upload,
                  let objectID = job.objectID,
                  result[objectID] == nil,
                  let revision = job.revision,
                  let generation = job.payloadGeneration,
                  let rawKind = job.remoteObjectKind,
                  let kind = VaultRemoteObjectKind(rawValue: rawKind),
                  let identity = try? VaultRemoteObjectIdentity(objectID: objectID, revision: revision,
                                                                 kind: kind, generation: generation)
            else { continue }
            result[objectID] = identity
        }
        return result
    }
}

/// The UI owns only the import button. This host object owns the document
/// picker lease and hands the selected URL to the protected import coordinator.
@MainActor
private final class VaultDocumentImportPresenter: NSObject, UIDocumentPickerDelegate {
    weak var presenter: UIViewController?
    private let coordinatorProvider: () -> VaultImportCoordinator?
    private var picker: UIDocumentPickerViewController?
    private var progressOverlay: UIView?

    init(coordinatorProvider: @escaping () -> VaultImportCoordinator?) {
        self.coordinatorProvider = coordinatorProvider
        super.init()
    }

    func present() {
        guard let presenter else { return }
        guard coordinatorProvider() != nil else {
            showError(on: presenter, message: "Vault storage is not ready. Finish setup, then try again.")
            return
        }
        let value = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: false)
        value.delegate = self
        value.allowsMultipleSelection = false
        picker = value
        presenter.present(value, animated: true)
    }

    /// `importFile` hashes, copies, and seals the whole picked file — seconds
    /// for a multi-GB video. Run it off main (the coordinator is `@unchecked
    /// Sendable`) so the watchdog never kills the app mid-import, and block
    /// interaction with a spinner while it runs.
    func documentPicker(_ controller: UIDocumentPickerViewController,
                        didPickDocumentsAt urls: [URL]) {
        picker = nil
        guard let url = urls.first, let coordinator = coordinatorProvider(),
              let presenter else { return }
        let contentType = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
        beginImporting(on: presenter)
        Task { [weak self, weak presenter] in
            let outcome = await Task.detached(priority: .userInitiated) {
                Result { try coordinator.importFile(VaultImportSource(
                    fileURL: url, fileName: url.lastPathComponent, contentType: contentType)) }
            }.value
            guard let self, let presenter else { return }
            self.endImporting(on: presenter)
            switch outcome {
            case .success:
                (presenter as? VaultRootViewController)?.refresh()
            case .failure:
                self.showError(on: presenter, message: "The file could not be imported. Check its size and try again.")
            }
        }
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        picker = nil
    }

    private func beginImporting(on presenter: UIViewController) {
        presenter.view.isUserInteractionEnabled = false
        let overlay = UIView(frame: presenter.view.bounds)
        overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        overlay.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.6)
        let spinner = UIActivityIndicatorView(style: .large)
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.startAnimating()
        overlay.addSubview(spinner)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: overlay.centerYAnchor),
        ])
        presenter.view.addSubview(overlay)
        progressOverlay = overlay
    }

    private func endImporting(on presenter: UIViewController) {
        presenter.view.isUserInteractionEnabled = true
        progressOverlay?.removeFromSuperview()
        progressOverlay = nil
    }

    private func showError(on presenter: UIViewController, message: String) {
        let alert = UIAlertController(title: "Vault", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Done", style: .default))
        presenter.present(alert, animated: true)
    }
}

private final class VaultSyncDownloadRequester: VaultPreviewDownloadRequesting, @unchecked Sendable {
    private let sync: VaultSyncCoordinator

    init(sync: VaultSyncCoordinator) { self.sync = sync }

    func requestDownload(for identity: VaultRemoteObjectIdentity) async throws {
        _ = try await sync.download(identity, wakeReason: .userRequested)
    }
}

/// Presents only the plan returned by `VaultPreviewRouter`. A remote URL or
/// unverified ciphertext never crosses this boundary; remote opens perform a
/// complete authenticated sync download before constructing a player/QuickLook
/// controller.
@MainActor
private final class VaultObjectPreviewPresenter {
    weak var presenter: UIViewController?
    private let routerProvider: () -> VaultPreviewRouter?
    private let servicesProvider: () -> VaultRuntimeServices?

    init(routerProvider: @escaping () -> VaultPreviewRouter?,
         servicesProvider: @escaping () -> VaultRuntimeServices?) {
        self.routerProvider = routerProvider
        self.servicesProvider = servicesProvider
    }

    func open(_ objectID: VaultObjectID) {
        guard let presenter else { return }
        guard let router = routerProvider() else {
            showStatus(on: presenter, message: "Vault preview is unavailable until storage is ready.")
            return
        }
        let services = servicesProvider()
        Task { [weak self, weak presenter] in
            // The job scan behind `remoteIdentity` reads every sync job row;
            // run it off main, the way search already does, instead of
            // blocking the tap that opened this preview.
            let identity = await Task.detached(priority: .userInitiated) {
                services.flatMap { Self.remoteIdentity(for: objectID, services: $0) }
            }.value
            do {
                var plan = try await router.plan(objectID: objectID, remoteIdentity: identity)
                if plan.availability == .needsDownload, let identity {
                    plan = try await router.downloadAndPlan(objectID: objectID, identity: identity)
                }
                // `makeViewController` already begins and owns a preview
                // lease when the plan is ready (`VaultPreviewLeaseHostingViewController`
                // renews it while visible and ends it on disappear). A second,
                // outer lease here only added an un-renewed lease racing the
                // real one to expire first.
                let content = router.makeViewController(for: plan)
                await MainActor.run { presenter?.present(content, animated: true) }
            } catch {
                await MainActor.run { [weak self, weak presenter] in
                    guard let self, let presenter else { return }
                    self.showStatus(on: presenter, message: "This file could not be opened securely.")
                }
            }
        }
    }

    private nonisolated static func remoteIdentity(for objectID: VaultObjectID,
                                                   services: VaultRuntimeServices) -> VaultRemoteObjectIdentity? {
        guard let backend = services.remoteBackend else { return nil }
        let jobs = (try? services.repository.jobs()) ?? []
        return jobs.sorted(by: { $0.updatedAt > $1.updatedAt }).compactMap { job in
            guard job.objectID == objectID, job.backendKey == backend.identity.stableKey,
                  (job.kind == .download || job.kind == .upload),
                  let revision = job.revision, let generation = job.payloadGeneration,
                  let rawKind = job.remoteObjectKind,
                  let kind = VaultRemoteObjectKind(rawValue: rawKind) else { return nil }
            return try? VaultRemoteObjectIdentity(objectID: objectID, revision: revision,
                                                   kind: kind, generation: generation)
        }.first
    }

    private func showStatus(on presenter: UIViewController, message: String) {
        let alert = UIAlertController(title: "Vault", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Done", style: .default))
        presenter.present(alert, animated: true)
    }
}

private final class VaultMacIdentityConfirmationPresenter:
    VaultMacServerIdentityConfirming, @unchecked Sendable {
    private weak var presenter: UIViewController?
    private let lock = NSLock()
    private var confirmedBindings: Set<String> = []

    @MainActor func attach(to presenter: UIViewController) { self.presenter = presenter }

    func confirm(fingerprint: String, endpointBinding: String) async throws
        -> VaultMacServerIdentityConfirmation? {
        if lock.withLock({ confirmedBindings.contains("\(fingerprint)|\(endpointBinding)") }) {
            return VaultMacServerIdentityConfirmation(fingerprint: fingerprint,
                endpointBinding: endpointBinding)
        }
        return await withCheckedContinuation { continuation in
            Task { @MainActor [weak self] in
                guard let self, let presenter = self.presenter else {
                    continuation.resume(returning: nil); return
                }
                // A VC already presenting something cannot also present this
                // alert; treat that as presentation being impossible rather
                // than leaving the continuation to hang.
                let topmost = topmostVaultPresentedViewController(from: presenter)
                guard topmost.presentedViewController == nil else {
                    continuation.resume(returning: nil); return
                }
                let resume = VaultOneShotResume(continuation)
                let alert = VaultConfirmAlertController(title: "Confirm your Mac",
                    message: "Compare this fingerprint on both devices:\n\n\(fingerprint)\n\nEndpoint: \(endpointBinding)",
                    preferredStyle: .alert)
                // A dismissal with neither button tapped — the presenting
                // screen disappearing out from under the alert — must still
                // resolve the continuation instead of hanging the caller.
                alert.onDisappear = { resume.resume(returning: nil) }
                alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in
                    resume.resume(returning: nil)
                })
                alert.addAction(UIAlertAction(title: "Fingerprints Match", style: .default) { [weak self] _ in
                    if let self {
                        _ = self.lock.withLock {
                            self.confirmedBindings.insert("\(fingerprint)|\(endpointBinding)")
                        }
                    }
                    resume.resume(returning: VaultMacServerIdentityConfirmation(
                        fingerprint: fingerprint, endpointBinding: endpointBinding))
                })
                topmost.present(alert, animated: true)
            }
        }
    }
}

/// Resumes a checked continuation exactly once. Both a button action and a
/// disappearance callback race to resolve the same confirmation; only the
/// first resume must take effect.
private final class VaultOneShotResume<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Never>?

    init(_ continuation: CheckedContinuation<T, Never>) { self.continuation = continuation }

    func resume(returning value: T) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
    }
}

/// An alert that reports its own disappearance, so a confirmation flow can
/// resolve even when the alert is dismissed without either action firing.
@MainActor
private final class VaultConfirmAlertController: UIAlertController {
    var onDisappear: (() -> Void)?

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        onDisappear?()
    }
}

@MainActor
private func topmostVaultPresentedViewController(from root: UIViewController) -> UIViewController {
    var top = root
    while let presented = top.presentedViewController { top = presented }
    return top
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T { lock(); defer { unlock() }; return body() }
}
