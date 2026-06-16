//
//  ReaderProviders.swift
//  Clip
//

import UIKit

/// Sharing affordances for a reader. The reader code depends only on this
/// protocol — the main app injects an implementation backed by the social
/// stack (CloudKit), while the share-extension reader passes `nil` (no share
/// footer, no share button). Keeps the reader free of CloudKit.
protocol ReaderShareProviding: AnyObject {
    /// Display name of a friend to suggest sharing this URL with (the
    /// end-of-article one-tap), or nil if there's nothing to suggest.
    func suggestedFriendName(forURLString urlString: String) -> String?
    /// Presents the full "share this article" sheet.
    func presentShareSheet(
        urlString: String, title: String?, from presenter: UIViewController, sourceView: UIView)
    /// One-tap send to the currently suggested friend.
    func sendToSuggestedFriend(urlString: String, title: String?, from presenter: UIViewController)
}

/// Estimates the last-read word from the front camera. The reader depends only
/// on this protocol; the concrete `EyeGazeWordTracker` (ARKit/camera) is
/// injected via `GazeTrackerFactory` by the main app and never compiled into
/// the share extension.
protocol GazeTracking: AnyObject {
    /// The most recent word-index estimate, if any.
    var estimatedWordIndex: Int? { get }
    /// Stops the camera session.
    func stop()
}

/// Builds a gaze tracker for a reader's text view, or returns nil when eye
/// tracking is off/unsupported (or in the share extension).
typealias GazeTrackerFactory = (_ textView: UITextView, _ wordMap: WordMap, _ seedWordIndex: Int?) -> GazeTracking?

/// A child reader that can report the word it's currently on, so the host can
/// carry the reading position across a mode switch.
protocol ReaderPositionTracking: AnyObject {
    /// Best estimate of the word index currently being read. For the scrolling
    /// reader with no playback this is the eye-tracked word (when available),
    /// falling back to the first word fully visible on screen.
    var currentReadingWordIndex: Int? { get }
}
