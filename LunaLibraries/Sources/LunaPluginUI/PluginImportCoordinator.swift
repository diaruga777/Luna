//
//  PluginImportCoordinator.swift
//  LunaPluginUI
//
//  Drives one import from end to end (§11.2): pick a source, preview its
//  header, ask consent when the preview says to, install or drop. The
//  consent screen is not optional decoration on this path — `install` is
//  never called for a declined preview.
//

import LunaModels
import LunaPluginKit
import UIKit
import UniformTypeIdentifiers

/// Told when an import finished (installed), so the caller can reload its list.
public protocol PluginImportObserving: AnyObject {
    func pluginImportDidFinish(_ coordinator: PluginImportCoordinator)
}

public final class PluginImportCoordinator: NSObject {

    private let importer: PluginImporting
    public weak var observer: PluginImportObserving?

    private weak var presenter: UIViewController?
    private var pendingOrigin: PluginImportOrigin?
    private var pendingSources: [String] = []
    private var bundleNavigationController: UINavigationController?
    private var bundleSourceCount = 0
    /// Exposed for the import UI to disable duplicate submissions while the
    /// candidate is being preflighted off the main actor.
    public private(set) var isInstalling = false

    public init(importer: PluginImporting) {
        self.importer = importer
        super.init()
    }

    /// Offers the two ways in: a file in Files, or pasted source.
    public func begin(from presenter: UIViewController, sourceView: UIView?) {
        self.presenter = presenter
        let sheet = UIAlertController(
            title: L10n.string("Plugins_importTitle"), message: nil, preferredStyle: .actionSheet)
        sheet.addAction(
            UIAlertAction(title: L10n.string("Plugins_importFromFiles"), style: .default) {
                [weak self] _ in self?.pickFile()
            })
        sheet.addAction(
            UIAlertAction(title: L10n.string("Plugins_importFromPaste"), style: .default) {
                [weak self] _ in self?.presentPasteSheet()
            })
        sheet.addAction(UIAlertAction(title: L10n.string("Common_cancel"), style: .cancel))
        let anchor = sourceView ?? presenter.view
        sheet.popoverPresentationController?.sourceView = anchor
        sheet.popoverPresentationController?.sourceRect = anchor?.bounds ?? .zero
        presenter.present(sheet, animated: true)
    }

    /// Continues the normal preview/consent/transactional-install flow with a
    /// source that another Luna screen has already collected and validated.
    public func begin(
        sourceText: String, origin: PluginImportOrigin = .paste,
        from presenter: UIViewController
    ) {
        self.presenter = presenter
        pendingSources = []
        handle(sourceText: sourceText, origin: origin)
    }

    private func pickFile() {
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: LunaApp.current.acceptedFileTypeIdentifiers.compactMap { UTType($0) }
                + [UTType(PluginBundleArchive.typeIdentifier) ?? .zip, .zip, .javaScript, .plainText], asCopy: true)
        picker.delegate = self
        picker.allowsMultipleSelection = false
        presenter?.present(picker, animated: true)
    }

    private func presentPasteSheet() {
        let screen = PluginPasteImportViewController()
        screen.delegate = self
        presenter?.present(UINavigationController(rootViewController: screen), animated: true)
    }

    // MARK: - Preview → consent → install

    private func handle(sourceText: String, origin: PluginImportOrigin) {
        do {
            let preview = try importer.preview(sourceText: sourceText)
            if bundleNavigationController != nil,
                preview.requiresConsent || preview.replacesVersion != nil
            {
                presentBundleConsent(preview, origin: origin)
            } else if preview.requiresConsent {
                pendingOrigin = origin
                let screen = PluginConsentViewController(preview: preview)
                screen.delegate = self
                presenter?.present(screen, animated: true)
            } else if let replaces = preview.replacesVersion {
                // No new capability, so the full consent screen would repeat
                // what was already granted — but silently overwriting an
                // installed plugin's entire script left no signal at all that
                // anything happened.
                confirmReplace(preview, replacing: replaces, origin: origin)
            } else {
                install(preview, origin: origin)
            }
        } catch {
            report(error)
        }
    }

    private func confirmReplace(
        _ preview: PluginImportPreview, replacing oldVersion: String, origin: PluginImportOrigin
    ) {
        let alert = UIAlertController(
            title: L10n.string("Plugins_updateConfirmTitle", preview.summary.name),
            message: L10n.string(
                "Plugins_updateConfirmMessage", oldVersion, preview.summary.version),
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: L10n.string("Common_cancel"), style: .cancel) { [weak self] _ in self?.pendingSources = [] })
        alert.addAction(
            UIAlertAction(title: L10n.string("Plugins_updateConfirmButton"), style: .default) {
                [weak self] _ in self?.install(preview, origin: origin)
            })
        presenter?.present(alert, animated: true)
    }

    private func install(_ preview: PluginImportPreview, origin: PluginImportOrigin) {
        guard !isInstalling else { return }
        isInstalling = true
        bundleNavigationController?.isModalInPresentation = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.importer.installAsync(preview, origin: origin)
                self.observer?.pluginImportDidFinish(self)
                self.isInstalling = false
                self.bundleNavigationController?.isModalInPresentation = false
                self.importNextSource()
            } catch {
                self.isInstalling = false
                self.report(error)
            }
        }
    }

    /// Opens either a single source or an entire bundle. Preflight every header
    /// before showing consent, so malformed later members cannot partially import.
    public func begin(fileURL url: URL, from presenter: UIViewController) {
        self.presenter = presenter
        guard !isInstalling else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            if [PluginBundleArchive.fileExtension, "zip"].contains(url.pathExtension.lowercased()) {
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= PluginBundleArchive.maximumBytes else {
                    throw PluginBundleArchive.ArchiveError.invalid("bundle is too large.")
                }
                let file = try FileHandle(forReadingFrom: url)
                defer { try? file.close() }
                let data = try file.read(upToCount: PluginBundleArchive.maximumBytes + 1) ?? Data()
                let sources = try PluginBundleArchive.sources(in: data)
                for source in sources { _ = try importer.preview(sourceText: source) }
                pendingSources = sources
                bundleSourceCount = sources.count
                bundleNavigationController = UINavigationController()
                importNextSource()
            } else {
                pendingSources = []
                handle(sourceText: try LunaFileReader.readText(at: url).get(), origin: .files)
            }
        } catch { report(error) }
    }

    private func importNextSource() {
        guard !pendingSources.isEmpty else {
            finishBundle()
            return
        }
        handle(sourceText: pendingSources.removeFirst(), origin: .files)
    }

    private func presentBundleConsent(_ preview: PluginImportPreview, origin: PluginImportOrigin) {
        guard let navigation = bundleNavigationController else { return }
        pendingOrigin = origin
        navigation.navigationBar.isUserInteractionEnabled = true
        let screen = PluginConsentViewController(preview: preview)
        screen.delegate = self
        screen.title = L10n.string(
            "Plugins_bundleProgress", bundleSourceCount - pendingSources.count, bundleSourceCount)
        screen.navigationItem.largeTitleDisplayMode = .never
        screen.navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .cancel, target: self, action: #selector(cancelBundle))
        // Completed members are already installed; they must not be revisited
        // and installed again through a Back button or an interactive pop.
        navigation.setViewControllers(
            [screen], animated: UIView.areAnimationsEnabled && navigation.presentingViewController != nil)
        if navigation.presentingViewController == nil {
            presenter?.present(navigation, animated: true)
            navigation.presentationController?.delegate = self
        }
    }

    @objc private func cancelBundle() {
        guard !isInstalling else { return }
        finishBundle()
    }

    private func finishBundle(completion: (() -> Void)? = nil) {
        pendingSources = []
        pendingOrigin = nil
        bundleSourceCount = 0
        let navigation = bundleNavigationController
        bundleNavigationController = nil
        if let navigation, navigation.presentingViewController != nil {
            navigation.dismiss(animated: true, completion: completion)
        } else {
            completion?()
        }
    }

    private func report(_ error: Error) {
        let alert = UIAlertController(
            title: L10n.string("Plugins_importFailedTitle"),
            message: error.localizedDescription, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: L10n.string("Common_ok"), style: .default))
        finishBundle { [weak self] in
            self?.presenter?.present(alert, animated: true)
        }
    }
}

extension PluginImportCoordinator: UIAdaptivePresentationControllerDelegate {
    public func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        guard presentationController.presentedViewController === bundleNavigationController else { return }
        finishBundle()
    }
}

extension PluginImportCoordinator: UIDocumentPickerDelegate {
    public func documentPicker(
        _ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]
    ) {
        guard let url = urls.first else { return }
        guard let presenter else { return }
        controller.dismiss(animated: true) { [weak self] in
            self?.begin(fileURL: url, from: presenter)
        }
    }
}

extension PluginImportCoordinator: PluginPasteImportDelegate {
    public func pluginPasteImport(
        _ controller: PluginPasteImportViewController, didSubmit sourceText: String
    ) {
        controller.dismiss(animated: true) { [weak self] in
            self?.handle(sourceText: sourceText, origin: .paste)
        }
    }
}

extension PluginImportCoordinator: PluginConsentDelegate {
    public func pluginConsent(
        _ controller: PluginConsentViewController, didDecide accepted: Bool,
        for preview: PluginImportPreview
    ) {
        guard !isInstalling else { return }
        if let navigation = bundleNavigationController {
            guard controller === navigation.topViewController, let origin = pendingOrigin else { return }
            pendingOrigin = nil
            guard accepted else { finishBundle(); return }
            controller.view.isUserInteractionEnabled = false
            navigation.navigationBar.isUserInteractionEnabled = false
            install(preview, origin: origin)
            return
        }
        let origin = pendingOrigin ?? .paste
        pendingOrigin = nil
        controller.dismiss(animated: true) { [weak self] in
            guard accepted else { self?.pendingSources = []; return }
            self?.install(preview, origin: origin)
        }
    }
}
