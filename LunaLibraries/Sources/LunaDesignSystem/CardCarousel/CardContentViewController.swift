//
//  CardContentViewController.swift
//  LunaDesignSystem
//
//  The playback contract between a carousel card and whatever content it hosts.
//  The carousel drives everything through this base class — autoplay/pause on
//  centering, tap play/pause, in-card drag scrubbing, and the mute button — so
//  content implementations (video, animated image, static image, app-specific
//  placeholders) stay interchangeable across the Luna apps.
//

import UIKit

open class CardContentViewController: UIViewController {

    public init() {
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { nil }

    /// Whether the content is time-based (tap toggles playback, drag scrubs).
    open var isPlayable: Bool { false }

    /// Whether the content can produce audio — controls the card's mute button.
    /// Implementations that discover this asynchronously (e.g. a video's audio
    /// track loading) should call `audioAvailabilityChanged` when it changes.
    open var supportsAudio: Bool { false }

    /// Set by the hosting card; invoke after `supportsAudio` changes.
    public var audioAvailabilityChanged: (() -> Void)?

    open var isPlaying: Bool { false }

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
