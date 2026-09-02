//
//  PluginLockedSaveCard.swift
//  LunaSavesUI
//

import LunaDesignSystem
import LunaModels
import UIKit

/// Presents the browser step a plugin-locked save is waiting on
/// (`claudedocs/plans/plugin-platform.md` §8.3).
///
/// `PluginUnlockFlow` (LunaPluginUI) is the witness. It sits here so the three
/// card presenters — compiled into the sibling apps too — can route a locked tap
/// without naming a plugin type: an app that links no plugin platform installs
/// nothing and its lock stays a lock.
@MainActor
public protocol PluginLockedSavePresenting: AnyObject {
    func presentPluginUnlock(for item: SavedItem, from presenter: UIViewController)
}

/// The installed unlock route. The central app's `PluginUIComposition.install()`
/// is the only writer.
public enum PluginLockedSaves {
    @MainActor public static var presenter: (any PluginLockedSavePresenting)?

    /// Routes a locked save's tap. False when nothing is installed to take it,
    /// so the caller can fall back to its kind's own behaviour.
    @discardableResult
    @MainActor
    public static func presentUnlock(
        for item: SavedItem, from presenter: UIViewController
    ) -> Bool {
        guard item.isPluginLocked, let route = Self.presenter else { return false }
        route.presentPluginUnlock(for: item, from: presenter)
        return true
    }
}

/// The card face of a plugin-locked save of any kind.
///
/// A media or product save that a plugin parked has nothing of its own to draw
/// — no downloaded file, no tracker — so its card wears the same lock the
/// paywalled article card wears. The overlay takes no touches, so the card's own
/// tap (the unlock flow) and long-press (Archive / Delete) still land.
public final class PluginLockedCardContentViewController: CardContentViewController {

    private let caption: String

    public init(caption: String) {
        self.caption = caption
        super.init()
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        let overlay = LockedCardOverlayView(caption: caption)
        overlay.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(overlay)
        NSLayoutConstraint.activate([
            overlay.topAnchor.constraint(equalTo: view.topAnchor),
            overlay.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            overlay.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
    }
}
