//
//  URLPrefixMatch.swift
//  Lune
//

import Foundation

/// Fuzzy URL prefix comparison for the Safari intent's optional verification
/// parameter: scheme, "www.", trailing slash, and case are ignored; the check
/// passes when either normalized URL is a prefix of the other.
public enum URLPrefixMatch {

    public static func fuzzyPrefixMatches(provided: String, tracked: String) -> Bool {
        let normalizedProvided = normalized(provided)
        let normalizedTracked = normalized(tracked)
        guard !normalizedProvided.isEmpty, !normalizedTracked.isEmpty else { return false }
        return normalizedTracked.hasPrefix(normalizedProvided)
            || normalizedProvided.hasPrefix(normalizedTracked)
    }

    public static func normalized(_ urlString: String) -> String {
        var text = urlString.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for prefix in ["https://", "http://"] where text.hasPrefix(prefix) {
            text = String(text.dropFirst(prefix.count))
        }
        if text.hasPrefix("www.") {
            text = String(text.dropFirst(4))
        }
        while text.hasSuffix("/") {
            text = String(text.dropLast())
        }
        return text
    }
}
