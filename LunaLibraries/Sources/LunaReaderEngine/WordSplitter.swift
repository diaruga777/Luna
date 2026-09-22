//
//  WordSplitter.swift
//  Luna
//

import Foundation

/// Splits an RSVP token into display frames that fit the focal column.
/// Compound words always break at their hyphens first, with each hyphen shown
/// only at the end of the part before the break. Any part still too long is
/// hard-hyphenated into fitting chunks. Unhyphenated words within the limit
/// are returned unchanged. Pure, tested.
public enum WordSplitter {

    /// Hyphen-minus plus the two Unicode hyphens commonly found in prose.
    /// En/em dashes are punctuation rather than compound-word separators.
    private static let compoundHyphens: Set<Character> = ["-", "‐", "‑"]

    /// `maxCharacters` is the widest part (in characters) that fits on screen.
    public static func split(_ token: String, maxCharacters: Int) -> [String] {
        guard maxCharacters > 1 else { return [token] }

        let hyphenParts = hyphenSplit(token)
        if hyphenParts.count > 1 {
            return hyphenParts.flatMap { hardWrap($0, maxCharacters: maxCharacters) }
        }
        guard token.count > maxCharacters else { return [token] }
        return hardWrap(token, maxCharacters: maxCharacters)
    }

    /// "well-being" → ["well-", "being"]; "a-b-c" → ["a-", "b-", "c"].
    /// Only an internal hyphen between letters or numbers is a compound break;
    /// leading/trailing hyphens and repeated punctuation stay untouched.
    private static func hyphenSplit(_ token: String) -> [String] {
        let characters = Array(token)
        guard characters.count >= 3 else { return [token] }

        var parts: [String] = []
        var current = ""
        for index in characters.indices {
            let character = characters[index]
            current.append(character)

            guard Self.compoundHyphens.contains(character),
                  index > characters.startIndex,
                  index < characters.index(before: characters.endIndex) else { continue }
            let previous = characters[characters.index(before: index)]
            let next = characters[characters.index(after: index)]
            guard (previous.isLetter || previous.isNumber),
                  (next.isLetter || next.isNumber) else { continue }

            parts.append(current)
            current = ""
        }
        guard !parts.isEmpty else { return [token] }
        parts.append(current)
        return parts
    }

    /// Cuts a too-long part into chunks of `maxCharacters`, each but the last
    /// gaining a trailing hyphen (so the total stays within the limit).
    private static func hardWrap(_ part: String, maxCharacters: Int) -> [String] {
        guard part.count > maxCharacters else { return [part] }
        var remaining = Array(part)
        var chunks: [String] = []
        let take = max(1, maxCharacters - 1) // room for the trailing hyphen
        while remaining.count > maxCharacters {
            chunks.append(String(remaining.prefix(take)) + "-")
            remaining.removeFirst(take)
        }
        chunks.append(String(remaining))
        return chunks
    }
}
