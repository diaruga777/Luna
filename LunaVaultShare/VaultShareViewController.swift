import UIKit
import UniformTypeIdentifiers
import BackgroundTasks

/// Copies shared files into the App Group before returning to the source app.
/// The containing app drains this durable inbox and owns the Mac connection.
final class VaultShareViewController: UIViewController {
    private var saving = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        showReady()
    }

    private func showReady() {
        var content = UIContentUnavailableConfiguration.empty()
        content.image = UIImage(systemName: "externaldrive.badge.plus")
        content.text = "Add to Luna Vault"
        content.secondaryText = "Files are copied into Vault's queue, then synced to your paired Mac when Vault runs."
        content.button = .filled()
        content.button.title = "Add Files"
        content.buttonProperties.primaryAction = UIAction { [weak self] _ in self?.save() }
        content.secondaryButton = .plain()
        content.secondaryButton.title = "Cancel"
        content.secondaryButtonProperties.primaryAction = UIAction { [weak self] _ in
            self?.extensionContext?.cancelRequest(withError: CocoaError(.userCancelled))
        }
        contentUnavailableConfiguration = content
    }

    private func save() {
        guard !saving else { return }
        saving = true
        var loading = UIContentUnavailableConfiguration.loading()
        loading.text = "Copying to Vault"
        loading.secondaryText = "Keep this sheet open until the files are queued."
        contentUnavailableConfiguration = loading
        let providers = (extensionContext?.inputItems as? [NSExtensionItem])?.flatMap { $0.attachments ?? [] } ?? []
        Task {
            var count = 0
            do {
                let queue = try VaultIncomingQueue.production()
                for provider in providers {
                    try await copy(provider, to: queue)
                    count += 1
                }
                guard count > 0 else { throw CocoaError(.fileReadUnsupportedScheme) }
                let started = submitTransferRequest()
                var done = UIContentUnavailableConfiguration.empty()
                done.image = UIImage(systemName: "checkmark.circle.fill")
                done.text = count == 1 ? "File queued" : "\(count) files queued"
                done.secondaryText = started ? "Vault is syncing these files to your Mac in the background." : "Open Luna Vault to resume syncing to your Mac."
                done.button = .filled()
                done.button.title = "Done"
                done.buttonProperties.primaryAction = UIAction { [weak self] _ in
                    self?.extensionContext?.completeRequest(returningItems: nil)
                }
                contentUnavailableConfiguration = done
            } catch {
                if count > 0 { _ = submitTransferRequest() }
                var failed = UIContentUnavailableConfiguration.empty()
                failed.image = UIImage(systemName: "exclamationmark.triangle")
                failed.text = count > 0 ? "\(count) files queued" : "Couldn’t queue files"
                failed.secondaryText = count > 0
                    ? "One item couldn’t be copied: \(error.localizedDescription) The queued files will still sync."
                    : error.localizedDescription
                failed.button = .filled()
                failed.button.title = "Done"
                failed.buttonProperties.primaryAction = UIAction { [weak self] _ in
                    if count > 0 { self?.extensionContext?.completeRequest(returningItems: nil) }
                    else { self?.extensionContext?.cancelRequest(withError: error) }
                }
                contentUnavailableConfiguration = failed
            }
            saving = false
        }
    }

    private func submitTransferRequest() -> Bool {
        guard #available(iOS 26.0, *), let bundleID = Bundle.main.bundleIdentifier else { return false }
        let request = BGContinuedProcessingTaskRequest(
            identifier: bundleID + ".transfer." + UUID().uuidString,
            title: "Syncing to Mac", subtitle: "Preparing shared files")
        request.strategy = .queue
        do { try BGTaskScheduler.shared.submit(request); return true }
        catch { return false }
    }

    private func copy(_ provider: NSItemProvider, to queue: VaultIncomingQueue) async throws {
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            if let url = try? await provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) as? URL,
               url.isFileURL {
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                _ = try queue.enqueueFile(at: url, relativeName: url.lastPathComponent)
                return
            }
        }
        let type = provider.registeredTypeIdentifiers.first {
            guard let value = UTType($0) else { return false }
            return value.conforms(to: .data) || value.conforms(to: .content)
        }
        guard let type else { throw CocoaError(.fileReadUnsupportedScheme) }
        let suggestedName = provider.suggestedName
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            provider.loadFileRepresentation(forTypeIdentifier: type) { url, error in
                do {
                    if let error { throw error }
                    guard let url else { throw CocoaError(.fileNoSuchFile) }
                    let ext = UTType(type)?.preferredFilenameExtension ?? url.pathExtension
                    let suggested = suggestedName ?? url.deletingPathExtension().lastPathComponent
                    let filename = (suggested as NSString).pathExtension.isEmpty && !ext.isEmpty
                        ? suggested + "." + ext : suggested
                    _ = try queue.enqueueFile(at: url, relativeName: filename)
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
}

private extension NSItemProvider {
    func loadItem(forTypeIdentifier identifier: String) async throws -> NSSecureCoding {
        try await withCheckedThrowingContinuation { continuation in
            loadItem(forTypeIdentifier: identifier, options: nil) { value, error in
                if let error { continuation.resume(throwing: error) }
                else if let value { continuation.resume(returning: value) }
                else { continuation.resume(throwing: CocoaError(.fileNoSuchFile)) }
            }
        }
    }
}
