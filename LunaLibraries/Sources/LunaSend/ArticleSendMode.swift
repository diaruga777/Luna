//
//  ArticleSendMode.swift
//  Luna
//

import Foundation

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
        case .off: return "Off"
        case .allSaves: return "All Saved Articles"
        case .doubleSave: return "Double Save"
        }
    }
}
