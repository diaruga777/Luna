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
    private let borderView = UIView()
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

        // A subtle glass rim delineating the card from a same-tone screen
        // background (style-gated by the host; fades with the carousel chrome
        // during immersion). Sits above the dim overlay so side cards keep
        // their outline while dimmed.
        borderView.frame = bounds
        borderView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        borderView.isUserInteractionEnabled = false
        borderView.layer.cornerRadius = Self.cornerRadius
        borderView.layer.cornerCurve = .continuous
        borderView.layer.borderWidth = 1
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

    /// Animatable border opacity — the carousel fades it with the rest of its
    /// chrome when the centered card goes immersive.
    public var borderAlpha: CGFloat {
        get { borderView.alpha }
        set { borderView.alpha = newValue }
    }

    private func applyBorderColor() {
        borderView.layer.borderColor =
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
