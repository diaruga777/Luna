//
//  ShareSheetExperience.swift
//  Clip
//

import Foundation

/// What happens when a link is shared into Click from the system share sheet.
/// Stored in the App Group so the share extension can read it.
enum ShareSheetExperience: String, CaseIterable {
    /// Save silently (current behavior, no UI).
    case off
    /// Open the article in the scrolling reader, scoped to that one article.
    case reader
    /// Open the article in the RSVP speed reader.
    case rsvp
    /// Open the article in the chunk speed reader.
    case chunk

    var displayName: String {
        switch self {
        case .off: return "Save Only"
        case .reader: return "Reader"
        case .rsvp: return "RSVP Speed Reader"
        case .chunk: return "Chunk Speed Reader"
        }
    }

    static let appGroupID = "group.com.hpiddy.clip"
    static let defaultsKey = "shareSheetExperience"

    private static var defaults: UserDefaults? { UserDefaults(suiteName: appGroupID) }

    static var current: ShareSheetExperience {
        get {
            guard let raw = defaults?.string(forKey: defaultsKey),
                  let value = ShareSheetExperience(rawValue: raw)
            else { return .off }
            return value
        }
        set { defaults?.set(newValue.rawValue, forKey: defaultsKey) }
    }
}
