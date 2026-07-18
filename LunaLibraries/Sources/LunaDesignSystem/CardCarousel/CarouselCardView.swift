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
