//
//  OnboardingStepViewController.swift
//  Clip
//

import UIKit

/// A single onboarding step: an icon, a title, an explanation, an optional
/// primary action button, and a continue/done button that advances the flow.
final class OnboardingStepViewController: UIViewController {

    /// A labelled primary action (e.g. "Enable Notifications").
    struct PrimaryAction {
        let title: String
        let handler: (OnboardingStepViewController) -> Void
    }

    private let symbolName: String
    private let stepTitle: String
    private let body: String
    private let primaryAction: PrimaryAction?
    private let continueTitle: String
    private let onContinue: () -> Void
    /// When set, a looping illustration of the iOS change replaces the static icon.
    private let animationKind: OnboardingAnimationView.Kind?
    private var animationView: OnboardingAnimationView?

    private let primaryButton = UIButton(type: .system)

    init(symbol: String, title: String, body: String,
         primary: PrimaryAction?, continueTitle: String,
         animation: OnboardingAnimationView.Kind? = nil,
         onContinue: @escaping () -> Void) {
        self.symbolName = symbol
        self.stepTitle = title
        self.body = body
        self.primaryAction = primary
        self.continueTitle = continueTitle
        self.animationKind = animation
        self.onContinue = onContinue
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidLoad() {
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

        let layout = UIStackView(arrangedSubviews: [topStack, UIView(), buttonStack])
        layout.axis = .vertical
        layout.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(layout)
        NSLayoutConstraint.activate([
            layout.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            layout.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            layout.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 60),
            layout.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -32),
        ])
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        animationView?.start()
    }

    @objc private func primaryTapped() { primaryAction?.handler(self) }
    @objc private func continueTapped() { onContinue() }
}
