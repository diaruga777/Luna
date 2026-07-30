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
    private let popoverText = MoonRevealLineView(
        text: "Say goodbye to popups.",
        font: .systemFont(ofSize: 21, weight: .semibold),
        textAlignment: .center,
        numberOfLines: 2,
        minimumScaleFactor: 0.88,
        occluderColor: OnboardingArticleReplicaPalette.popover)
    private let finalLine = MoonRevealLineView(
        text: "In just one click.",
        font: .systemFont(ofSize: 22, weight: .semibold),
        textAlignment: .center,
        occluderColor: OnboardingArticleReplicaPalette.background)
    private let popoverArrow = CAShapeLayer()
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
        popoverText.accessibilityIdentifier = "onboarding.safari.article.popoverText"
        finalLine.accessibilityIdentifier = "onboarding.safari.article.finalLine"

        addSubview(headline)
        addSubview(body)
        addSubview(banner)

        popover.backgroundColor = OnboardingArticleReplicaPalette.popover
        popover.layer.cornerRadius = 24
        popover.layer.cornerCurve = .continuous
        popover.layer.borderWidth = 1
        popover.layer.borderColor = UIColor.white.withAlphaComponent(0.2).cgColor
        popover.layer.shadowColor = UIColor.black.cgColor
        popover.layer.shadowOpacity = 0.42
        popover.layer.shadowRadius = 22
        popover.layer.shadowOffset = CGSize(width: 0, height: 12)
        popover.layer.addSublayer(popoverArrow)
        popover.addSubview(popoverText)
        addSubview(popover)

        addSubview(finalLine)

        banner.transform = CGAffineTransform(translationX: 460, y: 0)
        popover.alpha = 0
        popover.transform = CGAffineTransform(
            translationX: 0, y: 18).scaledBy(x: 0.82, y: 0.82)
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
            x: 28, y: banner.frame.maxY + 34,
            width: bounds.width - 56, height: 104)
        popoverText.frame = popover.bounds.insetBy(dx: 18, dy: 20)
        finalLine.frame = CGRect(
            x: horizontalInset, y: popover.frame.maxY + 30,
            width: contentWidth, height: 48)

        let arrowWidth: CGFloat = 28
        let arrowHeight: CGFloat = 14
        let arrowPath = UIBezierPath()
        arrowPath.move(to: CGPoint(x: 0, y: arrowHeight))
        arrowPath.addLine(to: CGPoint(x: arrowWidth / 2, y: 0))
        arrowPath.addLine(to: CGPoint(x: arrowWidth, y: arrowHeight))
        arrowPath.close()
        popoverArrow.path = arrowPath.cgPath
        popoverArrow.fillColor = popover.backgroundColor?.cgColor
        popoverArrow.frame = CGRect(
            x: popover.bounds.midX - arrowWidth / 2,
            y: -arrowHeight + 1,
            width: arrowWidth,
            height: arrowHeight)
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
        label.frame = bounds.insetBy(dx: 34, dy: 8)
        close.frame = CGRect(x: bounds.width - 31, y: 5, width: 24, height: 24)
    }
}
