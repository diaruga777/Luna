//
//  CardSurfaceView.swift
//  LunaDesignSystem
//
//  The generic chrome shared by any rounded, edge-fading card surface: a
//  rounded-corner surface in a tone slightly offset from the screen background
//  (so an aspect-fit letterboxed frame still reads as a card), a clipped
//  content container, an optional glass rim delineating the card from a
//  same-tone background, and an optional dissolve of the content at the top
//  and bottom edges instead of a hard clip. `CarouselCardView` builds the
//  carousel's card-specific chrome (mute button, dim overlay, top-leading
//  accessory) on top of this; other hosts that need only the generic surface —
//  e.g. the nested reader's own card chrome — use this class directly.
//

import UIKit

public class CardSurfaceView: UIView {

    public static let cornerRadius: CGFloat = 22

    /// Content view controllers' views are installed here, filling the card.
    public let contentContainer = UIView()

    /// A real Liquid Glass surface clipped to a narrow rounded ring. Unlike a
    /// flat stroke, this refracts whatever card content is directly beneath
    /// the edge and therefore stays visible on both light and dark pages.
    private let borderView = UIVisualEffectView(effect: GlassStyle.barEffect())
    /// UIVisualEffectView ignores `layer.mask` (the backdrop renders unclipped,
    /// frosting the whole card) — the ring must be applied through the
    /// view-level `mask` property instead.
    private let borderMaskView = UIView()
    private let borderMask = CAShapeLayer()
    private let borderHighlight = CAShapeLayer()
    /// Dissolves content at the card's top and bottom edges (host style-gated;
    /// 0 = hard clip). The mask rides `contentContainer`, so the dim overlay,
    /// rim, and corner buttons are unaffected.
    private var contentEdgeFadeHeight: CGFloat = 0
    private let contentFadeMask = VerticalEdgeFadeMaskView()
    /// The failure glow: a tinted ring stroked just inside the card edge, with
    /// its own shadow blooming INWARD over the content. `clipsToBounds` (which
    /// the letterbox tone and corner radius both need) would swallow an outward
    /// `layer.shadow`, so the glow is drawn on the inside of the border where it
    /// reads as a lit rim rather than a drawn stroke.
    private let glowLayer = CAShapeLayer()
    private var glowColor: UIColor?

    public override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = LunaColors.secondaryBackground
        layer.cornerRadius = Self.cornerRadius
        layer.cornerCurve = .continuous
        clipsToBounds = true

        contentContainer.frame = bounds
        contentContainer.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        contentContainer.clipsToBounds = true
        addSubview(contentContainer)

        // A Liquid Glass rim delineating the card from a same-tone screen
        // background (style-gated by the host; a carousel card fades this with
        // the rest of its chrome during immersion).
        borderView.frame = bounds
        borderView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        borderView.isUserInteractionEnabled = false
        borderMask.fillRule = .evenOdd
        borderMask.fillColor = UIColor.white.cgColor
        borderMaskView.layer.addSublayer(borderMask)
        borderView.mask = borderMaskView
        borderHighlight.fillColor = UIColor.clear.cgColor
        borderHighlight.lineWidth = 0.5
        borderView.contentView.layer.addSublayer(borderHighlight)
        borderView.isHidden = true
        addSubview(borderView)

        glowLayer.fillColor = UIColor.clear.cgColor
        glowLayer.shadowOffset = .zero
        glowLayer.isHidden = true
        layer.addSublayer(glowLayer)

        applyBorderColor()
        registerForTraitChanges([LunaSkyTrait.self]) {
            (card: CardSurfaceView, _: UITraitCollection) in
            card.applyBorderColor()
        }
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { nil }

    public override func layoutSubviews() {
        super.layoutSubviews()
        if contentEdgeFadeHeight > 0 {
            contentFadeMask.frame = contentContainer.bounds
            contentFadeMask.setFadeHeight(contentEdgeFadeHeight)
        }
        let outer = UIBezierPath(
            roundedRect: bounds, cornerRadius: Self.cornerRadius)
        let rimWidth: CGFloat = 1.5
        let innerRect = bounds.insetBy(dx: rimWidth, dy: rimWidth)
        outer.append(UIBezierPath(
            roundedRect: innerRect,
            cornerRadius: max(0, Self.cornerRadius - rimWidth)))
        borderMaskView.frame = bounds
        borderMask.frame = bounds
        borderMask.path = outer.cgPath

        borderHighlight.frame = bounds
        borderHighlight.path = UIBezierPath(
            roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
            cornerRadius: Self.cornerRadius - 0.5).cgPath

        let glowInset = Self.glowLineWidth / 2
        let glowPath = UIBezierPath(
            roundedRect: bounds.insetBy(dx: glowInset, dy: glowInset),
            cornerRadius: max(0, Self.cornerRadius - glowInset)).cgPath
        glowLayer.frame = bounds
        glowLayer.path = glowPath
        glowLayer.shadowPath = glowPath
    }

    /// Installs a content view controller's view, filling the card.
    public func installContentView(_ view: UIView) {
        view.frame = contentContainer.bounds
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        contentContainer.addSubview(view)
    }

    /// Enables the glass rim stroke (off by default; the host style gates it).
    public func setBorderEnabled(_ enabled: Bool) {
        borderView.isHidden = !enabled
    }

    /// Dissolve depth for content at the card's top and bottom edges
    /// (0, the default, keeps the hard clip).
    public func setContentEdgeFadeHeight(_ height: CGFloat) {
        contentEdgeFadeHeight = max(0, height)
        contentContainer.mask = contentEdgeFadeHeight > 0 ? contentFadeMask : nil
        setNeedsLayout()
    }

    /// Animatable border opacity — a host fades it with the rest of its own
    /// chrome (e.g. the carousel during immersion).
    public var borderAlpha: CGFloat {
        get { borderView.alpha }
        set { borderView.alpha = newValue }
    }

    /// Line width of the tinted rim; the shadow blooms `glowRadius` inward from it.
    private static let glowLineWidth: CGFloat = 1.5
    private static let glowRadius: CGFloat = 9

    /// Tints the card's edge — the glass rim itself takes the colour, and a soft
    /// inward glow blooms off it. How a card says "this save failed" without a
    /// badge or a banner. `nil` restores the plain glass rim.
    public func setEdgeGlow(_ color: UIColor?) {
        glowColor = color
        glowLayer.isHidden = color == nil
        glowLayer.lineWidth = Self.glowLineWidth
        glowLayer.shadowRadius = Self.glowRadius
        glowLayer.shadowOpacity = 1
        // Resolves both the rim stroke and the bloom, in either direction.
        applyBorderColor()
        setNeedsLayout()
    }

    private func applyBorderColor() {
        // With a glow set, the glass rim itself takes the tint rather than staying
        // white under a coloured bloom: a failed card should read as a card with a
        // RED border, not a white-bordered card that happens to be lit red.
        let border = glowColor?.resolvedColor(with: traitCollection).withAlphaComponent(0.5)
            ?? GlassStyle.glassBorderColor.resolvedColor(with: traitCollection)
        borderHighlight.strokeColor = border.cgColor
        applyGlowColor()
    }

    private func applyGlowColor() {
        guard let glowColor else { return }
        let resolved = glowColor.resolvedColor(with: traitCollection)
        // The rim reads as a lit edge, not a stroke: a mostly-transparent line
        // carrying a wider, softer shadow of the same hue.
        glowLayer.strokeColor = resolved.withAlphaComponent(0.55).cgColor
        glowLayer.shadowColor = resolved.withAlphaComponent(0.75).cgColor
    }
}

/// A mask that is opaque through the middle and dissolves to clear over a fixed
/// point-run at the top and bottom edges. Backed by a gradient layer directly,
/// so UIView animations that resize the card (e.g. the carousel's immersion
/// extension) carry the mask along.
private final class VerticalEdgeFadeMaskView: UIView {

    override class var layerClass: AnyClass { CAGradientLayer.self }
    private var gradient: CAGradientLayer { layer as! CAGradientLayer }

    override init(frame: CGRect) {
        super.init(frame: frame)
        gradient.colors = [
            UIColor.white.withAlphaComponent(0).cgColor,
            UIColor.white.cgColor,
            UIColor.white.cgColor,
            UIColor.white.withAlphaComponent(0).cgColor,
        ]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// Recomputes the fade run as a fraction of the current height — call on
    /// every size change.
    func setFadeHeight(_ height: CGFloat) {
        guard bounds.height > 0 else { return }
        let fraction = min(max(height / bounds.height, 0), 0.5)
        gradient.locations = [0, NSNumber(value: fraction), NSNumber(value: 1 - fraction), 1]
    }
}
