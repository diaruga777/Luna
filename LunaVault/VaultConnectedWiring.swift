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
            importHandler: { files.importFile() }, openHandler: { files.open($0) },
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

@MainActor private final class VaultConnectedFilePresenter: NSObject, UIDocumentPickerDelegate, QLPreviewControllerDataSource {
    let runtime: VaultConnectedRuntime
    weak var presenter: VaultSyncthingHomeViewController?
    private var previewURL: URL?
    init(runtime: VaultConnectedRuntime) { self.runtime = runtime }
    func importFile() {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        picker.delegate = self
        presenter?.present(picker, animated: true)
    }
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        Task {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            do { try await runtime.importFile(at: url); presenter?.refresh() }
            catch { show(error) }
        }
    }
    func open(_ name: String) {
        Task {
            do {
                let source = try await runtime.fileURL(named: name)
                // Quick Look needs the original extension; the cache uses hashed names.
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent("VaultPreview-\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let target = directory.appendingPathComponent((name as NSString).lastPathComponent)
                try FileManager.default.copyItem(at: source, to: target)
                if let previewURL { try? FileManager.default.removeItem(at: previewURL.deletingLastPathComponent()) }
                previewURL = target
                let preview = QLPreviewController(); preview.dataSource = self
                presenter?.present(preview, animated: true)
            } catch { show(error) }
        }
    }
    func numberOfPreviewItems(in controller: QLPreviewController) -> Int { previewURL == nil ? 0 : 1 }
    func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> any QLPreviewItem { previewURL! as NSURL }
    private func show(_ error: Error) {
        let alert = UIAlertController(title: "Vault", message: String(describing: error), preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default)); presenter?.present(alert, animated: true)
    }
}
