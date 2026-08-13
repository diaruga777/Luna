//
//  RabbitHoleLayerDescriptor.swift
//  Luna
//
//  Forked, experimental "RabbitHole" reader — see RabbitHoleReaderViewController.
//

import LunaModels
import Foundation

/// One layer of a persisted RabbitHole breadcrumb trail. The root layer (index 0) is
/// the save itself; deeper layers are links the user dove into. Stored separately from
/// `SavedItem` (see `RabbitHoleStackStore`) so the cross-process saves
/// database is never touched by this experiment.
public struct RabbitHoleLayerDescriptor: Codable, Equatable {
    /// The page this layer shows, parsed ONCE (at construction/decode) rather
    /// than re-parsed on every access — nil is the blank shell created before
    /// `configure(...)` installs a real URL (`RabbitHoleLayerViewController`'s
    /// placeholder `urlString: ""`), not a transient parse failure.
    public var url: URL?
    /// The shared scroll/RSVP reading position for this layer, as a word/token index —
    /// the mode-independent anchor both readers restore from.
    public var wordIndex: Int?
    /// The scroll reader's exact pixel offset for `wordIndex`, kept ONLY while it still
    /// corresponds to it. RSVP moves the position in word space with no pixels, so it
    /// nils this (resume from `wordIndex` by word instead) — the hybrid rule.
    public var scrollOffset: Double?
    /// The original/archive reader's OWN vertical offset, kept fully disjoint from the
    /// shared reading position above.
    public var originalScrollOffset: Double
    /// Which reader mode this layer was last shown in.
    public var readerMode: SavedItem.ReaderMode
    /// Resolved title (falls back to the URL in the lip when nil/empty).
    public var title: String?
    /// The text of the line the user tapped to descend INTO the next layer — shown in
    /// this layer's bottom lip once it becomes an ancestor. Nil for the focused/leaf
    /// layer (nothing has been tapped from it yet) or when descended from a non-scroll
    /// mode.
    public var bottomLipText: String?

    /// `url`'s string form — empty for the blank shell, matching the pre-parse
    /// shape this type used to persist directly.
    public var urlString: String { url?.absoluteString ?? "" }

    public init(urlString: String,
         wordIndex: Int? = nil,
         scrollOffset: Double? = nil,
         originalScrollOffset: Double = 0,
         readerMode: SavedItem.ReaderMode = .scroll,
         title: String? = nil,
         bottomLipText: String? = nil) {
        self.url = URL(string: urlString)
        self.wordIndex = wordIndex
        self.scrollOffset = scrollOffset
        self.originalScrollOffset = originalScrollOffset
        self.readerMode = readerMode
        self.title = title
        self.bottomLipText = bottomLipText
    }

    private enum CodingKeys: String, CodingKey {
        case urlString, wordIndex, scrollOffset, originalScrollOffset, readerMode, title, bottomLipText
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        url = URL(string: try container.decode(String.self, forKey: .urlString))
        wordIndex = try container.decodeIfPresent(Int.self, forKey: .wordIndex)
        scrollOffset = try container.decodeIfPresent(Double.self, forKey: .scrollOffset)
        originalScrollOffset = try container.decode(Double.self, forKey: .originalScrollOffset)
        readerMode = try container.decode(SavedItem.ReaderMode.self, forKey: .readerMode)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        bottomLipText = try container.decodeIfPresent(String.self, forKey: .bottomLipText)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(urlString, forKey: .urlString)
        try container.encodeIfPresent(wordIndex, forKey: .wordIndex)
        try container.encodeIfPresent(scrollOffset, forKey: .scrollOffset)
        try container.encode(originalScrollOffset, forKey: .originalScrollOffset)
        try container.encode(readerMode, forKey: .readerMode)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encodeIfPresent(bottomLipText, forKey: .bottomLipText)
    }
}

/// The full persisted trail for one save (keyed by the root saved item id).
public struct RabbitHoleStack: Codable, Equatable {
    public var layers: [RabbitHoleLayerDescriptor]

    public init(layers: [RabbitHoleLayerDescriptor]) {
        self.layers = layers
    }
}
