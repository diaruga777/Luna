//
//  CarouselCardView.swift
//  LunaDesignSystem
//
//  Carousel-specific chrome layered on top of CardSurfaceView's generic
//  rounded/edge-fading surface: a dim overlay for non-centered cards, a
//  mute/unmute button at the top-right, and a top-leading accessory slot
//  (e.g. the Photos-reference badge).
//

import UIKit
import LunaModels

public final class CarouselCardView: CardSurfaceView {

    /// The geometry shared by every card-local floating control. Hosts that
    /// temporarily move the mute button beyond the card use these values to
    /// preserve its exact card-mode margin against their new edge.
    public static let muteButtonInset: CGFloat = 12
    public static let muteButtonDiameter: CGFloat = 36

    /// Fired when the user taps the mute button. The carousel owns the actual
    /// mute state (it spans cards); the card only reports the tap.
    public var onMuteToggle: (() -> Void)?

    private let muteButton = UIButton(type: .system)
    private let dimOverlay = UIView()
    private var topLeadingAccessory: UIView?

    /// Opacity of transient controls that belong to the centered card rather
    /// than its media: mute and the optional top-leading accessory. Scrubbed
    /// media promotes its already-playing preview and fades only this chrome in.
    public var chromeAlpha: CGFloat {
        get { muteButton.alpha }
        set {
            muteButton.alpha = newValue
            topLeadingAccessory?.alpha = newValue
        }
    }

    public override init(frame: CGRect) {
        super.init(frame: frame)

        // Non-centered cards rest heavily darkened (see the carousel's resting
        // layout and the eclipse's dim choreography). Inserted directly above
        // the content container — and so below the base class's glass rim —
        // so side cards keep their outline while dimmed.
        dimOverlay.frame = bounds
        dimOverlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        dimOverlay.backgroundColor = .black
        dimOverlay.alpha = 0
        dimOverlay.isUserInteractionEnabled = false
        insertSubview(dimOverlay, aboveSubview: contentContainer)

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
            muteButton.topAnchor.constraint(equalTo: topAnchor, constant: Self.muteButtonInset),
            muteButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.muteButtonInset),
            muteButton.widthAnchor.constraint(equalToConstant: Self.muteButtonDiameter),
            muteButton.heightAnchor.constraint(equalToConstant: Self.muteButtonDiameter),
        ])
        updateMuteIcon(muted: true)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { nil }

    public func setMuteButtonVisible(_ visible: Bool) {
        muteButton.isHidden = !visible
    }

    /// Translates the mute toggle independently of its card. The carousel uses
    /// this while a reader card sheds its surrounding chrome: the card can keep
    /// animating its viewport while the toggle lands at the safe screen edge.
    public func setMuteButtonTranslation(_ translation: CGPoint) {
        muteButton.transform = CGAffineTransform(
            translationX: translation.x, y: translation.y)
    }

    /// Hides the card's own surface tone (animatable). While immersed the
    /// content edge fades dissolve into the SCREEN background — a visible
    /// card-toned band behind them would silhouette the retired container.
    public func setSurfaceHidden(_ hidden: Bool) {
        backgroundColor = hidden ? .clear : LunaColors.secondaryBackground
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
        muteButton.accessibilityLabel = muted ? L10n.string("CardDeck_unmuteAccessibilityLabel") : L10n.string("CardDeck_muteAccessibilityLabel")
    }

    /// A small accessory pinned to the card's top-leading corner (the top-right
    /// is the mute button's). Pass nil to clear.
    public func setTopLeadingAccessory(_ view: UIView?, size: CGSize = CGSize(width: 28, height: 28)) {
        topLeadingAccessory?.removeFromSuperview()
        topLeadingAccessory = view
        guard let view else { return }
        view.alpha = chromeAlpha
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
