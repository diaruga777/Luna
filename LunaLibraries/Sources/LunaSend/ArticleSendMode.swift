//
//  ArticleSendMode.swift
//  Luna
//

import Foundation
import LunaModels

/// When a destination sends articles automatically.
/// Shared by every destination's settings.
public enum ArticleSendMode: String, CaseIterable {
    /// Never send automatically (long-press / explicit send still works).
    case off
    /// Every saved article is sent once it's ingested.
    case allSaves
    /// Pressing save twice within a few seconds sends that article.
    case doubleSave

    public var displayName: String {
        switch self {
        case .off: return L10n.string("Reader_export_sendModeOffTitle")
        case .allSaves: return L10n.string("Reader_export_sendModeAllSavesTitle")
        case .doubleSave: return L10n.string("Reader_export_sendModeDoubleSaveTitle")
        }
    }
}
