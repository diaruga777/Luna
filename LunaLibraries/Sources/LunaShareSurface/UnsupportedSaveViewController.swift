//
//  UnsupportedSaveViewController.swift
//  LunaShareSurface
//

import LunaDesignSystem
import LunaIngest
import LunaModels
import UIKit

/// The extension error card shown when a classified save belongs to a content
/// kind this app doesn't handle (`SurfaceSupport`): nothing was saved, so the
/// card never shows a checkmark. The copy is the same generic explanation the
/// main app's alert uses; the App Store upsell for the owning app slots in
/// here once that link exists.
public final class UnsupportedSaveViewController: UIViewController {
    private let owner: LunaApp
    private let currentApp: LunaApp

    /// Runs when the user dismisses the card (the host completes silently).
    public var onDone: (() -> Void)?

    public init(owner: LunaApp, currentApp: LunaApp) {
        self.owner = owner
        self.currentApp = currentApp
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = LunaColors.background
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .done, target: self, action: #selector(doneTapped))

        let icon = UIImageView(image: UIImage(
            systemName: "exclamationmark.triangle.fill",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 40, weight: .semibold)))
        icon.tintColor = .systemOrange
        icon.contentMode = .center

        let title = UILabel()
        title.text = "Can't Save This Link"
        title.textColor = LunaColors.primaryText
        title.font = .preferredFont(forTextStyle: .headline)
        title.textAlignment = .center
        title.numberOfLines = 0

        let body = UILabel()
        body.text = SurfaceSupport.unsupportedMessage(owner: owner, current: currentApp)
        body.textColor = LunaColors.secondaryText
        body.font = .preferredFont(forTextStyle: .subheadline)
        body.textAlignment = .center
        body.numberOfLines = 0

        let stack = UIStackView(arrangedSubviews: [icon, title, body])
        stack.axis = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
        ])
    }

    @objc private func doneTapped() {
        onDone?()
    }
}
