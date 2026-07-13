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
/// `ReadingListItem` (see `RabbitHoleStackStore`) so the conservative cross-process
/// reading-list JSON is never touched by this experiment.
public struct RabbitHoleLayerDescriptor: Codable, Equatable {
    /// The page this layer shows.
    public var urlString: String
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
    public var readerMode: ReadingListItem.ReaderMode
    /// Resolved title (falls back to the URL in the lip when nil/empty).
    public var title: String?
    /// The text of the line the user tapped to descend INTO the next layer — shown in
    /// this layer's bottom lip once it becomes an ancestor. Nil for the focused/leaf
    /// layer (nothing has been tapped from it yet) or when descended from a non-scroll
    /// mode.
    public var bottomLipText: String?

    public var url: URL? { URL(string: urlString) }

    public init(urlString: String,
         wordIndex: Int? = nil,
         scrollOffset: Double? = nil,
         originalScrollOffset: Double = 0,
         readerMode: ReadingListItem.ReaderMode = .scroll,
         title: String? = nil,
         bottomLipText: String? = nil) {
        self.urlString = urlString
        self.wordIndex = wordIndex
        self.scrollOffset = scrollOffset
        self.originalScrollOffset = originalScrollOffset
        self.readerMode = readerMode
        self.title = title
        self.bottomLipText = bottomLipText
    }
}

/// The full persisted trail for one save (keyed by the root reading-list item id).
public struct RabbitHoleStack: Codable, Equatable {
    public var layers: [RabbitHoleLayerDescriptor]

    public init(layers: [RabbitHoleLayerDescriptor]) {
        self.layers = layers
    }
}
