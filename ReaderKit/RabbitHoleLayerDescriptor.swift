//
//  RabbitHoleLayerDescriptor.swift
//  Clip
//
//  Forked, experimental "RabbitHole" reader — see RabbitHoleReaderViewController.
//

import ClipModels
import Foundation

/// One layer of a persisted RabbitHole breadcrumb trail. The root layer (index 0) is
/// the save itself; deeper layers are links the user dove into. Stored separately from
/// `ReadingListItem` (see `RabbitHoleStackStore`) so the conservative cross-process
/// reading-list JSON is never touched by this experiment.
struct RabbitHoleLayerDescriptor: Codable, Equatable {
    /// The page this layer shows.
    var urlString: String
    /// Saved vertical scroll offset for this layer's scroll reader.
    var scrollOffset: Double
    /// Which reader mode this layer was last shown in.
    var readerMode: ReadingListItem.ReaderMode
    /// Resolved title (falls back to the URL in the lip when nil/empty).
    var title: String?
    /// The text of the line the user tapped to descend INTO the next layer — shown in
    /// this layer's bottom lip once it becomes an ancestor. Nil for the focused/leaf
    /// layer (nothing has been tapped from it yet) or when descended from a non-scroll
    /// mode.
    var bottomLipText: String?

    var url: URL? { URL(string: urlString) }

    init(urlString: String,
         scrollOffset: Double = 0,
         readerMode: ReadingListItem.ReaderMode = .scroll,
         title: String? = nil,
         bottomLipText: String? = nil) {
        self.urlString = urlString
        self.scrollOffset = scrollOffset
        self.readerMode = readerMode
        self.title = title
        self.bottomLipText = bottomLipText
    }
}

/// The full persisted trail for one save (keyed by the root reading-list item id).
struct RabbitHoleStack: Codable, Equatable {
    var layers: [RabbitHoleLayerDescriptor]
}
