//
//  AudioPlaybackWordIndexing.swift
//  LunaAudioPlayback
//

import Foundation

/// Pure helpers mapping between the "global word index" domain
/// `AudioPlaybackCenter` uses for resume/seek and
/// `ReadingListItem.lastSpokenWordIndex` (0-based, counting
/// whitespace-delimited words across an `AudioScript`'s `spokenBlocks` in
/// order — the exact rule `AudioScript.totalWordCount` uses) and the
/// per-block character-range domain `SpeechRenderer`'s `WordMarker`s live in.
///
/// Resume/seek/skip granularity is BLOCK-LEVEL: a target word index always
/// resolves to the start of whichever spoken block contains it, never a
/// mid-block offset. That mirrors the documented fallback precision
/// `SpeechRenderer.render(_:)` calls out for when word markers are
/// unavailable ("block-level resume/highlighting granularity, not
/// word-level... still fine") — here it's a deliberate simplification rather
/// than a fallback: re-rendering (or slicing) a block's PCM to resume
/// mid-buffer isn't worth the complexity when "restart this paragraph" reads
/// as correct behavior. Live word-level highlighting DURING forward playback
/// still uses the full marker precision (see `AudioPlaybackCenter`'s word
/// event pipeline) — only resume/seek/skip snaps to a block boundary.
///
/// Public so other modules that need the same word-boundary arithmetic over
/// their own block-like sequences (e.g. `LunaReaderUI`'s RSVP token mapping,
/// which counts whitespace-delimited tokens across `ArticleContent.Block`s
/// the same way) can reuse it instead of re-deriving it.
public enum AudioWordIndexing {
    /// Number of whitespace-delimited words in `text` — matches
    /// `AudioScript`'s own word-counting rule exactly.
    public static func wordCount(in text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace }).count
    }

    /// The global word index at the START of each entry in `spokenBlocks`
    /// (a parallel array — same count, same order).
    public static func blockStartWordIndices(_ spokenBlocks: [AudioScript.SpokenBlock]) -> [Int] {
        var result: [Int] = []
        result.reserveCapacity(spokenBlocks.count)
        var running = 0
        for block in spokenBlocks {
            result.append(running)
            running += wordCount(in: block.text)
        }
        return result
    }

    /// The index INTO `spokenBlocks` (i.e. a position in `starts`) whose span
    /// contains global `wordIndex`, clamped to the script's bounds.
    public static func spokenBlockPosition(forWordIndex wordIndex: Int, in starts: [Int]) -> Int {
        guard !starts.isEmpty else { return 0 }
        var position = 0
        for (index, start) in starts.enumerated() where start <= wordIndex {
            position = index
        }
        return position
    }

    /// UTF-16 start offsets of each whitespace-delimited word in `text`, in
    /// ascending order — used to translate a `WordMarker.utteranceRange` (a
    /// character range within a block's text) into a word offset WITHIN that
    /// block, for live word-event highlighting during forward playback.
    public static func wordStartUTF16Offsets(in text: String) -> [Int] {
        var offsets: [Int] = []
        var index = text.startIndex
        while index < text.endIndex {
            if !text[index].isWhitespace,
               index == text.startIndex || text[text.index(before: index)].isWhitespace {
                offsets.append(index.utf16Offset(in: text))
            }
            index = text.index(after: index)
        }
        return offsets
    }

    /// The 0-based word offset WITHIN a block whose text produced
    /// `wordStartOffsets` (see above), for a marker's UTF-16 `location`.
    public static func wordOffset(forUTF16Location location: Int, wordStartOffsets: [Int]) -> Int {
        guard !wordStartOffsets.isEmpty else { return 0 }
        var offset = 0
        for (index, start) in wordStartOffsets.enumerated() where start <= location {
            offset = index
        }
        return offset
    }
}

extension Array {
    /// Bounds-safe subscript used throughout `AudioPlaybackCenter`'s index
    /// arithmetic — deliberately re-declared here (rather than importing a
    /// module that already has one) to keep `LunaAudioPlayback`'s dependency
    /// graph exactly what Phase 2 needs.
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
