//
//  ReaderHostDelegates.swift
//  LunaReaderUI
//

import UIKit

/// How a host takes an inline link tap over from the reader it embeds. With a
/// delegate set, the reader hands the link up instead of presenting its own
/// inline split overlay — the host pushes it onto its own navigation stack
/// rather than nesting another one.
///
/// The two readers report the tap in the shape each of them has, and the two
/// shapes are not interchangeable: RSVP knows only where its link pill sits,
/// while the scroll reader hands back the text range UIKit already resolved,
/// which its hosts use for the activation point AND (RabbitHole) for the tapped
/// line's text. `InlineReaderPageViewController` and
/// `RabbitHoleLayerViewController` each embed both readers, so both implement
/// both.
public protocol ReaderLinkActivationDelegate: AnyObject {
    /// The pill's center, in the RSVP reader's own coordinates.
    func reader(_ reader: RSVPViewController, didActivateLink url: URL, at point: CGPoint)
    /// The character range UIKit resolved for the tapped link.
    func reader(
        _ reader: ScrollReaderViewController, didActivateLink url: URL, inRange range: NSRange)
}

/// A host that follows an embedded RSVP reader's play state. The Reader card
/// carousel fades its chrome away while RSVP is playing and back in when it
/// pauses.
public protocol RSVPPlaybackObserving: AnyObject {
    /// Fired whenever playback starts (true) or stops (false) — every path: tap,
    /// controls, scrubbing, read-aloud via the playback center.
    func rsvpReader(_ reader: RSVPViewController, didChangePlaybackState playing: Bool)
}
