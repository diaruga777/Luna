//
//  PluginExportSeam.swift
//  LunaModels
//

import Foundation

/// One export plugin's share row, as a share menu sees it
/// (`claudedocs/plans/plugin-platform.md` §9.3).
///
/// It carries no action: a row's tap runs `PluginExportRowProviding.runExport`,
/// so a menu builder never holds work belonging to the export tier.
public struct PluginExportRowSpec: Equatable, Sendable {
    public let pluginID: String
    /// The manifest's `export.title`, e.g. "Send to Kindle".
    public let title: String
    /// The manifest's `export.symbol`, or a kind-appropriate default.
    public let symbolName: String
    /// The status dot a destination row draws: nil for no dot, true for lit.
    /// Fed by the reserved `_status` setting.
    public let isLive: Bool?

    public init(pluginID: String, title: String, symbolName: String, isLive: Bool?) {
        self.pluginID = pluginID
        self.title = title
        self.symbolName = symbolName
        self.isLive = isLive
    }
}

/// Answers "which export plugins does this save's share menu offer, and what
/// happens when one is tapped".
///
/// The rows are VALUES rather than menu elements because the three share menus
/// that show them — the reader's sheet, the media card's, the product card's —
/// compile into apps that do not link the export tier at all. They read this
/// seam; central Luna's `KindWiring` is what fills it.
public protocol PluginExportRowProviding: AnyObject {
    /// The rows for one save, in plugin order. Empty when no loaded plugin
    /// exports this kind or none is configured.
    func exportRows(forSaveID saveID: UUID, kind: PluginModelKind) -> [PluginExportRowSpec]
    /// Runs the plugin's `export` hook for the save and presents whatever it
    /// answers. Presentation is the export tier's own: it resolves the app's
    /// top presenter, because a menu's anchor view is gone by the time the
    /// hook settles.
    @MainActor
    func runExport(pluginID: String, saveID: UUID)
}

/// The export seam, held at the bottom of the stack for the same reason
/// `PluginPriceSeams` is: the three card surfaces sit in app targets that link
/// no plugin module. `PluginExportComposition.install()` is the only writer.
public enum PluginExportSeams {
    public static var rows: (any PluginExportRowProviding)?
}
