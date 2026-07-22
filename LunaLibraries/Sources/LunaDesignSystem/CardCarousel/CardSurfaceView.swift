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
        borderHighlight.lineWidth = 0.75
        borderView.contentView.layer.addSublayer(borderHighlight)
        borderView.isHidden = true
        addSubview(borderView)
        applyBorderColor()
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) {
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
        let rimWidth: CGFloat = 3
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

    private func applyBorderColor() {
        borderHighlight.strokeColor =
            GlassStyle.glassBorderColor.resolvedColor(with: traitCollection).cgColor
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
