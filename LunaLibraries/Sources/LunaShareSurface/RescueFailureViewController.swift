//
//  RescueFailureViewController.swift
//  LunaShareSurface
//

import LunaDesignSystem
import LunaModels
import UIKit

/// The extension failure card shown when a share/action save can't be loaded.
/// Instead of a dead-end red triangle, it offers to finish the save with Apple
/// Intelligence in the main app: pick what the save should become, then tap
/// "Finish in Luna" (writes a pending-rescue record + best-effort opens the
/// containing app). No LLM code here — the extension only records the request.
public final class RescueFailureViewController: UIViewController {
    private let defaultHint: RescueHint
    private let rescueURL: URL?
    private let openApp: (URL) -> Void
    private let onFinish: (RescueHint) -> Void
    private let onDone: () -> Void

    private let segmented = UISegmentedControl(items: RescueHint.allCases.map(\.displayName))
    private lazy var primaryButton = UIButton(type: .system)
    private let manualLabel = UILabel()
    private lazy var doneButton = UIButton(type: .system)

    /// - rescueURL: this app's `<scheme>://rescue` deep link (built by the driver);
    ///   nil ⇒ only the manual "Open Luna" instruction is shown.
    /// - openApp: best-effort deep-link open (host.openURL — extensions can't
    ///   observe whether it succeeded, so the card always then shows the manual
    ///   "Open Luna to finish saving" reassurance; the app's foreground drain
    ///   picks the record up regardless).
    /// - onFinish: records the pending rescue for the chosen hint.
    public init(
        defaultHint: RescueHint,
        rescueURL: URL?,
        openApp: @escaping (URL) -> Void,
        onFinish: @escaping (RescueHint) -> Void,
        onDone: @escaping () -> Void
    ) {
        self.defaultHint = defaultHint
        self.rescueURL = rescueURL
        self.openApp = openApp
        self.onFinish = onFinish
        self.onDone = onDone
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = LunaColors.background
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .cancel, target: self, action: #selector(cancelTapped))

        let icon = UIImageView(image: UIImage(
            systemName: "exclamationmark.triangle.fill",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 40, weight: .semibold)))
        icon.tintColor = .systemOrange
        icon.contentMode = .center

        let title = UILabel()
        title.text = "Couldn't load this page."
        title.textColor = LunaColors.primaryText
        title.font = .preferredFont(forTextStyle: .headline)
        title.textAlignment = .center
        title.numberOfLines = 0

        let body = UILabel()
        body.text = "Luna can try again with Apple Intelligence the next time you open it. "
            + "What should this save become?"
        body.textColor = LunaColors.secondaryText
        body.font = .preferredFont(forTextStyle: .subheadline)
        body.textAlignment = .center
        body.numberOfLines = 0

        segmented.selectedSegmentIndex = RescueHint.allCases.firstIndex(of: defaultHint) ?? 0

        primaryButton.setTitle("Finish in Luna", for: .normal)
        primaryButton.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        primaryButton.addTarget(self, action: #selector(finishTapped), for: .touchUpInside)

        manualLabel.text = "Open Luna to finish saving this."
        manualLabel.textColor = LunaColors.secondaryText
        manualLabel.font = .preferredFont(forTextStyle: .footnote)
        manualLabel.textAlignment = .center
        manualLabel.numberOfLines = 0
        manualLabel.isHidden = true

        doneButton.setTitle("Done", for: .normal)
        doneButton.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        doneButton.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)
        doneButton.isHidden = true

        let notNow = UIButton(type: .system)
        notNow.setTitle("Not Now", for: .normal)
        notNow.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [icon, title, body, segmented, primaryButton, manualLabel, doneButton, notNow])
        stack.axis = .vertical
        stack.spacing = 16
        stack.alignment = .center
        stack.setCustomSpacing(24, after: body)
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 32),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -32),
        ])
    }

    private var selectedHint: RescueHint {
        RescueHint.allCases[safe: segmented.selectedSegmentIndex] ?? defaultHint
    }

    @objc private func finishTapped() {
        onFinish(selectedHint)   // record the pending request first — so the open never loses it
        if let url = rescueURL { openApp(url) }
        // We can't observe whether the deep-link open succeeded from an extension,
        // so always leave the manual instruction (the app's foreground drain is the
        // real guarantee).
        segmented.isEnabled = false
        primaryButton.isHidden = true
        manualLabel.isHidden = false
        doneButton.isHidden = false
    }

    @objc private func cancelTapped() { onDone() }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
