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
        sheet.popoverPresentationController?.sourceView = sourceView
        sheet.popoverPresentationController?.sourceRect = sourceView?.bounds ?? .zero
        presenter.present(sheet, animated: true)
    }

    private func pickFile() {
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: [.javaScript, .plainText], asCopy: true)
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
            if preview.requiresConsent {
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
        alert.addAction(UIAlertAction(title: L10n.string("Common_cancel"), style: .cancel))
        alert.addAction(
            UIAlertAction(title: L10n.string("Plugins_updateConfirmButton"), style: .default) {
                [weak self] _ in self?.install(preview, origin: origin)
            })
        presenter?.present(alert, animated: true)
    }

    private func install(_ preview: PluginImportPreview, origin: PluginImportOrigin) {
        do {
            try importer.install(preview, origin: origin)
            observer?.pluginImportDidFinish(self)
        } catch {
            report(error)
        }
    }

    private func report(_ error: Error) {
        let alert = UIAlertController(
            title: L10n.string("Plugins_importFailedTitle"),
            message: error.localizedDescription, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: L10n.string("Common_ok"), style: .default))
        presenter?.present(alert, animated: true)
    }
}

extension PluginImportCoordinator: UIDocumentPickerDelegate {
    public func documentPicker(
        _ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]
    ) {
        guard let url = urls.first else { return }
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            handle(sourceText: text, origin: .files)
        } catch {
            report(error)
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
        let origin = pendingOrigin ?? .paste
        pendingOrigin = nil
        controller.dismiss(animated: true) { [weak self] in
            guard accepted else { return }
            self?.install(preview, origin: origin)
        }
    }
}
