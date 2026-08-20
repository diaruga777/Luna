//
//  CardCarouselPullTabHint.swift
//  LunaDesignSystem
//
//  A one-time tutorial affordance for the root card decks. Its marker lives in
//  the App Group so a page swipe in any Luna app teaches the gesture everywhere.
//

import UIKit
import LunaAppConfig

/// Persists whether the user has already discovered horizontal card paging.
///
/// The shared App Group suite is deliberate: Luna Reader, Downloader, and Price
/// Tracker are separate apps, but the tutorial describes the same shared card
/// carousel interaction in all of them.
public protocol CardCarouselPullTabHintStoring: AnyObject {
    var hasSeenCardPagingSwipe: Bool { get }
    func recordCardPagingSwipe()
}

public final class CardCarouselPullTabHintStore: CardCarouselPullTabHintStoring {
    private static let key = "cardCarousel.pullTabHint.dismissed.v1"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults? = nil) {
        self.defaults = defaults ?? UserDefaults(suiteName: AppConfig.appGroupID) ?? .standard
    }

    public var hasSeenCardPagingSwipe: Bool {
        defaults.bool(forKey: Self.key)
    }

    public func recordCardPagingSwipe() {
        defaults.set(true, forKey: Self.key)
    }
}

/// The small right-edge handle that gently demonstrates the direction of a
/// card-page gesture. It deliberately does not accept touches: the carousel's
/// own pan recognizer continues to receive the entire edge gesture.
final class CardCarouselPullTabHintView: UIView {
    static let size = CGSize(width: 38, height: 68)

    private let chevron = UIImageView(image: UIImage(
        systemName: "chevron.left",
        withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .bold)))
    private var isAnimatingHint = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        accessibilityIdentifier = "cardCarousel.pullTabHint"
        accessibilityElementsHidden = true
        backgroundColor = LunaSurfacePalette.glassTint
        layer.cornerRadius = 17
        // The left edge overlaps the card by a few points; only the exposed
        // right edge rounds, so it reads as a tab attached to the card.
        layer.maskedCorners = [.layerMaxXMinYCorner, .layerMaxXMaxYCorner]
        layer.borderWidth = 1
        layer.borderColor = LunaColors.separator.cgColor

        chevron.translatesAutoresizingMaskIntoConstraints = false
        chevron.tintColor = LunaColors.primaryText
        chevron.contentMode = .center
        addSubview(chevron)
        NSLayoutConstraint.activate([
            chevron.centerXAnchor.constraint(equalTo: centerXAnchor, constant: -1),
            chevron.centerYAnchor.constraint(equalTo: centerYAnchor),
            chevron.widthAnchor.constraint(equalToConstant: 24),
            chevron.heightAnchor.constraint(equalToConstant: 24),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func setHintAnimating(_ shouldAnimate: Bool) {
        guard shouldAnimate != isAnimatingHint else { return }
        isAnimatingHint = shouldAnimate
        layer.removeAllAnimations()
        chevron.layer.removeAllAnimations()
        transform = .identity
        chevron.transform = .identity

        guard shouldAnimate, !UIAccessibility.isReduceMotionEnabled else { return }
        UIView.animate(
            withDuration: 0.92,
            delay: 0.18,
            options: [.autoreverse, .repeat, .allowUserInteraction, .beginFromCurrentState, .curveEaseInOut]
        ) {
            self.transform = CGAffineTransform(scaleX: 1.07, y: 1.07)
            self.chevron.transform = CGAffineTransform(translationX: -4, y: 0)
        }
    }
}
