//
//  OnboardingStepViewController.swift
//  Luna
//

import LunaDesignSystem
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

    /// This step's position in the flow, shown as a dot-matrix progress row.
    public struct Progress {
        public let index: Int
        public let total: Int

        public init(index: Int, total: Int) {
            self.index = index
            self.total = total
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
    private let progress: Progress?

    private let primaryButton = UIButton(type: .system)
    private let secondaryButton = UIButton(type: .system)
    private let continueButton = UIButton(type: .system)
    private let bodyLabel = UILabel()

    /// Called once, from `viewDidAppear`, every time this step becomes visible.
    public var onDidAppear: (() -> Void)?
    /// Called on `UIApplication.willEnterForegroundNotification` while this step
    /// is on screen (observed between `viewDidAppear` and `viewWillDisappear`).
    public var onWillEnterForeground: (() -> Void)?
    private var foregroundObserver: NSObjectProtocol?

    public init(symbol: String, title: String, body: String,
         primary: PrimaryAction?, secondary: PrimaryAction? = nil, continueTitle: String,
         animation: OnboardingAnimationView.Kind? = nil,
         progress: Progress? = nil,
         onContinue: @escaping () -> Void) {
        self.symbolName = symbol
        self.stepTitle = title
        self.body = body
        self.primaryAction = primary
        self.secondaryAction = secondary
        self.continueTitle = continueTitle
        self.animationKind = animation
        self.progress = progress
        self.onContinue = onContinue
        super.init(nibName: nil, bundle: nil)
    }

    public required init?(coder: NSCoder) { fatalError("not used") }

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = LunaColors.background
        navigationItem.hidesBackButton = true

        let accent = GlassStyle.lunaBrandAccent

        // An animated illustration of the iOS change, or — for steps without one —
        // the step's SF symbol in a brand-colored app-icon-style rounded tile.
        let topVisual: UIView
        if let animationKind {
            let animation = OnboardingAnimationView(kind: animationKind)
            animationView = animation
            topVisual = animation
        } else {
            topVisual = Self.iconTile(symbol: symbolName, accent: accent)
        }

        // The visual sits on a plain background.
        let visualPanel = UIView()
        topVisual.translatesAutoresizingMaskIntoConstraints = false
        visualPanel.addSubview(topVisual)
        let panelHugsVisual = visualPanel.heightAnchor.constraint(equalTo: topVisual.heightAnchor, constant: 32)
        panelHugsVisual.priority = .defaultHigh
        NSLayoutConstraint.activate([
            topVisual.centerXAnchor.constraint(equalTo: visualPanel.centerXAnchor),
            topVisual.centerYAnchor.constraint(equalTo: visualPanel.centerYAnchor),
            panelHugsVisual,
            visualPanel.heightAnchor.constraint(greaterThanOrEqualToConstant: 140),
        ])

        let titleLabel = UILabel()
        titleLabel.text = stepTitle
        titleLabel.font = .systemFont(ofSize: 28, weight: .bold)
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 0

        bodyLabel.text = body
        bodyLabel.font = .preferredFont(forTextStyle: .body)
        bodyLabel.textColor = LunaColors.secondaryText
        bodyLabel.textAlignment = .center
        bodyLabel.numberOfLines = 0

        let topStack = UIStackView(arrangedSubviews: [visualPanel, titleLabel, bodyLabel])
        topStack.axis = .vertical
        topStack.spacing = 16
        topStack.setCustomSpacing(24, after: visualPanel)

        let buttonStack = UIStackView()
        buttonStack.axis = .vertical
        buttonStack.spacing = 10

        if let primaryAction {
            primaryButton.setTitle(primaryAction.title, for: .normal)
            primaryButton.titleLabel?.font = .systemFont(ofSize: 19, weight: .semibold)
            primaryButton.backgroundColor = accent
            primaryButton.setTitleColor(.white, for: .normal)
            primaryButton.layer.cornerRadius = 14
            primaryButton.heightAnchor.constraint(equalToConstant: 52).isActive = true
            primaryButton.addTarget(self, action: #selector(primaryTapped), for: .touchUpInside)
            buttonStack.addArrangedSubview(primaryButton)
        }

        if let secondaryAction {
            secondaryButton.setTitle(secondaryAction.title, for: .normal)
            secondaryButton.titleLabel?.font = .systemFont(ofSize: 17, weight: .medium)
            secondaryButton.tintColor = accent
            secondaryButton.addTarget(self, action: #selector(secondaryTapped), for: .touchUpInside)
            buttonStack.addArrangedSubview(secondaryButton)
        }

        continueButton.setTitle(continueTitle, for: .normal)
        continueButton.titleLabel?.font = .systemFont(ofSize: 17, weight: .medium)
        continueButton.tintColor = primaryAction == nil ? .white : accent
        if primaryAction == nil {
            continueButton.backgroundColor = accent
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

        // Step-progress dots, pinned above the scroll area so they never scroll away.
        var scrollTopAnchor = view.safeAreaLayoutGuide.topAnchor
        var scrollTopInset: CGFloat = 12
        if let progress {
            let progressView = OnboardingDotMatrixProgressView(
                currentIndex: progress.index, totalSteps: progress.total)
            progressView.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(progressView)
            NSLayoutConstraint.activate([
                progressView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
                progressView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            ])
            scrollTopAnchor = progressView.bottomAnchor
            scrollTopInset = 8
        }

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

            scroll.topAnchor.constraint(equalTo: scrollTopAnchor, constant: scrollTopInset),
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
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            // Repeating UIKit animations are removed when the app is suspended.
            // Restart the inline guide before reacting to the return from PiP.
            self.animationView?.start()
            self.onWillEnterForeground?()
        }
        onDidAppear?()
    }

    public override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        animationView?.stop()
        if let foregroundObserver {
            NotificationCenter.default.removeObserver(foregroundObserver)
        }
        foregroundObserver = nil
    }

    deinit {
        if let foregroundObserver {
            NotificationCenter.default.removeObserver(foregroundObserver)
        }
    }

    /// Updates the body copy in place (e.g. once the user has partially completed
    /// the step's out-of-app action and the step wants to nudge them further).
    public func updateBody(_ text: String) {
        bodyLabel.text = text
    }

    /// Updates the continue/done button's title in place.
    public func updateContinueTitle(_ title: String) {
        continueButton.setTitle(title, for: .normal)
    }

    /// Installs `view` (a muted, looping PiP-source video layer) behind the
    /// animation illustration, small and centered — the illustration's opaque phone
    /// mockup fully covers it, so it is never visible on screen (the illustrations
    /// are transparent around the mockup, so pinning it to the full animation frame
    /// would let the unsynchronized video peek out around the edges). It still
    /// counts as on-screen and playing for AVKit, which is all Picture-in-Picture
    /// needs to hand off. Idempotent per view; a no-op if this step has no
    /// animation (nothing to tuck behind).
    public func installBackdropView(_ view: UIView) {
        guard let animationView, let superview = animationView.superview,
              view.superview !== superview else { return }
        view.translatesAutoresizingMaskIntoConstraints = false
        superview.insertSubview(view, belowSubview: animationView)
        NSLayoutConstraint.activate([
            view.centerXAnchor.constraint(equalTo: animationView.centerXAnchor),
            view.centerYAnchor.constraint(equalTo: animationView.centerYAnchor),
            view.widthAnchor.constraint(equalToConstant: 40),
            view.heightAnchor.constraint(equalToConstant: 40),
        ])
    }

    /// A brand-colored, app-icon-style rounded tile holding the step's SF symbol —
    /// the "hero" visual for steps without a live illustration (e.g. the email step),
    /// so a lone glyph on white doesn't read as unfinished.
    private static func iconTile(symbol: String, accent: UIColor) -> UIView {
        let tile = UIView()
        tile.backgroundColor = accent
        tile.layer.cornerRadius = 26
        tile.layer.cornerCurve = .continuous
        tile.translatesAutoresizingMaskIntoConstraints = false

        let glyph = UIImageView(image: UIImage(systemName: symbol,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 52, weight: .semibold)))
        glyph.tintColor = .white
        glyph.contentMode = .center
        glyph.translatesAutoresizingMaskIntoConstraints = false
        tile.addSubview(glyph)
        NSLayoutConstraint.activate([
            tile.widthAnchor.constraint(equalToConstant: 108),
            tile.heightAnchor.constraint(equalToConstant: 108),
            glyph.centerXAnchor.constraint(equalTo: tile.centerXAnchor),
            glyph.centerYAnchor.constraint(equalTo: tile.centerYAnchor),
        ])
        return tile
    }

    @objc private func primaryTapped() { primaryAction?.handler(self) }
    @objc private func secondaryTapped() { secondaryAction?.handler(self) }
    @objc private func continueTapped() { onContinue() }
}
