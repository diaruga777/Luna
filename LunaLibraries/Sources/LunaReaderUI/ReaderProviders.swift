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
    /// Display name of a friend to suggest sharing this URL with (the
    /// end-of-article one-tap), or nil if there's nothing to suggest.
    func suggestedFriendName(forURLString urlString: String) -> String?
    /// Presents the full "share this article" sheet.
    func presentShareSheet(
        urlString: String, title: String?, from presenter: UIViewController, sourceView: UIView)
    /// One-tap send to the currently suggested friend.
    func sendToSuggestedFriend(urlString: String, title: String?, from presenter: UIViewController)
    /// Saves an arbitrary link (e.g. a link long-pressed inside the reader) to
    /// the reading list.
    func saveLink(urlString: String)
}

/// Estimates the last-read word from the front camera. The reader depends only
/// on this protocol; the concrete `EyeGazeWordTracker` (ARKit/camera) is
/// injected via `GazeTrackerFactory` by the main app and never compiled into
/// the share extension.
public protocol GazeTracking: AnyObject {
    /// The most recent word-index estimate, if any.
    var estimatedWordIndex: Int? { get }
    /// Called (on the main thread) whenever the estimate changes — drives the
    /// optional live "highlight the word you're looking at" affordance.
    var onWordIndexChange: ((Int) -> Void)? { get set }
    /// Stops the camera session.
    func stop()
}

/// Builds a gaze tracker for a reader's text view, or returns nil when eye
/// tracking is off/unsupported (or in the share extension).
public typealias GazeTrackerFactory = (_ textView: UITextView, _ wordMap: WordMap, _ seedWordIndex: Int?) -> GazeTracking?

/// Drives the visual transition between two RabbitHole layer arrangements (a dive,
/// a pop, or an interactive overscroll). The reader depends only on this protocol;
/// the app injects a Metal pixel-mosaic implementation (`LunaContentRendering` can't be
/// linked into `LunaReaderUI`, which compiles into the extensions). When nil (Metal
/// unavailable / extension), the host cuts instantly with no animation.
///
/// Both calls take a `before` and `after` snapshot of the whole reader. The impl owns
/// its overlay: it adds it to `container` on top, animates, and removes it when done.
public protocol RabbitHoleTransitioning: AnyObject {
    /// Optionally build the overlay now and park it (hidden) in `container`, so the
    /// first transition doesn't pay the Metal setup cost mid-tap. Safe to call more
    /// than once; a no-op when Metal is unavailable.
    func prewarm(in container: UIView)
    /// Non-interactive dive/pop wipe with ZERO visible work on the tap's critical path.
    ///
    /// The impl masks the screen INSTANTLY with a cheap view snapshot (no re-render),
    /// then on the next runloop calls `prepare` — which performs the (expensive)
    /// before-snapshot + layer build/relayout + after-snapshot, returning both images —
    /// entirely hidden behind that mask, hands off to the GPU dissolve, and removes the
    /// instant mask. `completion` fires once the wipe finishes and the overlay is parked.
    ///
    /// `region` (in `container`'s coordinate space) confines the wipe to just that
    /// sub-rect: the overlay is framed there and the `before`/`after` images supplied by
    /// `prepare` are expected to be that-region-sized (the host snapshots only that
    /// rect), so everything OUTSIDE the region keeps its live views and never pixelates.
    /// Pass nil ⇒ a full-`container.bounds` wipe (full-`bounds`-sized images), identical
    /// to before. The host computes the region from a UIView-level changed-region diff so
    /// genuinely-unchanged chrome (e.g. layer-0 lips) stays perfectly static.
    func play(prepare: @escaping () -> (before: UIImage, after: UIImage),
              in container: UIView, region: CGRect?, completion: @escaping () -> Void)
    /// Begin an interactive wipe; drive the returned handle with `update(progress:)`
    /// (0 = before, 1 = after) and end it with `finish(committed:completion:)`.
    ///
    /// `region` confines the wipe exactly as in `play(prepare:in:region:completion:)`:
    /// the `before`/`after` images are that-region-sized and the overlay is framed to it;
    /// nil ⇒ a full-`container.bounds` wipe.
    func begin(before: UIImage, after: UIImage,
               in container: UIView, region: CGRect?) -> RabbitHoleInteractiveTransition
}

public extension RabbitHoleTransitioning {
    /// Full-screen convenience: wipe the whole `container.bounds` (the pre-region API).
    func play(prepare: @escaping () -> (before: UIImage, after: UIImage),
              in container: UIView, completion: @escaping () -> Void) {
        play(prepare: prepare, in: container, region: nil, completion: completion)
    }
    /// Full-screen convenience: begin a whole-`container.bounds` interactive wipe.
    func begin(before: UIImage, after: UIImage,
               in container: UIView) -> RabbitHoleInteractiveTransition {
        begin(before: before, after: after, in: container, region: nil)
    }
}

/// Handle to an in-flight interactive RabbitHole transition.
public protocol RabbitHoleInteractiveTransition: AnyObject {
    /// 0 = fully the before state, 1 = fully the after state.
    func update(progress: CGFloat)
    /// Settle to the after state (`committed`) or back to before; `completion` fires
    /// after the settle animation and overlay removal.
    func finish(committed: Bool, completion: @escaping () -> Void)
}

/// A child reader that can report the word it's currently on, so the host can
/// carry the reading position across a mode switch.
public protocol ReaderPositionTracking: AnyObject {
    /// Best estimate of the word index currently being read. For the scrolling
    /// reader with no playback this is the eye-tracked word (when available),
    /// falling back to the first word fully visible on screen.
    var currentReadingWordIndex: Int? { get }
}
