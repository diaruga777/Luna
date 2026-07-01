//
//  WordSplitter.swift
//  Luna
//

import Foundation

/// Splits an over-long RSVP word into parts that fit the focal column.
/// Hyphenated words break at their hyphens first (the hyphen is shown at the
/// end of the part before the break AND the start of the part after it); any
/// part still too long is hard-hyphenated into fitting chunks. Words within
/// the limit are returned unchanged. Pure, tested.
public enum WordSplitter {

    /// `maxCharacters` is the widest part (in characters) that fits on screen.
    public static func split(_ token: String, maxCharacters: Int) -> [String] {
        guard maxCharacters > 1, token.count > maxCharacters else { return [token] }

        let hyphenParts = hyphenSplit(token)
        if hyphenParts.count > 1 {
            return hyphenParts.flatMap { hardWrap($0, maxCharacters: maxCharacters) }
        }
        return hardWrap(token, maxCharacters: maxCharacters)
    }

    /// "well-being" → ["well-", "-being"]; "a-b-c" → ["a-", "-b-", "-c"].
    /// The hyphen is duplicated across each break so both parts show it.
    public static func hyphenSplit(_ token: String) -> [String] {
        let pieces = token.split(separator: "-", omittingEmptySubsequences: true).map(String.init)
        guard pieces.count > 1 else { return [token] }
        return pieces.enumerated().map { index, piece in
            var part = piece
            if index != 0 { part = "-" + part }
            if index != pieces.count - 1 { part = part + "-" }
            return part
        }
    }

    /// Cuts a too-long part into chunks of `maxCharacters`, each but the last
    /// gaining a trailing hyphen (so the total stays within the limit).
    public static func hardWrap(_ part: String, maxCharacters: Int) -> [String] {
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
