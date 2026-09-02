//
//  PluginExportInputAvailability.swift
//  LunaPluginKit
//

import Foundation
import LunaModels

/// Which input formats each save kind can actually be handed to an export hook
/// in (`claudedocs/plans/plugin-platform.md` §9.1).
///
/// The table lives beside the manifest parser because a declaration naming a
/// pair Luna cannot produce is refused at PARSE time — before an import writes
/// anything, and before a bundled plugin loads. `ExportInputProducer` produces
/// exactly these.
public enum PluginExportInputAvailability {

    public static func formats(for kind: PluginModelKind) -> Set<PluginExportInputFormat> {
        switch kind {
        // Every article format comes from a builder LunaSend already ships.
        case .article: return [.url, .epub, .pdf, .docx, .markdown, .text, .html, .json]
        // A media save is a row plus the file it downloaded.
        case .media: return [.url, .json, .file]
        // A tracker is its stores and their price points.
        case .product: return [.url, .json]
        }
    }

    public static func isAvailable(kind: PluginModelKind, format: PluginExportInputFormat) -> Bool {
        formats(for: kind).contains(format)
    }

    /// The kinds in `kinds` that cannot be handed `format`, in declaration
    /// order. Empty means the declaration is producible.
    public static func unsupportedKinds(
        in kinds: [PluginModelKind], format: PluginExportInputFormat
    ) -> [PluginModelKind] {
        kinds.filter { !isAvailable(kind: $0, format: format) }
    }
}
