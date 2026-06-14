//
//  YouTubeQuery.swift
//  Clip
//

import Foundation

/// Parses the "channel:title" input for the Save YouTube Video intent.
/// Splits on the FIRST colon (titles may contain colons), drops a leading "@"
/// from the channel, and strips ellipses from the search terms.
enum YouTubeQuery {

    struct Parsed: Equatable {
        let channel: String
        let title: String
    }

    static func parse(_ raw: String) -> Parsed? {
        guard let colon = raw.firstIndex(of: ":") else { return nil }
        var channel = String(raw[raw.startIndex..<colon])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let title = String(raw[raw.index(after: colon)...])
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if channel.hasPrefix("@") { channel = String(channel.dropFirst()) }

        let cleanedChannel = cleaned(channel)
        let cleanedTitle = cleaned(title)
        guard !cleanedChannel.isEmpty, !cleanedTitle.isEmpty else { return nil }
        return Parsed(channel: cleanedChannel, title: cleanedTitle)
    }

    /// Drops ellipses (… or "...") and collapses whitespace, so truncated
    /// share text still searches cleanly.
    static func cleaned(_ text: String) -> String {
        text.replacingOccurrences(of: "…", with: " ")
            .replacingOccurrences(of: "...", with: " ")
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }
}
