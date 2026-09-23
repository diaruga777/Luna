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
    private static weak var home: VaultSyncthingHomeViewController?

    static func install() {
        do {
            let store = try VaultFolderStore.production()
            // System networking also reaches a separately installed Tailscale client.
            let transport = LunaVaultGoTransport(configuration: .init(stateDirectory: store.identityDirectory, requestLocalNetworkAccess: true))
            runtime = try VaultConnectedRuntime(store: store, dialer: transport, lookup: transport, localID: transport.identity())
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
        let files = VaultConnectedFilePresenter(runtime: runtime)
        let root = VaultSyncthingHomeViewController(runtime: runtime,
            importHandler: { files.importFile() }, importFolderHandler: { files.importFolder() },
            openHandler: { files.open($0) },
            settingsController: { VaultConnectedSettingsViewController(runtime: runtime) })
        files.presenter = root; presenter = files; home = root
        applicationWillEnterForeground()
        return root
    }

    static func pairingController(code: String) -> UIViewController? {
        runtime.map { VaultConnectedSettingsViewController(runtime: $0, prefilledCode: code) }
    }

    static func applicationWillEnterForeground() {
        guard foregroundTask == nil, let runtime else { return }
        foregroundTask = Task {
            while !Task.isCancelled {
                await runtime.reconnect()
                home?.refresh()
                do { try await Task.sleep(for: .seconds(60)) } catch { break }
            }
        }
    }
    static func applicationDidEnterBackground() {
        foregroundTask?.cancel(); foregroundTask = nil
        if let runtime { Task { await runtime.stop() } }
    }
    static func handleSyncBackgroundTask(_ task: BGTask) {
        guard let runtime else { task.setTaskCompleted(success: false); return }
        let work = Task {
            await runtime.reconnect()
            let status = await runtime.connectionStatus()
            task.setTaskCompleted(success: !Task.isCancelled && status == .connected)
        }
        task.expirationHandler = { work.cancel() }
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
    weak var presenter: VaultSyncthingHomeViewController?
    private var previewURL: URL?
    private var work: Task<Void, Never>?
    private var progressTask: Task<Void, Never>?
    private weak var progress: UIViewController?
    private var visiblePresenter: UIViewController? { presenter?.navigationController?.topViewController ?? presenter }
    init(runtime: VaultConnectedRuntime) { self.runtime = runtime }

    func importFile() {
        guard work == nil else { return }
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: false)
        picker.delegate = self
        visiblePresenter?.present(picker, animated: true)
    }
    func importFolder() {
        guard work == nil else { return }
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
        picker.delegate = self
        visiblePresenter?.present(picker, animated: true)
    }
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        // Dismiss the picker before presenting progress or an error.
        controller.dismiss(animated: true) { [weak self] in self?.startImport(url) }
    }
    private func startImport(_ url: URL) {
        guard work == nil else { return }
        showProgress(title: "Importing", filename: url.lastPathComponent)
        work = Task {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            do {
                let isFolder = try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
                let names: [String]
                if isFolder { names = try await runtime.importFolder(at: url) }
                else { try await runtime.importFile(at: url); names = [url.lastPathComponent.precomposedStringWithCanonicalMapping] }
                await hideProgress()
                presenter?.refresh()
                try await runtime.waitForUpload(names: names)
                presenter?.refresh()
                UIAccessibility.post(notification: .announcement, argument: "Saved on your Mac")
            } catch {
                await hideProgress()
                presenter?.refresh()
                if !Task.isCancelled, !(error is CancellationError) { show(error, title: "Import Not Complete") }
            }
            work = nil
        }
    }
    func open(_ name: String) {
        guard work == nil else { return }
        showProgress(title: "Opening File", filename: (name as NSString).lastPathComponent)
        work = Task {
            var prepared: URL?
            do {
                let source = try await runtime.fileURL(named: name)
                try Task.checkCancellation()
                // Copy potentially large files away from the main actor. Quick Look needs
                // the original extension; the durable cache uses hashed filenames.
                let target = try await Task.detached(priority: .userInitiated) {
                    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("VaultPreview-\(UUID().uuidString)")
                    do {
                        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                        let target = directory.appendingPathComponent((name as NSString).lastPathComponent)
                        try FileManager.default.copyItem(at: source, to: target)
                        return target
                    } catch { try? FileManager.default.removeItem(at: directory); throw error }
                }.value
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
            loading.secondaryText = "Preparing a local copy. Keep Vault open."
            controller.contentUnavailableConfiguration = loading
            controller.navigationItem.leftBarButtonItem = UIBarButtonItem(title: "Hide", primaryAction: UIAction { [weak self] _ in
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
