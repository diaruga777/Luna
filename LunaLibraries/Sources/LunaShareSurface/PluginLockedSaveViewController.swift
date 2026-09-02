//
//  PluginLockedSaveViewController.swift
//  LunaShareSurface
//

import LunaDesignSystem
import LunaModels
import UIKit

/// The action extension's answer to a plugin lock
/// (`claudedocs/plans/plugin-platform.md` §8.2).
///
/// The save is made and parked; what is missing is a browser step no extension
/// can show. So the card wears the same lock the in-app locked card wears and
/// says where the rest of it happens. There is nothing to tap here — the app
/// finishes it, from the card or from the launch sweep.
public final class PluginLockedSaveViewController: UIViewController {

    /// Who takes the card's Done.
    @MainActor
    public protocol Delegate: AnyObject {
        func pluginLockedSaveCardDidFinish(_ card: PluginLockedSaveViewController)
    }

    /// Held strongly: the conformer is a small coordinator made for this card
    /// and must outlive the driver that raised it.
    private let delegate: (any Delegate)?
    private let cardView = CardSurfaceView()
    private let doneButton = UIButton(type: .system)

    public init(delegate: (any Delegate)?) {
        self.delegate = delegate
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("not used") }

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = LunaColors.background

        let overlay = LockedCardOverlayView(caption: L10n.string("PluginLockedOpenLuna"))
        overlay.translatesAutoresizingMaskIntoConstraints = false
        cardView.translatesAutoresizingMaskIntoConstraints = false
        cardView.addSubview(overlay)
        view.addSubview(cardView)

        var configuration = UIButton.Configuration.borderedProminent()
        configuration.title = L10n.string("Common_done")
        configuration.cornerStyle = .large
        doneButton.configuration = configuration
        doneButton.translatesAutoresizingMaskIntoConstraints = false
        doneButton.addAction(
            UIAction { [weak self] _ in
                guard let self else { return }
                self.delegate?.pluginLockedSaveCardDidFinish(self)
            },
            for: .touchUpInside)
        view.addSubview(doneButton)

        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            cardView.topAnchor.constraint(equalTo: guide.topAnchor, constant: 16),
            cardView.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 16),
            cardView.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -16),
            doneButton.topAnchor.constraint(equalTo: cardView.bottomAnchor, constant: 16),
            doneButton.centerXAnchor.constraint(equalTo: guide.centerXAnchor),
            doneButton.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -16),
            overlay.topAnchor.constraint(equalTo: cardView.topAnchor),
            overlay.bottomAnchor.constraint(equalTo: cardView.bottomAnchor),
            overlay.leadingAnchor.constraint(equalTo: cardView.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: cardView.trailingAnchor),
        ])
    }
}
