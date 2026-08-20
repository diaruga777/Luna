//
//  WeeklyRowEclipseTransition.swift
//  Luna
//

import LunaDesignSystem
import UIKit

/// A new Luna team pick eclipsing the old one, in the row's own slot
/// (`UtilCardLayout.weeklyRowHeight`).
///
/// The choreography is the card carousel's (`CardEclipseAnimator`): the
/// incoming body crosses, the outgoing one whitens late, and the corona blooms
/// exactly at totality. What is deliberately not borrowed is the dressing — no
/// dimmer, no peek veils, no diamond-ring flare. At row scale the corona is
/// the effect; the rest would be noise around a strip that short.
@MainActor
final class WeeklyRowEclipseTransition {
    /// Matches `CardEclipseTransition.duration`, split 66/34 like the card's.
    static let duration: TimeInterval = 0.62
    /// `EclipseCorona`'s own default has a 56pt floor sized for a CARD. On a
    /// row that hands it streamers as tall as the thing they surround, so the
    /// reach is overridden here for the same reason the onboarding pills
    /// override it.
    static let coronaReach: CGFloat = 30

    private let corona: EclipseCoronaView
    private let outgoing: UIView
    private let incoming: UIView
    private let whitening = UIView()
    private let completion: () -> Void
    private var finished = false

    /// - Parameters:
    ///   - host: The slot's outer view, which must NOT clip — the corona
    ///     overhangs the row on every side and that overhang is the whole
    ///     point.
    ///   - clip: The clipping child the rows live in, so the incoming row's
    ///     travel reads as a slide in from the edge rather than an object
    ///     floating over the card.
    init(
        host: UIView,
        clip: UIView,
        outgoing: UIView,
        incoming: UIView,
        completion: @escaping () -> Void
    ) {
        self.outgoing = outgoing
        self.incoming = incoming
        self.completion = completion

        corona = EclipseCoronaView(
            bodySize: clip.bounds.size,
            cornerRadius: UtilURLRow.cornerRadius,
            tint: LunaSurfacePalette.atmosphereTint,
            reach: Self.coronaReach)
        corona.frame = clip.frame
        corona.alpha = 0
        // Behind the rows: only the exterior half of the corona is ever meant
        // to be seen, and the opaque row is what hides the rest.
        host.insertSubview(corona, belowSubview: clip)

        incoming.frame = clip.bounds
        incoming.alpha = 0
        incoming.transform = CGAffineTransform(
            translationX: clip.bounds.width * 0.3, y: 0)
        clip.addSubview(incoming)

        whitening.frame = outgoing.bounds
        whitening.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        whitening.backgroundColor = .white
        whitening.alpha = 0
        whitening.isUserInteractionEnabled = false
        outgoing.addSubview(whitening)
    }

    func start() {
        let ingress = Self.duration * 0.66
        let incoming = self.incoming
        let corona = self.corona
        let whitening = self.whitening

        UIView.animateKeyframes(
            withDuration: ingress, delay: 0, options: [.calculationModeCubic]
        ) {
            UIView.addKeyframe(withRelativeStartTime: 0, relativeDuration: 1) {
                incoming.transform = .identity
            }
            // "Quickly fades in": the new row is solid long before it lands.
            UIView.addKeyframe(withRelativeStartTime: 0, relativeDuration: 0.25) {
                incoming.alpha = 1
            }
            // The sun holds, then flares white in the last moments of coverage…
            UIView.addKeyframe(withRelativeStartTime: 0, relativeDuration: 0.8) {
                whitening.alpha = 0.06
            }
            UIView.addKeyframe(withRelativeStartTime: 0.8, relativeDuration: 0.2) {
                whitening.alpha = 0.92
            }
            // …and the corona is barely there until that same moment.
            UIView.addKeyframe(withRelativeStartTime: 0, relativeDuration: 0.8) {
                corona.alpha = 0.08
            }
            UIView.addKeyframe(withRelativeStartTime: 0.8, relativeDuration: 0.2) {
                corona.alpha = 1
            }
        } completion: { [weak self] _ in
            // UIView animation completions land on the main thread.
            MainActor.assumeIsolated { self?.runEgress() }
        }
    }

    /// Totality: the old row is gone, and the light goes with it.
    private func runEgress() {
        whitening.removeFromSuperview()
        outgoing.removeFromSuperview()
        UIView.animate(
            withDuration: Self.duration * 0.34, delay: 0, options: [.curveEaseOut]
        ) {
            self.corona.alpha = 0
        } completion: { [weak self] _ in
            self?.finish()
        }
    }

    /// Idempotent teardown: the host drops its reference here, and a second
    /// call (an interrupted animation completing late) must not re-run it.
    func finish() {
        guard !finished else { return }
        finished = true
        whitening.removeFromSuperview()
        corona.removeFromSuperview()
        outgoing.removeFromSuperview()
        incoming.transform = .identity
        incoming.alpha = 1
        completion()
    }
}
