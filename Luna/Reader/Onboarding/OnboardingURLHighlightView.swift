//
//  OnboardingURLHighlightView.swift
//  Luna
//

import LunaDesignSystem
import UIKit

/// The bright, persistent pressed-state wash shared by Safari's URL field and
/// the newest incoming URL in the Messages mock.
final class OnboardingURLHighlightView: UIView {
    private let gradient = CAGradientLayer()

    private(set) var isHighlighted = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        alpha = 0
        layer.addSublayer(gradient)
        configureColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        gradient.frame = bounds
        gradient.cornerRadius = bounds.height / 2
        layer.cornerRadius = bounds.height / 2
    }

    func setHighlighted(_ highlighted: Bool) {
        isHighlighted = highlighted
        configureColors()
        alpha = highlighted ? 1 : 0
        layer.borderWidth = highlighted ? 1 : 0
        layer.borderColor = UIColor.white.withAlphaComponent(0.72).cgColor
        layer.shadowColor = highlighted
            ? LunaSurfacePalette.baseColor.cgColor
            : UIColor.clear.cgColor
        layer.shadowOpacity = highlighted ? 0.72 : 0
        layer.shadowRadius = highlighted ? 12 : 0
        layer.shadowOffset = .zero
    }

    private func configureColors() {
        let tint = LunaSurfacePalette.baseColor
        let brightTint = LunaSurfacePalette.blended(
            tint, toward: .white, amount: 0.42)
        gradient.colors = [
            tint.withAlphaComponent(0.58).cgColor,
            brightTint.withAlphaComponent(0.88).cgColor,
            UIColor.white.withAlphaComponent(0.76).cgColor,
            brightTint.withAlphaComponent(0.88).cgColor,
            tint.withAlphaComponent(0.58).cgColor,
        ]
        gradient.locations = [0, 0.24, 0.5, 0.76, 1]
        gradient.startPoint = CGPoint(x: 0, y: 0.5)
        gradient.endPoint = CGPoint(x: 1, y: 0.5)
    }
}
