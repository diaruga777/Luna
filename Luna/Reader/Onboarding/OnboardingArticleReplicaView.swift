//
//  OnboardingArticleReplicaView.swift
//  Luna
//

import UIKit

private enum OnboardingArticleReplicaPalette {
    static let background = UIColor(
        red: 0.025, green: 0.03, blue: 0.055, alpha: 1)
    static let popover = UIColor(white: 0.095, alpha: 0.98)
}

enum OnboardingArticleReplicaTiming {
    static let headlineRevealDuration: TimeInterval = 1.05
    static let bodyRevealDuration: TimeInterval = 0.92
    static let componentDelay: TimeInterval = 0.22
    static let bannerDuration: TimeInterval = 0.52
    static let popoverDuration: TimeInterval = 0.48
    static let popoverTextRevealDuration: TimeInterval = 0.82
    static let finalLineRevealDuration: TimeInterval = 0.76
}

/// Luna's fictional Safari article. It is native instead of HTML so the
/// glyph-level eclipse reveals begin only once the full-screen takeover has
/// completed; preloading the Safari replica cannot consume the sequence.
final class OnboardingArticleReplicaView: UIView {
    private let headline = MoonRevealLineView(
        text: "Save anything in Safari",
        font: .systemFont(ofSize: 32, weight: .bold),
        textAlignment: .left,
        numberOfLines: 2,
        minimumScaleFactor: 0.82,
        occluderColor: OnboardingArticleReplicaPalette.background)
    private let body = MoonRevealLineView(
        text: "Your article, and your browsing history, all stay offline.",
        font: .systemFont(ofSize: 18, weight: .regular),
        textAlignment: .left,
        numberOfLines: 3,
        minimumScaleFactor: 0.9,
        occluderColor: OnboardingArticleReplicaPalette.background)
    private let banner = OnboardingAnnoyingBannerView()
    private let popover = UIView()
    private let popoverTitle = UILabel()
    private let popoverClose = UILabel()
    private let popoverText = MoonRevealLineView(
        text: "…or not\n\nSay good bye to popups and just read",
        font: .systemFont(ofSize: 23, weight: .medium),
        textAlignment: .left,
        numberOfLines: 5,
        minimumScaleFactor: 0.82,
        occluderColor: OnboardingArticleReplicaPalette.popover)
    private let finalLine = MoonRevealLineView(
        text: "In just one click.",
        font: .systemFont(ofSize: 22, weight: .semibold),
        textAlignment: .center,
        occluderColor: OnboardingArticleReplicaPalette.background)
    private var didStart = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = OnboardingArticleReplicaPalette.background
        isUserInteractionEnabled = false
        accessibilityIdentifier = "onboarding.safari.lunaArticle"

        headline.accessibilityIdentifier = "onboarding.safari.article.headline"
        body.accessibilityIdentifier = "onboarding.safari.article.body"
        banner.accessibilityIdentifier = "onboarding.safari.article.banner"
        popover.accessibilityIdentifier = "onboarding.safari.article.popover"
        popoverTitle.accessibilityIdentifier = "onboarding.safari.article.popoverTitle"
        popoverText.accessibilityIdentifier = "onboarding.safari.article.popoverText"
        finalLine.accessibilityIdentifier = "onboarding.safari.article.finalLine"

        addSubview(headline)
        addSubview(body)
        addSubview(banner)

        popover.backgroundColor = OnboardingArticleReplicaPalette.popover
        popover.layer.cornerRadius = 30
        popover.layer.cornerCurve = .continuous
        popover.layer.borderWidth = 2
        popover.layer.borderColor = UIColor.white.withAlphaComponent(0.34).cgColor
        popover.layer.shadowColor = UIColor.black.cgColor
        popover.layer.shadowOpacity = 0.72
        popover.layer.shadowRadius = 30
        popover.layer.shadowOffset = CGSize(width: 0, height: 18)

        popoverTitle.text = "Subscribe!"
        popoverTitle.font = .systemFont(ofSize: 34, weight: .heavy)
        popoverTitle.textColor = .white
        popoverTitle.textAlignment = .left
        popover.addSubview(popoverTitle)

        popoverClose.text = "×"
        popoverClose.font = .systemFont(ofSize: 24, weight: .bold)
        popoverClose.textColor = UIColor.white.withAlphaComponent(0.72)
        popoverClose.textAlignment = .center
        popover.addSubview(popoverClose)

        popover.addSubview(popoverText)
        addSubview(popover)

        addSubview(finalLine)

        // `isHidden` is deliberate: a transform alone can briefly expose the
        // banner while the preloaded view receives its first layout pass.
        banner.isHidden = true
        banner.alpha = 0
        popover.alpha = 0
        popover.transform = CGAffineTransform(
            translationX: 0, y: 26).scaledBy(x: 0.72, y: 0.72)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        let horizontalInset: CGFloat = 24
        let contentWidth = bounds.width - horizontalInset * 2

        headline.frame = CGRect(
            x: horizontalInset, y: 56, width: contentWidth, height: 82)
        body.frame = CGRect(
            x: horizontalInset, y: headline.frame.maxY + 12,
            width: contentWidth, height: 70)
        banner.frame = CGRect(
            x: 15, y: body.frame.maxY + 30,
            width: bounds.width - 30, height: 76)
        popover.frame = CGRect(
            x: 16, y: 146,
            width: bounds.width - 32, height: 430)
        popoverTitle.frame = CGRect(
            x: 28, y: 30, width: popover.bounds.width - 92, height: 48)
        popoverClose.frame = CGRect(
            x: popover.bounds.width - 58, y: 25, width: 38, height: 38)
        popoverText.frame = CGRect(
            x: 28, y: 112,
            width: popover.bounds.width - 56, height: 220)
        finalLine.frame = CGRect(
            x: horizontalInset, y: popover.frame.maxY + 24,
            width: contentWidth, height: 48)
    }

    func start(completion: @escaping () -> Void) {
        guard !didStart else {
            completion()
            return
        }
        didStart = true
        layoutIfNeeded()

        headline.reveal(
            duration: OnboardingArticleReplicaTiming.headlineRevealDuration
        ) { [weak self] in
            self?.afterComponentDelay {
                guard let self else { return }
                self.body.reveal(
                    duration: OnboardingArticleReplicaTiming.bodyRevealDuration
                ) { [weak self] in
                    self?.afterComponentDelay {
                        self?.slideBannerIn(completion: completion)
                    }
                }
            }
        }
    }

    private func slideBannerIn(completion: @escaping () -> Void) {
        banner.prepareForReveal()
        UIView.animate(
            withDuration: UIAccessibility.isReduceMotionEnabled
                ? 0.2 : OnboardingArticleReplicaTiming.bannerDuration,
            delay: 0,
            usingSpringWithDamping: 0.72,
            initialSpringVelocity: 0.55,
            options: [.curveEaseOut, .beginFromCurrentState]
        ) {
            self.banner.transform = .identity
        } completion: { [weak self] _ in
            self?.afterComponentDelay {
                self?.showPopover(completion: completion)
            }
        }
    }

    private func showPopover(completion: @escaping () -> Void) {
        UIView.animate(
            withDuration: UIAccessibility.isReduceMotionEnabled
                ? 0.2 : OnboardingArticleReplicaTiming.popoverDuration,
            delay: 0,
            usingSpringWithDamping: 0.7,
            initialSpringVelocity: 0.35,
            options: [.curveEaseOut, .beginFromCurrentState]
        ) {
            self.popover.alpha = 1
            self.popover.transform = .identity
        } completion: { [weak self] _ in
            self?.afterComponentDelay {
                guard let self else { return }
                self.popoverText.reveal(
                    duration: OnboardingArticleReplicaTiming.popoverTextRevealDuration
                ) { [weak self] in
                    self?.afterComponentDelay {
                        guard let self else { return }
                        self.finalLine.reveal(
                            duration: OnboardingArticleReplicaTiming.finalLineRevealDuration
                        ) {
                            self.afterComponentDelay(completion)
                        }
                    }
                }
            }
        }
    }

    private func afterComponentDelay(_ action: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(
            deadline: .now() + OnboardingAnimationClock.delay(
                OnboardingArticleReplicaTiming.componentDelay),
            execute: action)
    }
}

private final class OnboardingAnnoyingBannerView: UIView {
    private let gradient = CAGradientLayer()
    private let radialStripes = CAShapeLayer()
    private let label = UILabel()
    private let close = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.cornerRadius = 14
        layer.cornerCurve = .continuous
        clipsToBounds = true
        layer.borderWidth = 2
        layer.borderColor = UIColor.white.withAlphaComponent(0.92).cgColor

        gradient.colors = [
            UIColor(red: 1, green: 0.08, blue: 0.38, alpha: 1).cgColor,
            UIColor(red: 1, green: 0.55, blue: 0.02, alpha: 1).cgColor,
            UIColor(red: 0.95, green: 0.1, blue: 0.72, alpha: 1).cgColor,
        ]
        gradient.startPoint = CGPoint(x: 0, y: 0.25)
        gradient.endPoint = CGPoint(x: 1, y: 0.75)
        layer.insertSublayer(gradient, at: 0)

        radialStripes.fillColor = UIColor.white.withAlphaComponent(0.22).cgColor
        layer.insertSublayer(radialStripes, above: gradient)

        label.text = "Get rid of annoying ads!"
        label.font = .systemFont(ofSize: 21, weight: .heavy)
        label.textColor = .white
        label.textAlignment = .center
        label.numberOfLines = 2
        label.accessibilityIdentifier = "onboarding.safari.article.bannerText"
        addSubview(label)

        close.text = "×"
        close.font = .systemFont(ofSize: 19, weight: .bold)
        close.textColor = UIColor.white.withAlphaComponent(0.9)
        close.textAlignment = .center
        addSubview(close)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        gradient.frame = bounds
        layoutRadialStripes()
        label.frame = bounds.insetBy(dx: 34, dy: 8)
        close.frame = CGRect(x: bounds.width - 31, y: 5, width: 24, height: 24)
    }

    func prepareForReveal() {
        isHidden = false
        alpha = 1
        transform = CGAffineTransform(
            translationX: max(bounds.width + 40, 460), y: 0)
        startStripeRotationIfNeeded()
    }

    private func layoutRadialStripes() {
        let side = max(bounds.width, bounds.height) * 2.4
        radialStripes.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        radialStripes.position = CGPoint(x: bounds.midX, y: bounds.midY)

        let center = CGPoint(x: side / 2, y: side / 2)
        let radius = side * 0.7
        let stripeCount = 24
        let angle = CGFloat.pi * 2 / CGFloat(stripeCount)
        let path = UIBezierPath()
        for index in stride(from: 0, to: stripeCount, by: 2) {
            let start = -CGFloat.pi / 2 + CGFloat(index) * angle
            path.move(to: center)
            path.addArc(
                withCenter: center,
                radius: radius,
                startAngle: start,
                endAngle: start + angle,
                clockwise: true)
            path.close()
        }
        radialStripes.path = path.cgPath
    }

    private func startStripeRotationIfNeeded() {
        guard !UIAccessibility.isReduceMotionEnabled,
              radialStripes.animation(forKey: "radialStripeRotation") == nil
        else { return }
        let rotation = CABasicAnimation(keyPath: "transform.rotation.z")
        rotation.fromValue = 0
        rotation.toValue = CGFloat.pi * 2
        rotation.duration = 7
        rotation.repeatCount = .infinity
        rotation.timingFunction = CAMediaTimingFunction(name: .linear)
        radialStripes.add(rotation, forKey: "radialStripeRotation")
    }
}
