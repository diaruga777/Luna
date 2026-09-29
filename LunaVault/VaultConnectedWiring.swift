import BackgroundTasks
import UIKit
import QuickLook
import UniformTypeIdentifiers
import LunaVaultBEP
import LunaVaultStore
import LunaVaultTailscale
import LunaVaultUI

@MainActor enum VaultConnectedWiring {
    private static var runtime: VaultConnectedRuntime?
    private static var initializationError: Error?
    private static var foregroundTask: Task<Void, Never>?
    private static var presenter: VaultConnectedFilePresenter?
    private static var transfers: VaultTransferController?
    private static var incomingQueue: VaultIncomingQueue?
    private static weak var home: VaultSyncthingHomeViewController?

    static func install() {
        do {
            let store = try VaultFolderStore.production()
            // System networking also reaches a separately installed Tailscale client.
            let transport = LunaVaultGoTransport(configuration: .init(stateDirectory: store.identityDirectory, requestLocalNetworkAccess: true))
            let connectedRuntime = try VaultConnectedRuntime(store: store, dialer: transport, lookup: transport, localID: transport.identity())
            runtime = connectedRuntime
            let queue = try VaultIncomingQueue.production()
            incomingQueue = queue
            transfers = VaultTransferController(runtime: connectedRuntime, queue: queue,
                bundleID: Bundle.main.bundleIdentifier ?? "com.hsanabria.luna.vault")
        } catch { initializationError = error }
    }

    static func makeRootViewController() -> UIViewController {
        guard let runtime else {
            let controller = UIViewController(); controller.title = "Luna Vault"
            controller.view.backgroundColor = .systemBackground
            let label = UILabel(); label.numberOfLines = 0
            label.text = "Vault could not open its local storage.\n\n\(initializationError.map(String.init(describing:)) ?? "Unknown error")"
            label.frame = CGRect(x: 24, y: 120, width: 320, height: 300)
            controller.view.addSubview(label)
            return controller
        }
        guard let transfers, let incomingQueue else { return UIViewController() }
        let files = VaultConnectedFilePresenter(runtime: runtime, queue: incomingQueue, transfers: transfers)
        let root = VaultSyncthingHomeViewController(runtime: runtime,
            importHandler: { files.importFile() }, importFolderHandler: { files.importFolder() },
            importPhotosHandler: { files.importPhotos() }, importPhotoAlbumHandler: { files.importPhotoAlbum() },
            openHandler: { files.open($0) }, macOpenHandler: { files.open($0, macFile: true) },
            settingsController: { settingsController(runtime: runtime) })
        files.presenter = root; presenter = files; home = root
        transfers.didChange = { [weak root] in root?.refresh() }
        transfers.start()
        applicationWillEnterForeground()
        return root
    }

    static func pairingController(code: String) -> UIViewController? {
        runtime.map { settingsController(runtime: $0, prefilledCode: code) }
    }

    private static func settingsController(runtime: VaultConnectedRuntime, prefilledCode: String? = nil) -> UIViewController {
        VaultConnectedSettingsViewController(services: runtime, prefilledCode: prefilledCode) { code in
            try await runtime.pair(code: code)
            await MainActor.run { transfers?.start() }
        }
    }

    static func applicationWillEnterForeground() {
        transfers?.resumeFromUserOpen()
        guard foregroundTask == nil, let runtime else { return }
        foregroundTask = Task {
            while !Task.isCancelled {
                await runtime.reconnect()
                transfers?.start()
                home?.refresh()
                do { try await Task.sleep(for: .seconds(60)) } catch { break }
            }
        }
    }
    static func applicationDidEnterBackground() {
        foregroundTask?.cancel(); foregroundTask = nil
        if transfers?.isRunning != true, let runtime { Task { await runtime.stop() } }
    }
    static func handleSyncBackgroundTask(_ task: BGTask) {
        guard let transfers else { task.setTaskCompleted(success: false); return }
        transfers.handle(task)
    }
    static func handleMaintenanceBackgroundTask(_ task: BGTask, kind: VaultBackgroundTaskKind) {
        guard let runtime else { task.setTaskCompleted(success: false); return }
        let work = Task {
            do { try await runtime.rebuildIndex(); task.setTaskCompleted(success: !Task.isCancelled) }
            catch { task.setTaskCompleted(success: false) }
        }
        task.expirationHandler = { work.cancel() }
    }
}

@MainActor private final class VaultConnectedFilePresenter: NSObject, UIDocumentPickerDelegate, QLPreviewControllerDataSource, @preconcurrency QLPreviewControllerDelegate {
    let runtime: VaultConnectedRuntime
    let queue: VaultIncomingQueue
    let transfers: VaultTransferController
    private let photos = VaultPhotoSelectionCoordinator()
    weak var presenter: VaultSyncthingHomeViewController?
    private var previewURL: URL?
    private var work: Task<Void, Never>?
    private var progressTask: Task<Void, Never>?
    private weak var progress: UIViewController?
    private var visiblePresenter: UIViewController? { presenter?.navigationController?.topViewController ?? presenter }
    init(runtime: VaultConnectedRuntime, queue: VaultIncomingQueue, transfers: VaultTransferController) {
        self.runtime = runtime; self.queue = queue; self.transfers = transfers
        super.init()
        photos.onExportStart = { [weak self] in self?.transfers.beginIntake() }
    }

    func importFile() {
        guard work == nil else { return }
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: false)
        picker.allowsMultipleSelection = true
        picker.delegate = self
        visiblePresenter?.present(picker, animated: true)
    }
    func importFolder() {
        guard work == nil else { return }
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
        picker.delegate = self
        visiblePresenter?.present(picker, animated: true)
    }
    func importPhotos() { presentPhotos(album: false) }
    func importPhotoAlbum() { presentPhotos(album: true) }

    private func presentPhotos(album: Bool) {
        guard let presenter = visiblePresenter else { return }
        do {
            let settings = try runtime.store.settings()
            photos.imageFormat = settings.photoImageFormat
            photos.videoFormat = settings.photoVideoFormat
        } catch { show(error, title: "Couldn’t Load Photo Settings"); return }
        let root = queue.rootURL.appendingPathComponent(".photo-export-" + UUID().uuidString, isDirectory: true)
        let completion: VaultPhotoSelectionCoordinator.Completion = { [weak self] result in
            guard let self else { return }
            defer { self.transfers.endIntake(); try? FileManager.default.removeItem(at: root) }
            switch result {
            case .success(let files):
                do {
                    for file in files {
                        try queue.enqueueFile(at: file.stagedURL, relativeName: file.relativeName,
                                              isDirectory: file.isDirectory)
                    }
                    self.transfers.start()
                    self.presenter?.refresh()
                } catch { self.show(error, title: "Photos Not Queued") }
            case .failure(let error):
                if case VaultPhotoSelectionError.cancelled = error { break }
                self.show(error, title: "Photos Not Queued")
            }
        }
        if album { photos.presentAlbumPicker(from: presenter, destinationRootURL: root, completion: completion) }
        else { photos.presentItemPicker(from: presenter, destinationRootURL: root, completion: completion) }
    }
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard !urls.isEmpty else { return }
        // Dismiss the picker before presenting progress or an error.
        controller.dismiss(animated: true) { [weak self] in self?.startImport(urls) }
    }
    private func startImport(_ urls: [URL]) {
        guard work == nil else { return }
        transfers.beginIntake()
        showProgress(title: "Queuing", filename: urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) items")
        work = Task {
            do {
                let preparation = Task.detached(priority: .userInitiated) { [queue] in
                    for url in urls {
                        try Task.checkCancellation()
                        let access = url.startAccessingSecurityScopedResource()
                        defer { if access { url.stopAccessingSecurityScopedResource() } }
                        let rootValues = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                        guard rootValues.isSymbolicLink != true else { throw CocoaError(.fileReadUnsupportedScheme) }
                        let isFolder = rootValues.isDirectory == true
                        if isFolder {
                            _ = try queue.enqueueDirectory(relativeName: url.lastPathComponent.precomposedStringWithCanonicalMapping)
                            let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
                            while let file = enumerator?.nextObject() as? URL {
                                try Task.checkCancellation()
                                let relative = url.lastPathComponent + "/" + file.path.dropFirst(url.path.count + 1)
                                let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey])
                                if values.isSymbolicLink == true { enumerator?.skipDescendants(); continue }
                                if values.isDirectory == true {
                                    _ = try queue.enqueueDirectory(relativeName: relative.precomposedStringWithCanonicalMapping)
                                } else if values.isRegularFile == true {
                                    _ = try queue.enqueueFile(at: file, relativeName: relative.precomposedStringWithCanonicalMapping)
                                }
                            }
                        } else { _ = try queue.enqueueFile(at: url, relativeName: url.lastPathComponent.precomposedStringWithCanonicalMapping) }
                    }
                }
                try await withTaskCancellationHandler {
                    try await preparation.value
                    try Task.checkCancellation()
                } onCancel: { preparation.cancel() }
                await hideProgress()
                presenter?.refresh()
                UIAccessibility.post(notification: .announcement, argument: "Queued for sync to your Mac")
            } catch {
                await hideProgress()
                presenter?.refresh()
                if !Task.isCancelled, !(error is CancellationError) { show(error, title: "Import Not Complete") }
            }
            transfers.endIntake()
            transfers.start()
            work = nil
        }
    }
    func open(_ name: String, macFile: Bool = false) {
        guard work == nil else { return }
        showProgress(title: "Opening File", filename: (name as NSString).lastPathComponent)
        work = Task {
            var prepared: URL?
            do {
                if macFile {
                    let target = try await runtime.macFileURL(path: name)
                    prepared = target
                    try Task.checkCancellation()
                    await hideProgress()
                    try Task.checkCancellation()
                    removePreview(); previewURL = target
                    let preview = QLPreviewController(); preview.dataSource = self; preview.delegate = self
                    visiblePresenter?.present(preview, animated: true)
                    work = nil
                    return
                }
                let source = try await runtime.fileURL(named: name)
                try Task.checkCancellation()
                // Quick Look needs the original extension; the durable cache uses
                // hashed filenames. A hard link preserves the complete downloaded
                // file without copying gigabytes into the preview directory.
                let preparation = Task.detached(priority: .userInitiated) {
                    try Task.checkCancellation()
                    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("VaultPreview-\(UUID().uuidString)")
                    do {
                        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                        let target = directory.appendingPathComponent((name as NSString).lastPathComponent)
                        do { try FileManager.default.linkItem(at: source, to: target) }
                        catch { try FileManager.default.copyItem(at: source, to: target) }
                        try Task.checkCancellation()
                        return target
                    } catch { try? FileManager.default.removeItem(at: directory); throw error }
                }
                let target = try await withTaskCancellationHandler {
                    try await preparation.value
                } onCancel: { preparation.cancel() }
                prepared = target
                try Task.checkCancellation()
                await hideProgress()
                try Task.checkCancellation()
                removePreview()
                previewURL = target
                let preview = QLPreviewController(); preview.dataSource = self; preview.delegate = self
                visiblePresenter?.present(preview, animated: true)
            } catch {
                if let prepared { try? FileManager.default.removeItem(at: prepared.deletingLastPathComponent()) }
                await hideProgress()
                if !Task.isCancelled { show(error, title: "Couldn’t Open File") }
            }
            work = nil
        }
    }
    private func showProgress(title: String, filename: String) {
        progressTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard let self, !Task.isCancelled else { return }
            let controller = UIViewController()
            controller.title = title
            controller.view.backgroundColor = .systemBackground
            var loading = UIContentUnavailableConfiguration.loading()
            loading.text = filename
            loading.secondaryText = title == "Opening File" ? "Downloading from your Mac…" : "Preparing files for sync to your Mac."
            controller.contentUnavailableConfiguration = loading
            controller.navigationItem.leftBarButtonItem = UIBarButtonItem(title: "Cancel", primaryAction: UIAction { [weak self] _ in
                self?.work?.cancel()
                self?.progress?.dismiss(animated: true)
                self?.progress = nil
                self?.presenter?.refresh()
            })
            let navigation = UINavigationController(rootViewController: controller)
            navigation.isModalInPresentation = true
            navigation.sheetPresentationController?.detents = [.medium()]
            progress = navigation
            visiblePresenter?.present(navigation, animated: true)
        }
    }
    private func hideProgress() async {
        progressTask?.cancel(); progressTask = nil
        guard let progress, progress.presentingViewController != nil else { return }
        await withCheckedContinuation { continuation in progress.dismiss(animated: true) { continuation.resume() } }
        self.progress = nil
    }
    private func removePreview() {
        if let previewURL { try? FileManager.default.removeItem(at: previewURL.deletingLastPathComponent()) }
        previewURL = nil
    }
    func previewControllerDidDismiss(_ controller: QLPreviewController) { removePreview() }
    func numberOfPreviewItems(in controller: QLPreviewController) -> Int { previewURL == nil ? 0 : 1 }
    func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> any QLPreviewItem { previewURL! as NSURL }
    private func show(_ error: Error, title: String) {
        let alert = UIAlertController(title: title, message: error.localizedDescription, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        visiblePresenter?.present(alert, animated: true)
    }
}
