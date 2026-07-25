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
    /// True when this provider offers a multi-option share, so a share button should
    /// hang `shareMenu` off itself as its primary action. False for a provider whose
    /// share is a single verb (the app extension just hands the link to the system
    /// sheet) — those buttons keep their plain tap.
    var providesShareMenu: Bool { get }
    /// The share options as a native menu, for a share button to present. Returning
    /// nil means "no menu for this article" and the button falls back to a tap.
    func shareMenu(
        urlString: String, title: String?, from presenter: UIViewController, sourceView: UIView
    ) -> UIMenu?
    /// Presents the full "share this article" sheet. Still the path for share entry
    /// points that aren't a button we own (a context-menu action, the archive tray).
    func presentShareSheet(
        urlString: String, title: String?, from presenter: UIViewController, sourceView: UIView)
    /// Saves an arbitrary link (e.g. a link long-pressed inside the reader) to
    /// the reading list.
    func saveLink(urlString: String)
}

extension ReaderShareProviding {
    public var providesShareMenu: Bool { false }
    public func shareMenu(
        urlString: String, title: String?, from presenter: UIViewController, sourceView: UIView
    ) -> UIMenu? { nil }
}

/// A child reader that can report the word it's currently on, so the host can
/// carry the reading position across a mode switch.
public protocol ReaderPositionTracking: AnyObject {
    /// Best estimate of the word index currently being read. For the scrolling
    /// reader with no playback this is the first word fully visible on screen.
    var currentReadingWordIndex: Int? { get }
}
