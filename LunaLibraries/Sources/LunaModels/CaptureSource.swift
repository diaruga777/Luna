//
//  CaptureSource.swift
//  Luna
//

import Foundation

/// Where a reading-list item was captured from. Drives per-source auto-send
/// configuration — each ereader destination can auto-send some sources and not
/// others. Stored on `ReadingListItem`; absent on legacy items, which are
/// treated as `.manual`.
public enum CaptureSource: String, Codable, CaseIterable {
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
    public var displayName: String {
        switch self {
        case .email: return L10n.string("Common_email")
        case .appIntent: return L10n.string("CaptureSource_appIntents")
        case .friendShare: return L10n.string("CaptureSource_savesFromContacts")
        case .shareSheet: return L10n.string("CaptureSource_shareSheet")
        case .paste: return L10n.string("CaptureSource_paste")
        case .manual: return L10n.string("CaptureSource_inAppSaves")
        }
    }
}
