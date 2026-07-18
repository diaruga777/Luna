//
//  ReaderProviders.swift
//  Luna
//

import LunaReaderEngine
import UIKit

/// Sharing affordances for a reader. The reader code depends only on this
/// protocol — the main app injects an implementation backed by the social
/// stack (CloudKit), while the share-extension reader passes `nil` (no share
/// footer, no share button). Keeps the reader free of CloudKit.
public protocol ReaderShareProviding: AnyObject {
    /// Presents the full "share this article" sheet.
    func presentShareSheet(
        urlString: String, title: String?, from presenter: UIViewController, sourceView: UIView)
    /// Saves an arbitrary link (e.g. a link long-pressed inside the reader) to
    /// the reading list.
    func saveLink(urlString: String)
}

/// A child reader that can report the word it's currently on, so the host can
/// carry the reading position across a mode switch.
public protocol ReaderPositionTracking: AnyObject {
    /// Best estimate of the word index currently being read. For the scrolling
    /// reader with no playback this is the first word fully visible on screen.
    var currentReadingWordIndex: Int? { get }
}
