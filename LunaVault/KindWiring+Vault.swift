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
    /// The host owns import implementation. The UI only exposes the seam.
    static var importHandler: (() -> Void)?
    /// The host owns preview/rendering. The UI only forwards canonical IDs.
    static var openHandler: ((VaultObjectID) -> Void)?
    /// Optional host handoff for the one-use enrollment material. The UI also
    /// keeps a visible copy/share/export affordance for the user.
    static var enrollmentPreparedHandler: ((VaultMacPairingEnrollment) -> Void)?
    static var storagePolicyChangedHandler: ((VaultStoragePolicy) -> Void)?
    static var credentialSavedHandler: ((VaultMacPairingCredential) -> Void)?
    static var credentialUnpairedHandler: ((VaultMacRemoteRevocationOutcome) -> Void)?

    static func install() {
        _ = setupCoordinator.load()
        _ = makeServices()
    }

    static func applicationDidEnterBackground() {
        syncRuntime?.applicationDidEnterBackground()
        for kind in [VaultBackgroundTaskKind.importRepair, .index, .thumbnailMaintenance] {
            _ = try? backgroundScheduler?.schedule(kind: kind)
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
            importHandler: importHandler ?? { [weak importer] in importer?.present() },
            openHandler: openHandler ?? { [weak opener] objectID in opener?.open(objectID) },
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
            storagePolicyChanged: { storagePolicyChangedHandler?($0) },
            clearCache: {
                guard let value = services ?? makeServices() else {
                    throw VaultRuntimeError.providerUnavailable
                }
                try value.repository.evictExpired()
            },
            rebuildIndex: {
                guard let index = makeSearchIndex() else {
                    throw VaultSearchError.sqlite("Vault index is unavailable")
                }
                try index.rebuild()
            },
            requestICloudEviction: requestICloudEviction,
            reconfigureRuntime: {
                invalidateRuntime()
                _ = makeServices()
            },
            enrollmentPrepared: { enrollmentPreparedHandler?($0) },
            credentialSaved: { credentialSavedHandler?($0) },
            revokeMacCredential: { _ in
                // Vault's wire protocol has no unauthenticated revoke call.
                // Drop the local runtime immediately; the UI reports the
                // remote operation as local-only and instructs the user to
                // revoke the companion before pairing again.
                invalidateRuntime()
                return .localOnly(reason: "The paired Mac must be revoked from its companion process.")
            },
            credentialUnpaired: { credentialUnpairedHandler?($0) }
        )
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
        guard let accessGroup = Bundle.main.object(forInfoDictionaryKey: "LunaVaultKeychainAccessGroup") as? String,
              !accessGroup.isEmpty else { throw VaultMacProtocolError.unavailable }
        let store = VaultMacKeychainCredentialStore(accessGroup: accessGroup,
            service: "\(Bundle.main.bundleIdentifier ?? "com.hsanabria.luna.vault").mac-pairing")
        return try store.load()
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
                repository: services.repository, metadataStore: metadata)
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
            for kind in [VaultBackgroundTaskKind.importRepair, .index, .thumbnailMaintenance] {
                try? scheduler.registerWithSystemScheduler(kind: kind)
            }
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
        let repository = try VaultRepository()
        let device = VaultDeviceBackend(store: repository)
        let backend: (any VaultBackendTransport)?
        if let credential, credential.revokedAt == nil {
            backend = try VaultMacRemoteBackend(
                endpoint: VaultMacEndpoint(binding: credential.endpointBinding),
                credential: credential, connector: VaultMacNWConnector(),
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
            runtimeIdentity: runtimeIdentity)
    }

    private static func makeSearchIndex() -> VaultSearchIndex? {
        guard let container = AppConfig.sharedContainerURL() else { return nil }
        return try? VaultSearchIndex(databaseURL: container.appendingPathComponent("vault-index.sqlite"))
    }

    private static func requestICloudEviction() async -> VaultICloudLocalState {
        guard let value = services ?? makeServices(),
              value.policy.location == .iCloud,
              let backend = value.remoteBackend as? VaultICloudBackend,
              let identity = remoteIdentity(for: value) else { return .unavailable }
        do {
            switch try await backend.evictionOutcome(for: identity) {
            case .evicted: return .evicted
            case .pending: return .evictionRequested
            case .notEvictable: return .unavailable
            }
        } catch {
            return .failed
        }
    }

    private static func remoteIdentity(for services: VaultRuntimeServices)
        -> VaultRemoteObjectIdentity? {
        guard let backend = services.remoteBackend else { return nil }
        let jobs = (try? services.repository.jobs()) ?? []
        for job in jobs.sorted(by: { $0.updatedAt > $1.updatedAt }) {
            guard job.backendKey == backend.identity.stableKey,
                  job.kind == .download || job.kind == .upload,
                  let objectID = job.objectID,
                  let revision = job.revision,
                  let generation = job.payloadGeneration,
                  let rawKind = job.remoteObjectKind,
                  let kind = VaultRemoteObjectKind(rawValue: rawKind) else { continue }
            return try? VaultRemoteObjectIdentity(objectID: objectID, revision: revision,
                                                   kind: kind, generation: generation)
        }
        return nil
    }
}

/// The UI owns only the import button. This host object owns the document
/// picker lease and hands the selected URL to the protected import coordinator.
@MainActor
private final class VaultDocumentImportPresenter: NSObject, UIDocumentPickerDelegate {
    weak var presenter: UIViewController?
    private let coordinatorProvider: () -> VaultImportCoordinator?
    private var picker: UIDocumentPickerViewController?

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

    func documentPicker(_ controller: UIDocumentPickerViewController,
                        didPickDocumentsAt urls: [URL]) {
        picker = nil
        guard let url = urls.first, let coordinator = coordinatorProvider(),
              let presenter else { return }
        do {
            let contentType = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
            _ = try coordinator.importFile(VaultImportSource(
                fileURL: url, fileName: url.lastPathComponent, contentType: contentType))
            (presenter as? VaultRootViewController)?.refresh()
        } catch {
            showError(on: presenter, message: "The file could not be imported. Check its size and try again.")
        }
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        picker = nil
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
        let identity = services.flatMap { Self.remoteIdentity(for: objectID, services: $0) }
        Task { [weak self, weak presenter] in
            do {
                var plan = try await router.plan(objectID: objectID, remoteIdentity: identity)
                if plan.availability == .needsDownload, let identity {
                    plan = try await router.downloadAndPlan(objectID: objectID, identity: identity)
                }
                if let capability = plan.capability {
                    try router.beginPreview(capability)
                    let content = router.makeViewController(for: plan)
                    let session = VaultPreviewSessionViewController(
                        content: content, router: router, capability: capability)
                    await MainActor.run { presenter?.present(session, animated: true) }
                } else {
                    let content = router.makeViewController(for: plan)
                    await MainActor.run { presenter?.present(content, animated: true) }
                }
            } catch {
                await MainActor.run { [weak self, weak presenter] in
                    guard let self, let presenter else { return }
                    self.showStatus(on: presenter, message: "This file could not be opened securely.")
                }
            }
        }
    }

    private static func remoteIdentity(for objectID: VaultObjectID,
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

@MainActor
private final class VaultPreviewSessionViewController: UIViewController {
    private let content: UIViewController
    private let router: VaultPreviewRouter
    private let capability: VaultLocalContentCapability
    private var ended = false

    init(content: UIViewController, router: VaultPreviewRouter,
         capability: VaultLocalContentCapability) {
        self.content = content; self.router = router; self.capability = capability
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        addChild(content)
        content.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(content.view)
        NSLayoutConstraint.activate([
            content.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            content.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            content.view.topAnchor.constraint(equalTo: view.topAnchor),
            content.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        content.didMove(toParent: self)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        guard !ended else { return }
        ended = true
        try? router.endPreview(capability)
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
                let alert = UIAlertController(title: "Confirm your Mac",
                    message: "Compare this fingerprint on both devices:\n\n\(fingerprint)\n\nEndpoint: \(endpointBinding)",
                    preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in
                    continuation.resume(returning: nil)
                })
                alert.addAction(UIAlertAction(title: "Fingerprints Match", style: .default) { [weak self] _ in
                    if let self {
                        _ = self.lock.withLock {
                            self.confirmedBindings.insert("\(fingerprint)|\(endpointBinding)")
                        }
                    }
                    continuation.resume(returning: VaultMacServerIdentityConfirmation(
                        fingerprint: fingerprint, endpointBinding: endpointBinding))
                })
                presenter.present(alert, animated: true)
            }
        }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T { lock(); defer { unlock() }; return body() }
}
