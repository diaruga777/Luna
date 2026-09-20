//
//  RecoveryFileIntake.swift
//  Luna
//
//  The app's half of the Luna file intake seam: a recovery file that reached
//  this process — through Open In, the Files app, or a shared code block —
//  becomes a finished save (`claudedocs/luna-file.md`).
//
//  Universal (no membership exception): every type it names is universal-tier,
//  so it compiles into all four app targets, and all four install it. Recovery
//  is not a per-kind capability — an app that shows a kind can recover it.
//

import LunaDesignSystem
import LunaModels
import LunaSaves
import LunaSavesUI
import UIKit

/// Applies an arriving recovery file and puts the user where the result is.
@MainActor
final class RecoveryFileIntake: LunaRecoveryFileHandling {

    func handleRecovery(_ file: LunaRecoveryFile, sourceURL: URL?) {
        Task { @MainActor in
            switch await RecoveryFileApplier.shared.apply(file) {
            case let .recovered(itemID):
                centerDeck(on: itemID)
            case let .dropped(owner):
                presentUnsupported(owner: owner)
            case .failed:
                // The reason is on the save's own card, which the deck is
                // already showing or is about to reload: `.savesChanged` fired
                // when the item was reserved, and the card reads the applier
                // for the line under its offer.
                break
            }
        }
    }

    /// Lands on the recovered save, the same way the media deep link lands on a
    /// finished download.
    private func centerDeck(on itemID: UUID) {
        guard let root = AppDelegate.frontmostViewController() else { return }
        let navigation = root as? UINavigationController
            ?? root.navigationController
            ?? (root.presentingViewController as? UINavigationController)
        navigation?.popToRootViewController(animated: false)
        let deck = navigation?.viewControllers.first as? CardCarouselHostViewController
        _ = deck?.centerCard(onItemID: itemID)
    }

    /// The same card a foreign kind gets from any other surface.
    private func presentUnsupported(owner: LunaApp) {
        guard let presenter = AppDelegate.frontmostViewController() else { return }
        let card = UnsupportedSaveCardViewController(owner: owner)
        card.modalPresentationStyle = .fullScreen
        card.delegate = RecoveryDropCardDismisser.shared
        presenter.present(card, animated: true)
    }
}

/// Done takes the drop card back down. Stateless, and a `static let` because
/// the card holds its delegate weakly.
@MainActor
private final class RecoveryDropCardDismisser: UnsupportedSaveCardDelegate {
    static let shared = RecoveryDropCardDismisser()

    func unsupportedSaveCardDidFinish(_ card: UnsupportedSaveCardViewController) {
        card.dismiss(animated: true)
    }
}
