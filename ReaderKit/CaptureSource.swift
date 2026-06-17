//
//  CaptureSource.swift
//  Clip
//

import Foundation

/// Where a reading-list item was captured from. Drives per-source auto-send
/// configuration — each ereader destination can auto-send some sources and not
/// others. Stored on `ReadingListItem`; absent on legacy items, which are
/// treated as `.manual`.
enum CaptureSource: String, Codable, CaseIterable {
    /// Imported from an allowed email sender.
    case email
    /// Saved via an App Intent / Shortcut (the Action button, Shortcuts app).
    case appIntent
    /// Sent to us by a friend over the social channel.
    case friendShare
    /// Saved through the iOS share sheet (the share extension).
    case shareSheet
    /// Saved from the clipboard (the in-app paste suggestion).
    case paste
    /// Saved directly inside the app (typing a URL, the reader's save button).
    case manual

    /// User-facing label for the auto-send-by-source settings.
    var displayName: String {
        switch self {
        case .email: return "Email"
        case .appIntent: return "App Intents (Shortcuts)"
        case .friendShare: return "Friend Shares"
        case .shareSheet: return "Share Sheet"
        case .paste: return "Paste"
        case .manual: return "In-App Saves"
        }
    }
}
