//
//  BlueskyPostQuery.swift
//  LuneIntents
//

import Foundation

/// Builds a Bluesky search query from the handle + text using the `from:`
/// operator. Pure, so the formatting is testable.
public enum BlueskyPostQuery {
    public static func searchQuery(handle: String, text: String) -> String {
        let cleanText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanHandle = handle.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "@", with: "", options: [.anchored])
        var parts: [String] = []
        if !cleanText.isEmpty { parts.append(cleanText) }
        if !cleanHandle.isEmpty { parts.append("from:\(cleanHandle)") }
        return parts.joined(separator: " ")
    }
}
