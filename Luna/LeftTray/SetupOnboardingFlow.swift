//
//  SetupOnboardingFlow.swift
//  Luna
//

import LunaDesignSystem
import UIKit

/// Independent setup destinations recovered from the former first-launch
/// onboarding. They retain that flow's focused, illustrated one-step shape,
/// without reintroducing a completion gate around the app.
enum SetupOnboardingFlow {
    /// Installed only by article-capable composition roots. Keeping this seam
    /// here prevents Downloader from linking the email settings screen it can
    /// never present.
    static var openEmailSetup: ((UIViewController) -> Void)?

    static func present(_ kind: LeftTraySetupKind, from presenter: UIViewController) {
        let screen: SetupStepViewController
        switch kind {
        case .safari:
            screen = SetupStepViewController(
                symbol: "safari",
                title: "Unlock and save from Safari",
                body: "Turn on the Luna Safari extension to keep a private recent trail and add Luna actions while you browse.",
                primaryTitle: "Open Safari",
                primaryAction: {
                    if let url = URL(string: "https://en.wikipedia.org/wiki/Wikipedia") {
                        UIApplication.shared.open(url)
                    }
                },
                secondaryTitle: "Open Settings",
                secondaryAction: { SystemSettingsLink.open() })
        case .shortcut:
            screen = SetupStepViewController(
                symbol: "square.and.arrow.down.on.square",
                title: "Save anything, instantly",
                body: "Import “\(BundledShortcut.displayName)” into Shortcuts, then assign it to your Action Button.",
                primaryTitle: "Install Shortcut",
                primaryAction: { [weak presenter] in
                    guard let presenter else { return }
                    BundledShortcut.presentInstaller(from: presenter)
                },
                secondaryTitle: "Set Action Button",
                secondaryAction: { SystemSettingsLink.openActionButton() })
        case .email:
            screen = SetupStepViewController(
                symbol: "envelope.badge.fill",
                title: "Connect your email",
                body: "Use one shared account to send articles, import links, and deliver reading to your Kindle.",
                primaryTitle: "Connect Email",
                primaryAction: { [weak presenter] in
                    presenter?.dismiss(animated: true) {
                        guard let presenter else { return }
                        openEmailSetup?(presenter)
                    }
                })
        }
        let nav = UINavigationController(rootViewController: screen)
        nav.modalPresentationStyle = .pageSheet
        presenter.present(nav, animated: true)
    }
}

/// The reusable visual core of the deleted onboarding screen: a tinted hero
/// tile, concise explanation, and pinned setup actions.
private final class SetupStepViewController: UIViewController {
    private let symbol: String
    private let heading: String
    private let body: String
    private let primaryTitle: String
    private let primaryAction: () -> Void
    private let secondaryTitle: String?
    private let secondaryAction: (() -> Void)?

    init(
        symbol: String, title: String, body: String,
        primaryTitle: String, primaryAction: @escaping () -> Void,
        secondaryTitle: String? = nil, secondaryAction: (() -> Void)? = nil
    ) {
        self.symbol = symbol
        self.heading = title
        self.body = body
        self.primaryTitle = primaryTitle
        self.primaryAction = primaryAction
        self.secondaryTitle = secondaryTitle
        self.secondaryAction = secondaryAction
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = LunaColors.background
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            systemItem: .done, primaryAction: UIAction { [weak self] _ in
                self?.dismiss(animated: true)
            })

        let tint = LunaSurfacePalette.baseColor
        let tile = UIView()
        tile.backgroundColor = tint.withAlphaComponent(0.20)
        tile.layer.cornerRadius = 30
        tile.layer.cornerCurve = .continuous
        tile.layer.borderWidth = 1
        tile.layer.borderColor = tint.withAlphaComponent(0.55).cgColor
        tile.layer.shadowColor = tint.cgColor
        tile.layer.shadowOpacity = 0.24
        tile.layer.shadowRadius = 18
        tile.layer.shadowOffset = .zero
        tile.translatesAutoresizingMaskIntoConstraints = false

        let icon = UIImageView(image: UIImage(
            systemName: symbol,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 54, weight: .semibold)))
        icon.tintColor = tint
        icon.translatesAutoresizingMaskIntoConstraints = false
        tile.addSubview(icon)

        let titleLabel = UILabel()
        titleLabel.text = heading
        titleLabel.font = .systemFont(ofSize: 28, weight: .bold)
        titleLabel.textColor = LunaColors.primaryText
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 0

        let bodyLabel = UILabel()
        bodyLabel.text = body
        bodyLabel.font = .preferredFont(forTextStyle: .body)
        bodyLabel.textColor = LunaColors.secondaryText
        bodyLabel.textAlignment = .center
        bodyLabel.numberOfLines = 0

        let primary = UIButton(type: .system)
        primary.configuration = GlassStyle.actionButtonConfiguration(
            title: primaryTitle, symbol: symbol, prominent: true)
        primary.addAction(UIAction { [weak self] _ in self?.primaryAction() }, for: .touchUpInside)
        primary.heightAnchor.constraint(equalToConstant: 52).isActive = true

        var arranged: [UIView] = [tile, titleLabel, bodyLabel, primary]
        if let secondaryTitle, let secondaryAction {
            let secondary = UIButton(type: .system)
            secondary.configuration = GlassStyle.actionButtonConfiguration(
                title: secondaryTitle, symbol: "arrow.up.forward.app")
            secondary.addAction(UIAction { _ in secondaryAction() }, for: .touchUpInside)
            secondary.heightAnchor.constraint(equalToConstant: 48).isActive = true
            arranged.append(secondary)
        }
        let stack = UIStackView(arrangedSubviews: arranged)
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 18
        stack.setCustomSpacing(30, after: tile)
        stack.setCustomSpacing(28, after: bodyLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            tile.widthAnchor.constraint(equalToConstant: 126),
            tile.heightAnchor.constraint(equalToConstant: 126),
            tile.centerXAnchor.constraint(equalTo: stack.centerXAnchor),
            icon.centerXAnchor.constraint(equalTo: tile.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: tile.centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }
}
