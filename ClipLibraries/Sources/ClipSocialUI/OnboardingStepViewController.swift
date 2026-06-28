//
//  OnboardingStepViewController.swift
//  Clip
//

import ClipDesignSystem
import UIKit

/// A single onboarding step: an icon, a title, an explanation, an optional
/// primary action button, and a continue/done button that advances the flow.
public final class OnboardingStepViewController: UIViewController {

    /// A labelled primary action (e.g. "Enable Notifications").
    public struct PrimaryAction {
        public let title: String
        public let handler: (OnboardingStepViewController) -> Void

        public init(title: String, handler: @escaping (OnboardingStepViewController) -> Void) {
            self.title = title
            self.handler = handler
        }
    }

    private let symbolName: String
    private let stepTitle: String
    private let body: String
    private let primaryAction: PrimaryAction?
    private let secondaryAction: PrimaryAction?
    private let continueTitle: String
    private let onContinue: () -> Void
    /// When set, a looping illustration of the iOS change replaces the static icon.
    private let animationKind: OnboardingAnimationView.Kind?
    private var animationView: OnboardingAnimationView?

    private let primaryButton = UIButton(type: .system)
    private let secondaryButton = UIButton(type: .system)

    public init(symbol: String, title: String, body: String,
         primary: PrimaryAction?, secondary: PrimaryAction? = nil, continueTitle: String,
         animation: OnboardingAnimationView.Kind? = nil,
         onContinue: @escaping () -> Void) {
        self.symbolName = symbol
        self.stepTitle = title
        self.body = body
        self.primaryAction = primary
        self.secondaryAction = secondary
        self.continueTitle = continueTitle
        self.animationKind = animation
        self.onContinue = onContinue
        super.init(nibName: nil, bundle: nil)
    }

    public required init?(coder: NSCoder) { fatalError("not used") }

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        navigationItem.hidesBackButton = true

        // An animated illustration of the iOS change, or the static icon.
        let topVisual: UIView
        if let animationKind {
            let animation = OnboardingAnimationView(kind: animationKind)
            animationView = animation
            topVisual = animation
        } else {
            let icon = UIImageView(image: UIImage(systemName: symbolName,
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 64, weight: .semibold)))
            icon.tintColor = GlassStyle.readingAccent
            icon.contentMode = .center
            topVisual = icon
        }
        let icon = topVisual

        let titleLabel = UILabel()
        titleLabel.text = stepTitle
        titleLabel.font = .systemFont(ofSize: 28, weight: .bold)
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 0

        let bodyLabel = UILabel()
        bodyLabel.text = body
        bodyLabel.font = .preferredFont(forTextStyle: .body)
        bodyLabel.textColor = .secondaryLabel
        bodyLabel.textAlignment = .center
        bodyLabel.numberOfLines = 0

        let topStack = UIStackView(arrangedSubviews: [icon, titleLabel, bodyLabel])
        topStack.axis = .vertical
        topStack.spacing = 16
        topStack.setCustomSpacing(24, after: icon)

        let buttonStack = UIStackView()
        buttonStack.axis = .vertical
        buttonStack.spacing = 10

        if let primaryAction {
            primaryButton.setTitle(primaryAction.title, for: .normal)
            primaryButton.titleLabel?.font = .systemFont(ofSize: 19, weight: .semibold)
            primaryButton.backgroundColor = GlassStyle.readingAccent
            primaryButton.setTitleColor(.white, for: .normal)
            primaryButton.layer.cornerRadius = 14
            primaryButton.heightAnchor.constraint(equalToConstant: 52).isActive = true
            primaryButton.addTarget(self, action: #selector(primaryTapped), for: .touchUpInside)
            buttonStack.addArrangedSubview(primaryButton)
        }

        if let secondaryAction {
            secondaryButton.setTitle(secondaryAction.title, for: .normal)
            secondaryButton.titleLabel?.font = .systemFont(ofSize: 17, weight: .medium)
            secondaryButton.tintColor = GlassStyle.readingAccent
            secondaryButton.addTarget(self, action: #selector(secondaryTapped), for: .touchUpInside)
            buttonStack.addArrangedSubview(secondaryButton)
        }

        let continueButton = UIButton(type: .system)
        continueButton.setTitle(continueTitle, for: .normal)
        continueButton.titleLabel?.font = .systemFont(ofSize: 17, weight: .medium)
        continueButton.tintColor = primaryAction == nil ? .white : GlassStyle.readingAccent
        if primaryAction == nil {
            continueButton.backgroundColor = GlassStyle.readingAccent
            continueButton.layer.cornerRadius = 14
            continueButton.heightAnchor.constraint(equalToConstant: 52).isActive = true
        }
        continueButton.addTarget(self, action: #selector(continueTapped), for: .touchUpInside)
        buttonStack.addArrangedSubview(continueButton)

        // The buttons are pinned at the bottom (always full size — never compressed
        // into overlap); the icon/title/body scroll above them when they're too tall
        // for the screen (e.g. the large action-extension animation + long body), and
        // center when they fit.
        buttonStack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(buttonStack)

        let scroll = UIScrollView()
        scroll.showsVerticalScrollIndicator = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        let content = UIView()
        content.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(content)
        topStack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(topStack)

        let contentFillsScroll = content.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor)
        contentFillsScroll.priority = .defaultLow   // only as tall as the scroll area when content is short → centers

        NSLayoutConstraint.activate([
            buttonStack.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            buttonStack.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            buttonStack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -20),

            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: buttonStack.topAnchor, constant: -16),

            content.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            content.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            content.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),
            contentFillsScroll,

            topStack.topAnchor.constraint(greaterThanOrEqualTo: content.topAnchor, constant: 16),
            topStack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -16),
            topStack.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            topStack.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            topStack.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
        ])
    }

    public override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        animationView?.start()
    }

    @objc private func primaryTapped() { primaryAction?.handler(self) }
    @objc private func secondaryTapped() { secondaryAction?.handler(self) }
    @objc private func continueTapped() { onContinue() }
}
