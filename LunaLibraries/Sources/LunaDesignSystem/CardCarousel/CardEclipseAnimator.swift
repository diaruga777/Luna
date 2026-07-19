//
//  CardEclipseAnimator.swift
//  LunaDesignSystem
//
//  The carousel's page transition, staged as a solar eclipse. The incoming side
//  card (the moon) slides over the centered outgoing card (the sun), growing
//  slightly past full size, its resting darkness easing from 70% to 60% and then
//  snapping to full color right at the zenith. The outgoing card stays put and
//  holds almost unchanged for most of the crossing — only in the final stretch
//  does it flash bright and the corona (a hot rim inside a wide halo) bloom
//  around its silhouette, while the rest of the screen darkens. Just at the
//  zenith a star-shaped point light — white-hot core, quick falloff, diffraction
//  spikes — flares on the edge covered last (the final sliver of sun), centered
//  vertically. Meanwhile the far peek card fades to black, merging with the
//  darkened background, and is retired at totality. As the scene lifts back out
//  of totality the two reappearing side cards — the outgoing card, now living on
//  the opposite side, and a freshly mounted peek on the vacated side — slide in
//  from their screen edges to their peek positions (at the resting side-card
//  darkness) on a smooth curve, rather than popping in place.
//
//  The ingress runs inside a UIViewPropertyAnimator so an interactive pan can
//  scrub it forward and back with the finger; releasing either finishes through
//  the zenith or reverses back to rest. Taps and scrub commits run the same
//  transition non-interactively. The transition owns only the dressing (dimmer, whitening,
//  corona, flare, black veils) and the incoming card's motion — the carousel's
//  `atZenith` callback does the slot bookkeeping and reports the affected views
//  back for the egress reveal.
//

import UIKit

/// What the carousel changed at the zenith, for the transition to reveal on egress.
public struct CardEclipseZenithResult {
    /// The outgoing card, now positioned at the opposite peek slot (it slides in
    /// from that screen edge).
    public let repositionedOutgoing: UIView?
    /// A freshly mounted peek on the side the incoming card vacated (slides in
    /// from that screen edge).
    public let enteringPeek: UIView?

    public init(repositionedOutgoing: UIView?, enteringPeek: UIView?) {
        self.repositionedOutgoing = repositionedOutgoing
        self.enteringPeek = enteringPeek
    }
}

/// One eclipse page transition — interactive or automatic. Create it, then either
/// `animateToFinish()` (taps, scrub commits) or drive it with `update(fraction:)` +
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
        // dimmer; the corona, sun (outgoing), flare, and moon (incoming) above it —
        // the moon on top, so it masks the flare as it covers the sun's last edge.
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
        // opposite edge, centered vertically. The frame is much larger than the
        // visible core — the diffraction spikes need the room.
        flare = EclipseFlareView()
        let flareDiameter: CGFloat = 130
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
        // Below the moon: the incoming card masks the bright point, so only the
        // part of the star still outside the moon's edge shows (diamond ring),
        // and it is swallowed as the edge sweeps past.
        container.insertSubview(flare, belowSubview: incoming)

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
                // The sun stays essentially unchanged for most of the crossing…
                UIView.addKeyframe(withRelativeStartTime: 0, relativeDuration: 0.8) {
                    whitening.alpha = 0.06
                }
                // …then flashes bright in the last moments before totality.
                UIView.addKeyframe(withRelativeStartTime: 0.8, relativeDuration: 0.2) {
                    whitening.alpha = 0.92
                }
                // The corona is barely there until the sun is nearly covered…
                UIView.addKeyframe(withRelativeStartTime: 0, relativeDuration: 0.8) {
                    corona.alpha = 0.08
                }
                // …and blooms to full only right at the moment of overlap, as
                // the rest of the screen falls dark.
                UIView.addKeyframe(withRelativeStartTime: 0.8, relativeDuration: 0.2) {
                    corona.alpha = 1
                }
                UIView.addKeyframe(withRelativeStartTime: 0.3, relativeDuration: 0.7) {
                    dimmer.alpha = 0.72
                }
                UIView.addKeyframe(withRelativeStartTime: 0.82, relativeDuration: 0.18) {
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

    // MARK: - Automatic run (taps, scrub commits)

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

        // Both reappearing side cards are placed at their resting peek slots by the
        // zenith swap; park each just past its screen edge (its outer edge flush
        // with the container edge) so the egress slides it in to its peek position
        // rather than popping it in place. The travel is exactly the peek amount.
        let containerWidth = container.bounds.width
        var slideIns: [(card: UIView, restingCenter: CGPoint)] = []
        for card in [result.repositionedOutgoing, result.enteringPeek].compactMap({ $0 }) {
            container.insertSubview(card, belowSubview: dimmer)
            let restingCenter = card.center
            card.center = Self.offscreenPeekCenter(for: card, containerWidth: containerWidth)
            slideIns.append((card, restingCenter))
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
                for slideIn in slideIns { slideIn.card.center = slideIn.restingCenter }
            }
            UIView.addKeyframe(withRelativeStartTime: 0, relativeDuration: 0.25) {
                flare.alpha = 0
                flare.transform = CGAffineTransform(scaleX: 1.35, y: 1.35)
            }
        } completion: { [weak self] _ in
            self?.removeDressing()
            self?.completion(true)
        }
    }

    /// The off-screen center a resting peek card slides in from: its outer edge
    /// flush with the nearer container edge (fully off screen), on whichever side
    /// its resting slot lies. `card.frame` already reflects the card's scale, so
    /// the resulting travel to the resting center is exactly the peek amount.
    private static func offscreenPeekCenter(for card: UIView, containerWidth: CGFloat) -> CGPoint {
        let halfWidth = card.frame.width / 2
        let onLeft = card.center.x < containerWidth / 2
        let x = onLeft ? -halfWidth : containerWidth + halfWidth
        return CGPoint(x: x, y: card.center.y)
    }

    private func removeDressing() {
        dimmer.removeFromSuperview()
        corona.removeFromSuperview()
        flare.removeFromSuperview()
        whitening.removeFromSuperview()
        oppositeVeil?.removeFromSuperview()
    }

    /// The corona: two stacked glows — a tight, hot rim and a wide, soft halo —
    /// each a white rounded rect matching the sun's silhouette whose shadow is
    /// the light. The card body above them is opaque, so only the glow escaping
    /// past the edges is visible.
    public static func makeCorona(frame: CGRect) -> UIView {
        let corona = UIView(frame: frame)
        corona.isUserInteractionEnabled = false
        for (radius, opacity) in [(CGFloat(48), Float(0.95)), (CGFloat(14), Float(1))] {
            let glow = UIView(frame: corona.bounds)
            glow.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            glow.backgroundColor = .white
            glow.layer.cornerRadius = CarouselCardView.cornerRadius
            glow.layer.cornerCurve = .continuous
            glow.layer.shadowColor = UIColor.white.cgColor
            glow.layer.shadowOpacity = opacity
            glow.layer.shadowOffset = .zero
            glow.layer.shadowRadius = radius
            corona.addSubview(glow)
        }
        return corona
    }
}

/// The diamond-ring point, drawn like a bright point light caught by a camera:
/// a white-hot core with a very quick radial falloff into a faint diffuse halo,
/// plus thin diffraction spikes — four long axis-aligned rays and four shorter
/// diagonals — so it reads as a star, not a dot. Drawn (not shadowed) so the
/// profile stays point-like.
public final class EclipseFlareView: UIView {
    public override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        isUserInteractionEnabled = false
        backgroundColor = .clear
        contentMode = .redraw
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { nil }

    public override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let maxRadius = min(bounds.width, bounds.height) / 2

        // Core: white-hot, dropping off quickly, with only a faint diffuse tail.
        let colors: [CGColor] = [
            UIColor.white.cgColor,
            UIColor.white.cgColor,
            UIColor.white.withAlphaComponent(0.55).cgColor,
            UIColor.white.withAlphaComponent(0.16).cgColor,
            UIColor.white.withAlphaComponent(0.04).cgColor,
            UIColor.clear.cgColor,
        ]
        let locations: [CGFloat] = [0, 0.04, 0.09, 0.2, 0.42, 1]
        if let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: colors as CFArray,
            locations: locations) {
            context.drawRadialGradient(
                gradient,
                startCenter: center,
                startRadius: 0,
                endCenter: center,
                endRadius: maxRadius,
                options: .drawsAfterEndLocation)
        }

        // Diffraction spikes: long rays on the axes, shorter dimmer diagonals.
        for index in 0..<8 {
            let diagonal = index % 2 == 1
            let angle = CGFloat(index) * .pi / 4
            drawSpike(
                context: context,
                center: center,
                angle: angle,
                length: maxRadius * (diagonal ? 0.5 : 1),
                halfWidth: maxRadius * (diagonal ? 0.02 : 0.028),
                peakAlpha: diagonal ? 0.5 : 0.9)
        }
    }

    /// One tapered ray from the center: a thin concave-sided kite filled with a
    /// white-to-clear gradient along its length, so it thins and fades to the tip.
    private func drawSpike(context: CGContext, center: CGPoint, angle: CGFloat,
                           length: CGFloat, halfWidth: CGFloat, peakAlpha: CGFloat) {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 0, y: -halfWidth))
        path.addQuadCurve(to: CGPoint(x: length, y: 0),
                          control: CGPoint(x: length * 0.16, y: -halfWidth * 0.18))
        path.addQuadCurve(to: CGPoint(x: 0, y: halfWidth),
                          control: CGPoint(x: length * 0.16, y: halfWidth * 0.18))
        path.closeSubpath()

        guard let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [
                UIColor.white.withAlphaComponent(peakAlpha).cgColor,
                UIColor.white.withAlphaComponent(peakAlpha * 0.35).cgColor,
                UIColor.clear.cgColor,
            ] as CFArray,
            locations: [0, 0.35, 1])
        else { return }

        context.saveGState()
        context.translateBy(x: center.x, y: center.y)
        context.rotate(by: angle)
        context.addPath(path)
        context.clip()
        context.drawLinearGradient(
            gradient,
            start: .zero,
            end: CGPoint(x: length, y: 0),
            options: [])
        context.restoreGState()
    }
}
