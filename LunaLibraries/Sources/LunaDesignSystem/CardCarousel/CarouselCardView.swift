//
//  CarouselCardView.swift
//  LunaDesignSystem
//
//  The chrome of one carousel card: a rounded-corner surface in a tone slightly
//  offset from the screen background (so an aspect-fit letterboxed frame still
//  reads as a card), a clipped content container, a mute/unmute button at the
//  top-right, and a top-leading accessory slot (e.g. the Photos-reference badge).
//

import UIKit

public final class CarouselCardView: UIView {

    public static let cornerRadius: CGFloat = 22

    /// Content view controllers' views are installed here, filling the card.
    public let contentContainer = UIView()

    /// Fired when the user taps the mute button. The carousel owns the actual
    /// mute state (it spans cards); the card only reports the tap.
    public var onMuteToggle: (() -> Void)?

    private let muteButton = UIButton(type: .system)
    private let dimOverlay = UIView()
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
    private var topLeadingAccessory: UIView?

    public override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .secondarySystemBackground
        layer.cornerRadius = Self.cornerRadius
        layer.cornerCurve = .continuous
        clipsToBounds = true

        contentContainer.frame = bounds
        contentContainer.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        contentContainer.clipsToBounds = true
        addSubview(contentContainer)

        // Non-centered cards rest heavily darkened (see the carousel's resting
        // layout and the eclipse's dim choreography).
        dimOverlay.frame = bounds
        dimOverlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        dimOverlay.backgroundColor = .black
        dimOverlay.alpha = 0
        dimOverlay.isUserInteractionEnabled = false
        addSubview(dimOverlay)

        // A Liquid Glass rim delineating the card from a same-tone screen
        // background (style-gated by the host; fades with the carousel chrome
        // during immersion). Sits above the dim overlay so side cards keep
        // their outline while dimmed.
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
            (card: CarouselCardView, _: UITraitCollection) in
            card.applyBorderColor()
        }

        var configuration = UIButton.Configuration.plain()
        configuration.baseForegroundColor = .white
        configuration.background.backgroundColor = UIColor.black.withAlphaComponent(0.4)
        configuration.background.cornerRadius = 18
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8)
        muteButton.configuration = configuration
        muteButton.addTarget(self, action: #selector(muteTapped), for: .touchUpInside)
        muteButton.isHidden = true
        muteButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(muteButton)
        NSLayoutConstraint.activate([
            muteButton.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            muteButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            muteButton.widthAnchor.constraint(equalToConstant: 36),
            muteButton.heightAnchor.constraint(equalToConstant: 36),
        ])
        updateMuteIcon(muted: true)
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

    public func setMuteButtonVisible(_ visible: Bool) {
        muteButton.isHidden = !visible
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

    /// Hides the card's own surface tone (animatable). While immersed the
    /// content edge fades dissolve into the SCREEN background — a visible
    /// card-toned band behind them would silhouette the retired container.
    public func setSurfaceHidden(_ hidden: Bool) {
        backgroundColor = hidden ? .clear : .secondarySystemBackground
    }

    /// Animatable border opacity — the carousel fades it with the rest of its
    /// chrome when the centered card goes immersive.
    public var borderAlpha: CGFloat {
        get { borderView.alpha }
        set { borderView.alpha = newValue }
    }

    private func applyBorderColor() {
        borderHighlight.strokeColor =
            GlassStyle.glassBorderColor.resolvedColor(with: traitCollection).cgColor
    }

    /// The resting darkness for a non-centered card.
    public static let restingDimAlpha: CGFloat = 0.7

    /// How dark the card's built-in black overlay is (0 = full color). Animatable.
    public var dimAlpha: CGFloat {
        get { dimOverlay.alpha }
        set { dimOverlay.alpha = newValue }
    }

    public func updateMuteIcon(muted: Bool) {
        let name = muted ? "speaker.slash.fill" : "speaker.wave.2.fill"
        muteButton.setImage(
            UIImage(systemName: name,
                    withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold)),
            for: .normal)
        muteButton.accessibilityLabel = muted ? "Unmute" : "Mute"
    }

    /// A small accessory pinned to the card's top-leading corner (the top-right
    /// is the mute button's). Pass nil to clear.
    public func setTopLeadingAccessory(_ view: UIView?, size: CGSize = CGSize(width: 28, height: 28)) {
        topLeadingAccessory?.removeFromSuperview()
        topLeadingAccessory = view
        guard let view else { return }
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            view.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            view.widthAnchor.constraint(equalToConstant: size.width),
            view.heightAnchor.constraint(equalToConstant: size.height),
        ])
    }

    @objc private func muteTapped() {
        onMuteToggle?()
    }
}

/// A mask that is opaque through the middle and dissolves to clear over a fixed
/// point-run at the top and bottom edges. Backed by a gradient layer directly,
/// so UIView animations that resize the card (immersion's bottom extension)
/// carry the mask along.
private final class VerticalEdgeFadeMaskView: UIView {

    override class var layerClass: AnyClass { CAGradientLayer.self }
    private var gradient: CAGradientLayer { layer as! CAGradientLayer }
    private var fadeHeight: CGFloat = 0

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
        fadeHeight = height
        guard bounds.height > 0 else { return }
        let fraction = min(max(height / bounds.height, 0), 0.5)
        gradient.locations = [0, NSNumber(value: fraction), NSNumber(value: 1 - fraction), 1]
    }
}
