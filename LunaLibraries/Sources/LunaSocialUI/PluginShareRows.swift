//
//  PluginShareRows.swift
//  LunaSocialUI
//

import LunaModels
import UIKit

public extension ReaderShareSheet {

    /// One row per export plugin that handles this save's kind and is
    /// configured (`claudedocs/plans/plugin-platform.md` §9.3).
    ///
    /// The rows arrive as VALUES through `PluginExportSeams`, and the mapping
    /// lives here because all three share menus that show them — the reader's
    /// sheet, the media card's, the product card's — compile into apps that
    /// link no plugin module. An app without the export tier gets an empty
    /// list, since nothing filled the seam.
    ///
    /// Reading the rows is free of the main actor — every share menu is built
    /// where it stands — while RUNNING an export hops to it, because the stage
    /// presents from the app's own presenter.
    static func pluginRows(forSaveID saveID: UUID, kind: PluginModelKind) -> [Row] {
        guard let provider = PluginExportSeams.rows else { return [] }
        return provider.exportRows(forSaveID: saveID, kind: kind).map { spec in
            .action(
                title: spec.title, systemImage: spec.symbolName,
                statusDotColor: spec.isLive.map { $0 ? .systemGreen : .tertiaryLabel }
            ) {
                Task { @MainActor in
                    provider.runExport(pluginID: spec.pluginID, saveID: saveID)
                }
            }
        }
    }

    /// The same rows as menu elements, for a card whose share circle presents a
    /// `UIMenu` rather than this sheet.
    static func pluginMenuElements(
        forSaveID saveID: UUID, kind: PluginModelKind
    ) -> [UIMenuElement] {
        pluginRows(forSaveID: saveID, kind: kind).map { row in
            UIAction(title: row.title, image: UIImage(systemName: row.systemImage)) { _ in
                guard case .tap(let action) = row.behavior else { return }
                action()
            }
        }
    }
}
