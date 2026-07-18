//
//  CardEclipseAnimator.swift
//  LunaDesignSystem
//
//  The carousel's page transition, staged as a solar eclipse. The incoming side
//  card (the moon) slides over the centered outgoing card (the sun), growing
//  slightly past full size, its resting darkness easing from 70% to 60% and then
//  snapping to full color right at the zenith. The outgoing card stays put and
//  lightens — subtly at first, then very fast as it is almost covered — while a
//  corona blooms around its silhouette and the rest of the screen darkens. Just
//  at the zenith a point-like star flares on the edge covered last (the final
//  sliver of sun), centered vertically. Meanwhile the peek card on the opposite
//  side fades to black, merging with the darkened background; behind that veil
//  the slots are re-stacked, and on the way back it is unveiled as the outgoing
//  card now living on that side (at the resting side-card darkness).
//
//  The ingress runs inside a UIViewPropertyAnimator so an interactive pan can
//  scrub it forward and back with the finger; releasing either finishes through
//  the zenith or reverses back to rest. Taps/flicks run the same transition
//  non-interactively. The transition owns only the dressing (dimmer, whitening,
//  corona, flare, black veils) and the incoming card's motion — the carousel's
//  `atZenith` callback does the slot bookkeeping and reports the affected views
//  back for the egress reveal.
//

import UIKit

/// What the carousel changed at the zenith, for the transition to reveal on egress.
public struct CardEclipseZenithResult {
    /// The outgoing card, now positioned at the opposite peek slot (it will be
    /// unveiled from black).
    public let repositionedOutgoing: UIView?
    /// A freshly mounted peek on the side the incoming card vacated (fades in).
    public let enteringPeek: UIView?

    public init(repositionedOutgoing: UIView?, enteringPeek: UIView?) {
        self.repositionedOutgoing = repositionedOutgoing
        self.enteringPeek = enteringPeek
    }
}

/// One eclipse page transition — interactive or automatic. Create it, then either
/// `animateToFinish()` (tap/flick) or drive it with `update(fraction:)` +
/// `finishInteractive()` / `cancelInteractive()` from a pan.
public final class CardEclipseTransition {

    public static let duration: TimeInterval = 0.62
    /// The incoming card overshoots full size slightly at the zenith, guaranteeing
    /// the outgoing card is entirely covered when the slots are re-stacked.
    public static let zenithScale: CGFloat = 1.03

    private let container: UIView
    private let outgoing: CarouselCardView
    private let incoming: CarouselCardView
    private let atZenith: () -> CardEclipseZenithResult
    private let completion: (_ finished: Bool) -> Void

    private let ingress: UIViewPropertyAnimator
    private let dimmer: UIView
    private let corona: UIView
    private let flare: EclipseFlareView
    private let whitening: UIView
    private var oppositeVeil: UIView?
    private var didStart = false

    /// - Parameters:
    ///   - container: the card area; dressing views are added to it.
    ///   - forward: paging direction (true = to the next card, incoming from the
    ///     trailing side).
    ///   - incomingTargetCenter: the centered slot's center point.
    ///   - dimmingBounds: region (in container coordinates) the darkening veil
    ///     covers — typically extending past the cards over the scrub area.
    ///   - atZenith: slot bookkeeping, run behind the veils at total coverage.
    ///   - completion: `finished` is false when an interactive run was cancelled
    ///     (everything is back at rest and no swap happened).
    public init(
        in container: UIView,
        outgoing: CarouselCardView,
        incoming: CarouselCardView,
        oppositePeek: UIView?,
        forward: Bool,
        incomingTargetCenter: CGPoint,
        dimmingBounds: CGRect,
        atZenith: @escaping () -> CardEclipseZenithResult,
        completion: @escaping (_ finished: Bool) -> Void
    ) {
        self.container = container
        self.outgoing = outgoing
        self.incoming = incoming
        self.atZenith = atZenith
        self.completion = completion

        let outgoingFrame = outgoing.frame

        // Dressing, bottom to top: the black-veiled opposite peek stays below the
        // dimmer; the corona, sun (outgoing), moon (incoming), and flare above it.
        dimmer = UIView(frame: dimmingBounds)
        dimmer.backgroundColor = .black
        dimmer.alpha = 0
        container.addSubview(dimmer)

        corona = Self.makeCorona(frame: outgoingFrame)
        corona.alpha = 0
        container.addSubview(corona)

        container.bringSubviewToFront(outgoing)
        container.bringSubviewToFront(incoming)

        whitening = UIView(frame: outgoing.bounds)
        whitening.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        whitening.backgroundColor = .white
        whitening.alpha = 0
        whitening.isUserInteractionEnabled = false
        outgoing.addSubview(whitening)

        if let oppositePeek {
            let veil = UIView(frame: oppositePeek.bounds)
            veil.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            veil.backgroundColor = .black
            veil.alpha = 0
            veil.isUserInteractionEnabled = false
            oppositePeek.addSubview(veil)
            oppositeVeil = veil
        }

        // The last sliver of sun: the edge the moon covers last. The incoming card
        // sweeps from one side, so coverage completes at the outgoing card's
        // opposite edge, centered vertically.
        flare = EclipseFlareView()
        let flareDiameter: CGFloat = 42
        let flareCenter = CGPoint(
            x: forward ? outgoingFrame.minX : outgoingFrame.maxX,
            y: outgoingFrame.midY)
        flare.frame = CGRect(
            x: flareCenter.x - flareDiameter / 2,
            y: flareCenter.y - flareDiameter / 2,
            width: flareDiameter,
            height: flareDiameter)
        flare.alpha = 0
        flare.transform = CGAffineTransform(scaleX: 0.45, y: 0.45)
        container.addSubview(flare)

        let ingressDuration = Self.duration * 0.66
        let dimmer = self.dimmer
        let corona = self.corona
        let flare = self.flare
        let whitening = self.whitening
        let oppositeVeil = self.oppositeVeil

        // The ingress is keyframed inside a property animator so a pan can scrub
        // it (scrubs linearly — keyframe timing then maps to finger travel).
        ingress = UIViewPropertyAnimator(duration: ingressDuration, curve: .easeInOut) {
            UIView.animateKeyframes(withDuration: 0, delay: 0) {
                UIView.addKeyframe(withRelativeStartTime: 0, relativeDuration: 1) {
                    incoming.center = incomingTargetCenter
                    incoming.transform = CGAffineTransform(
                        scaleX: Self.zenithScale, y: Self.zenithScale)
                    oppositeVeil?.alpha = 1
                }
                // The incoming card's resting darkness lifts only slightly while
                // it crosses…
                UIView.addKeyframe(withRelativeStartTime: 0, relativeDuration: 0.85) {
                    incoming.dimAlpha = 0.6
                }
                // …then drops to full color very rapidly right at the zenith.
                UIView.addKeyframe(withRelativeStartTime: 0.85, relativeDuration: 0.15) {
                    incoming.dimAlpha = 0
                }
                // The sun lightens subtly at first…
                UIView.addKeyframe(withRelativeStartTime: 0, relativeDuration: 0.55) {
                    whitening.alpha = 0.18
                }
                // …then very fast as it is almost covered entirely.
                UIView.addKeyframe(withRelativeStartTime: 0.55, relativeDuration: 0.45) {
                    whitening.alpha = 0.92
                }
                UIView.addKeyframe(withRelativeStartTime: 0, relativeDuration: 0.7) {
                    corona.alpha = 0.5
                }
                // The corona shines brightest just at the moment of overlap, as
                // the rest of the screen falls dark.
                UIView.addKeyframe(withRelativeStartTime: 0.7, relativeDuration: 0.3) {
                    corona.alpha = 1
                }
                UIView.addKeyframe(withRelativeStartTime: 0.3, relativeDuration: 0.7) {
                    dimmer.alpha = 0.72
                }
                UIView.addKeyframe(withRelativeStartTime: 0.74, relativeDuration: 0.26) {
                    flare.alpha = 1
                    flare.transform = .identity
                }
            }
        }
        ingress.addCompletion { [weak self] position in
            guard let self else { return }
            if position == .end {
                self.runZenithAndEgress()
            } else {
                self.removeDressing()
                self.completion(false)
            }
        }
    }

    // MARK: - Automatic run (taps, flicks)

    public func animateToFinish() {
        didStart = true
        ingress.startAnimation()
    }

    // MARK: - Interactive driving (inset pan)

    /// Scrubs the ingress to `fraction` (clamped to 0...1) of the way to zenith.
    public func update(fraction: CGFloat) {
        didStart = true
        if ingress.state == .inactive { ingress.startAnimation() }
        ingress.pauseAnimation()
        ingress.fractionComplete = min(max(fraction, 0), 0.999)
    }

    /// Plays the rest of the ingress, then the zenith swap and egress.
    public func finishInteractive() {
        guard didStart else {
            animateToFinish()
            return
        }
        ingress.isReversed = false
        ingress.continueAnimation(
            withTimingParameters: UICubicTimingParameters(animationCurve: .easeIn),
            durationFactor: 1 - ingress.fractionComplete)
    }

    /// Plays the ingress backwards to rest; no swap happens.
    public func cancelInteractive() {
        guard didStart else {
            removeDressing()
            completion(false)
            return
        }
        ingress.isReversed = true
        ingress.continueAnimation(
            withTimingParameters: UICubicTimingParameters(animationCurve: .easeOut),
            durationFactor: max(ingress.fractionComplete, 0.15))
    }

    // MARK: - Zenith + egress

    private func runZenithAndEgress() {
        // Total coverage: re-stack the slots behind the veils.
        whitening.removeFromSuperview()
        oppositeVeil?.removeFromSuperview()
        let result = atZenith()

        var outgoingVeil: UIView?
        if let moved = result.repositionedOutgoing {
            container.insertSubview(moved, belowSubview: dimmer)
            let veil = UIView(frame: moved.bounds)
            veil.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            veil.backgroundColor = .black
            veil.alpha = 1
            veil.isUserInteractionEnabled = false
            moved.addSubview(veil)
            outgoingVeil = veil
        }
        if let entering = result.enteringPeek {
            container.insertSubview(entering, belowSubview: dimmer)
            entering.alpha = 0
        }

        let incoming = self.incoming
        let dimmer = self.dimmer
        let corona = self.corona
        let flare = self.flare
        UIView.animateKeyframes(
            withDuration: Self.duration - ingress.duration,
            delay: 0,
            options: [.calculationModeCubic]
        ) {
            UIView.addKeyframe(withRelativeStartTime: 0, relativeDuration: 1) {
                dimmer.alpha = 0
                corona.alpha = 0
                incoming.transform = .identity
                outgoingVeil?.alpha = 0
                result.enteringPeek?.alpha = 1
            }
            UIView.addKeyframe(withRelativeStartTime: 0, relativeDuration: 0.25) {
                flare.alpha = 0
                flare.transform = CGAffineTransform(scaleX: 1.35, y: 1.35)
            }
        } completion: { [weak self] _ in
            outgoingVeil?.removeFromSuperview()
            self?.removeDressing()
            self?.completion(true)
        }
    }

    private func removeDressing() {
        dimmer.removeFromSuperview()
        corona.removeFromSuperview()
        flare.removeFromSuperview()
        whitening.removeFromSuperview()
        oppositeVeil?.removeFromSuperview()
    }

    /// A white rounded rect matching the sun's silhouette whose shadow is the
    /// corona: the card body above it is opaque, so only the glow escaping past
    /// the edges is visible.
    private static func makeCorona(frame: CGRect) -> UIView {
        let corona = UIView(frame: frame)
        corona.backgroundColor = .white
        corona.layer.cornerRadius = CarouselCardView.cornerRadius
        corona.layer.cornerCurve = .continuous
        corona.layer.shadowColor = UIColor.white.cgColor
        corona.layer.shadowOpacity = 1
        corona.layer.shadowOffset = .zero
        corona.layer.shadowRadius = 26
        corona.isUserInteractionEnabled = false
        return corona
    }
}

/// The diamond-ring point: a small radial gradient falling off from a white-hot
/// core, drawn (not shadowed) so its profile stays point-like.
private final class EclipseFlareView: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        isUserInteractionEnabled = false
        backgroundColor = .clear
        contentMode = .redraw
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        let colors: [CGColor] = [
            UIColor.white.cgColor,
            UIColor.white.withAlphaComponent(0.85).cgColor,
            UIColor.white.withAlphaComponent(0.32).cgColor,
            UIColor.white.withAlphaComponent(0.08).cgColor,
            UIColor.clear.cgColor,
        ]
        let locations: [CGFloat] = [0, 0.05, 0.18, 0.45, 1]
        guard let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: colors as CFArray,
            locations: locations)
        else { return }
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        context.drawRadialGradient(
            gradient,
            startCenter: center,
            startRadius: 0,
            endCenter: center,
            endRadius: min(bounds.width, bounds.height) / 2,
            options: .drawsAfterEndLocation)
    }
}
