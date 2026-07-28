//
//  OnboardingIntroCard.swift
//  Luna
//

import LunaDesignSystem
import UIKit

final class OnboardingIntroCardContentViewController: CardContentViewController {
    var onContinue: (() -> Void)?

    private let firstLine: MoonRevealLineView
    private let secondLine: MoonRevealLineView
    private let button = UIButton(type: .system)
    private var didStart = false

    init(firstLine: String, secondLine: String) {
        self.firstLine = MoonRevealLineView(text: firstLine)
        self.secondLine = MoonRevealLineView(text: secondLine)
        super.init()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        view.addSubview(firstLine)
        view.addSubview(secondLine)

        button.configuration = GlassStyle.actionButtonConfiguration(
            title: "Show me how",
            symbol: "arrow.right",
            prominent: true)
        button.configuration?.imagePlacement = .trailing
        button.accessibilityLabel = "Show me how"
        button.alpha = 0
        button.transform = CGAffineTransform(scaleX: 0.92, y: 0.92)
        button.isUserInteractionEnabled = false
        button.addTarget(self, action: #selector(continueTapped), for: .touchUpInside)
        view.addSubview(button)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let inset: CGFloat = 24
        let lineHeight: CGFloat = 44
        let gap: CGFloat = 3
        let contentTop = AppOnboardingLayout.contentTop(in: view.bounds)
        firstLine.frame = CGRect(
            x: inset, y: contentTop,
            width: view.bounds.width - inset * 2, height: lineHeight)
        secondLine.frame = CGRect(
            x: inset, y: firstLine.frame.maxY + gap,
            width: view.bounds.width - inset * 2, height: lineHeight)
        let buttonSize = button.sizeThatFits(CGSize(
            width: view.bounds.width - 40, height: 60))
        button.frame = CGRect(
            x: (view.bounds.width - max(170, buttonSize.width)) / 2,
            y: view.bounds.height - max(54, buttonSize.height) - 24,
            width: max(170, buttonSize.width),
            height: max(54, buttonSize.height))
    }

    func start() {
        guard !didStart else { return }
        didStart = true
        firstLine.reveal(duration: 0.70) { [weak self] in
            guard let self else { return }
            DispatchQueue.main.asyncAfter(
                deadline: .now() + OnboardingAnimationClock.delay(0.38)
            ) {
                self.secondLine.reveal(duration: 0.82) { [weak self] in
                    guard let self else { return }
                    UIView.animate(
                        withDuration: 0.38,
                        delay: 0.16,
                        options: [.curveEaseOut, .beginFromCurrentState]
                    ) {
                        self.button.alpha = 1
                        self.button.transform = .identity
                    } completion: { _ in
                        self.button.isUserInteractionEnabled = true
                        UIAccessibility.post(
                            notification: .layoutChanged,
                            argument: self.button)
                    }
                }
            }
        }
    }

    @objc private func continueTapped() {
        button.isUserInteractionEnabled = false
        UIView.animate(
            withDuration: 0.16,
            animations: {
                self.button.transform = CGAffineTransform(scaleX: 0.96, y: 0.96)
                self.button.alpha = 0.72
            },
            completion: { [weak self] _ in self?.onContinue?() })
    }
}

final class OnboardingBrowserSeedCardContentViewController: CardContentViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
    }
}

/// A black circular occluder moves down over a line. Newly exposed pixels pass
/// through a narrow white bloom before resolving to the ordinary glyphs.
private final class MoonRevealLineView: UIView {
    private let finalLabel = UILabel()
    private let glowLabel = UILabel()
    private let moon = UIView()
    private let glowMask = CAGradientLayer()
    private var didReveal = false

    init(text: String) {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        clipsToBounds = false
        for label in [finalLabel, glowLabel] {
            label.text = text
            label.font = .systemFont(ofSize: 25, weight: .semibold)
            label.textColor = .white
            label.textAlignment = .center
            label.adjustsFontSizeToFitWidth = true
            label.minimumScaleFactor = 0.72
            addSubview(label)
        }
        glowLabel.layer.shadowColor = UIColor.white.cgColor
        glowLabel.layer.shadowRadius = 18
        glowLabel.layer.shadowOpacity = 1
        glowLabel.layer.shadowOffset = .zero
        glowMask.colors = [
            UIColor.clear.cgColor,
            UIColor.white.cgColor,
            UIColor.white.cgColor,
            UIColor.clear.cgColor,
        ]
        glowMask.locations = [0, 0.34, 0.58, 1]
        glowMask.startPoint = CGPoint(x: 0.5, y: 0)
        glowMask.endPoint = CGPoint(x: 0.5, y: 1)
        glowLabel.layer.mask = glowMask

        moon.backgroundColor = .black
        moon.layer.shadowColor = UIColor.white.cgColor
        moon.layer.shadowRadius = 7
        moon.layer.shadowOpacity = 0.16
        moon.layer.shadowOffset = CGSize(width: 0, height: -2)
        addSubview(moon)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        finalLabel.frame = bounds
        glowLabel.frame = bounds
        glowMask.frame = CGRect(
            x: 0, y: -bounds.height * 0.48,
            width: bounds.width, height: bounds.height * 0.58)
        if !didReveal {
            let diameter = max(bounds.width + 40, 240)
            moon.bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
            moon.center = CGPoint(x: bounds.midX, y: bounds.midY)
            moon.layer.cornerRadius = diameter / 2
        }
    }

    func reveal(duration: TimeInterval, completion: @escaping () -> Void) {
        guard !didReveal else {
            completion()
            return
        }
        didReveal = true
        layoutIfNeeded()
        let moonTravel = moon.bounds.height / 2 + bounds.height + 12
        let glowTravel = bounds.height * 1.9
        let resolvedDuration = UIAccessibility.isReduceMotionEnabled ? 0.18 : duration

        UIView.animate(
            withDuration: resolvedDuration,
            delay: 0,
            options: [.curveEaseInOut, .beginFromCurrentState]
        ) {
            self.moon.transform = CGAffineTransform(translationX: 0, y: moonTravel)
        } completion: { _ in
            self.moon.removeFromSuperview()
            self.glowLabel.removeFromSuperview()
            completion()
        }
        let animation = CABasicAnimation(keyPath: "transform.translation.y")
        animation.fromValue = 0
        animation.toValue = glowTravel
        animation.duration = resolvedDuration
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        glowMask.add(animation, forKey: "revealBand")
    }
}
