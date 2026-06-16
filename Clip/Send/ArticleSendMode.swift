//
//  ArticleSendMode.swift
//  Clip
//

import Foundation

/// When an ereader destination (Kindle, Boox, …) sends articles automatically.
/// Shared by every destination's settings.
enum ArticleSendMode: String, CaseIterable {
    /// Never send automatically (long-press / explicit send still works).
    case off
    /// Every saved article is sent once it's ingested.
    case allSaves
    /// Pressing save twice within a few seconds sends that article.
    case doubleSave

    var displayName: String {
        switch self {
        case .off: return "Off"
        case .allSaves: return "All Saved Articles"
        case .doubleSave: return "Double Save"
        }
    }
}
