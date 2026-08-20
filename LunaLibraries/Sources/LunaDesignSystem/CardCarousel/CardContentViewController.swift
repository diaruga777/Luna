//
//  CardContentViewController.swift
//  LunaDesignSystem
//
//  The playback contract between a carousel card and whatever content it hosts.
//  The carousel drives everything through this base class — autoplay/pause on
//  centering, tap play/pause, scrub-bar seeking, and the mute button — so
//  content implementations (video, animated image, static image, app-specific
//  placeholders) stay interchangeable across the Luna apps.
//

import UIKit

/// The mount that follows a card content's audio availability — the carousel,
/// and the scrub strip's preview, which shows the same mute button.
public protocol CardContentAudioAvailabilityObserving: AnyObject {
    func cardContentDidChangeAudioAvailability(_ content: CardContentViewController)
}

/// The mount that follows a card content's play state. Kept separate from the
/// audio observer because a retiring card stops driving the deck's playback
/// controls while its audio availability still resolves the mute button, and a
/// content promoted out of a scrub preview loses the preview's mute wiring
/// before the carousel installs its own.
public protocol CardContentPlaybackObserving: AnyObject {
    func cardContentDidChangePlaybackState(_ content: CardContentViewController)
}

open class CardContentViewController: UIViewController {

    public init() {
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { nil }

    /// Whether the content is time-based (tap toggles playback).
    open var isPlayable: Bool { false }

    /// Whether the content can produce audio — controls the card's mute button.
    /// Implementations that discover this asynchronously (e.g. a video's audio
    /// track loading) should call `reportAudioAvailabilityChange()` when it
    /// changes.
    open var supportsAudio: Bool { false }

    /// Set by the hosting card.
    public weak var audioAvailabilityObserver: CardContentAudioAvailabilityObserving?

    /// Tells the mount that `supportsAudio` has changed.
    public func reportAudioAvailabilityChange() {
        audioAvailabilityObserver?.cardContentDidChangeAudioAvailability(self)
    }

    open var isPlaying: Bool { false }

    /// Set by the hosting carousel.
    public weak var playbackObserver: CardContentPlaybackObserving?

    /// Tells the mount that `isPlaying` has changed, for any reason (including
    /// the carousel's own `setPlaying`), so the paused card's playback controls
    /// follow the content rather than each call site.
    public func reportPlaybackStateChange() {
        playbackObserver?.cardContentDidChangePlaybackState(self)
    }

    /// Whether this content plays at a chooseable rate — the card's speed pill
    /// appears only for content that says yes.
    open var supportsPlaybackSpeed: Bool { false }

    /// The current rate, as a multiple of natural speed.
    open var playbackSpeed: Double { PlaybackSpeed.normal }

    open func setPlaybackSpeed(_ speed: Double) {}

    /// Current playback position as a fraction (0...1) of the duration.
    open var playbackFraction: Double { 0 }

    /// Whether the carousel should show its transient moon-horizon position
    /// bar while the user drags to seek this content. Video opts in; other
    /// playable content (such as animated images) keeps its existing gesture
    /// without presenting video-specific chrome.
    open var showsPlaybackScrubProgress: Bool { false }

    open func setPlaying(_ playing: Bool) {}

    open func seek(toFraction fraction: Double) {}

    open func setMuted(_ muted: Bool) {}

    /// Whether a plain card-level tap at this content-local point should be
    /// forwarded to the carousel delegate. Content with its own non-control
    /// interactions (for example text links or inline image attachments) can
    /// reject the additive card tap without interfering with its own gesture.
    open func allowsCardTap(at point: CGPoint) -> Bool { true }

    /// Whether a long-press at this content-local point belongs to the content
    /// itself rather than the card. Text content returns true over glyphs and
    /// links (so the press selects text or opens the link's own menu) and false
    /// over whitespace, letting the card present its context menu there.
    open func longPressSelectsContent(at point: CGPoint) -> Bool { false }

    /// Whether a horizontal drag beginning at this content-local point belongs
    /// to a narrowly-scoped interaction inside the card rather than carousel
    /// paging. Keep this to controls that genuinely need a horizontal drag
    /// (for example an embedded player or an interactive chart); the default
    /// leaves the card's surrounding surface free to page.
    open func ownsHorizontalDrag(at point: CGPoint) -> Bool { false }

    /// Gives content a chance to replace an ordinary bounds interpolation with
    /// a transition tailored to its rendering model. The Reader uses this to
    /// animate TextKit glyphs between their old and newly reflowed locations
    /// while the card itself expands. Other card kinds keep the no-op default.
    open func prepareForCardViewportTransition(to size: CGSize) {}

    /// Commits the prepared viewport transition inside the carousel's animation
    /// block. Implementations should only change animatable presentation state
    /// here; expensive capture/layout belongs in `prepare...` above.
    open func animatePreparedCardViewportTransition() {}

    /// Retires any temporary presentation installed for the viewport change.
    open func finishCardViewportTransition(completed: Bool) {}

    /// The card became the centered card: playable content should (re)start,
    /// looping, honoring the mute state last applied via `setMuted`.
    open func cardDidBecomeCentered() {
        if isPlayable { setPlaying(true) }
    }

    /// The card left center (paged away / scrub preview): pause, keep position.
    open func cardDidLeaveCenter() {
        if isPlayable { setPlaying(false) }
    }
}
