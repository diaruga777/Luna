//
//  WeeklyPromotionMenu.swift
//  Luna
//

import LunaModels
import LunaSavesUI
import LunaWeekly
import UIKit

/// The long-press verbs every deck grows: propose this save, and — if you hold
/// the key — promote it outright.
///
/// One factory, three call sites (the article, media and product decks), so the
/// wording, the kind mapping and the "a failed save is not a candidate" rule
/// can't drift apart.
///
/// Propose is offered to EVERYONE, key-holder included. Holding the key is a
/// capability, not a mode: the curator still reads the proposal queue, and a
/// pick they want to sit on rather than publish today belongs in it like any
/// other. Hiding the verb from the one device that can also promote would mean
/// the only way to queue a link is to remove your own key.
@MainActor
enum WeeklyPromotionMenu {

    /// The actions to append above Archive/Delete — propose, preceded by
    /// promote for a key-holder. Empty when this item can never be a Save of
    /// the Week.
    static func actions(
        for item: SavedItem,
        presenter: UIViewController,
        refresher: WeeklySaveRefresher? = nil,
        isKeyHolder: Bool = WeeklyPromotionKeyStore.isKeyHolder,
        app: LunaApp = .current
    ) -> [UIAction] {
        guard let kind = weeklyKind(for: item) else { return [] }
        return actions(
            kind: kind, urlString: item.urlString, title: item.title,
            presenter: presenter, refresher: refresher,
            isKeyHolder: isKeyHolder, app: app)
    }

    /// The same verbs for a surface whose saves aren't `SavedItem`s (the
    /// Downloader deck keeps its own `SavedMediaItem` — a type this shared
    /// shell file must not import, since it compiles into all four apps).
    static func actions(
        kind: WeeklySaveKind,
        urlString: String,
        title: String?,
        presenter: UIViewController,
        refresher: WeeklySaveRefresher? = nil,
        isKeyHolder: Bool = WeeklyPromotionKeyStore.isKeyHolder,
        app: LunaApp = .current
    ) -> [UIAction] {
        // Resolved here rather than as a default argument: a default is
        // evaluated in the caller's context, which is not the main actor even
        // though this is, and `WeeklySaveRefresher` is main-actor isolated.
        let refresher = refresher ?? .shared
        var actions: [UIAction] = []
        if isKeyHolder {
            actions.append(UIAction(
                title: WeeklySaveLabels.promoteMenuTitle(for: app),
                image: UIImage(systemName: "crown")
            ) { _ in
                confirmPromotion(
                    kind: kind, urlString: urlString, title: title,
                    presenter: presenter, refresher: refresher, app: app)
            })
        }
        actions.append(UIAction(
            title: WeeklySaveLabels.proposeMenuTitle,
            image: UIImage(systemName: "star.circle")
        ) { _ in
            propose(
                kind: kind, urlString: urlString,
                presenter: presenter, refresher: refresher)
        })
        return actions
    }

    /// A save's kind, in weekly terms. A failed save has no content to stand
    /// behind, so it is never a candidate.
    static func weeklyKind(for item: SavedItem) -> WeeklySaveKind? {
        guard !SavesSectioning.isFailedSave(item), item.state != .failed
        else { return nil }
        if item.isPriceTracker { return .product }
        if item.isPlatformItem { return .media }
        return .article
    }

    // MARK: - Key-holder

    private static func confirmPromotion(
        kind: WeeklySaveKind,
        urlString: String,
        title: String?,
        presenter: UIViewController,
        refresher: WeeklySaveRefresher,
        app: LunaApp
    ) {
        let confirm = UIAlertController(
            title: WeeklySaveLabels.promoteMenuTitle(for: app),
            message: title ?? urlString,
            preferredStyle: .alert)
        confirm.addAction(UIAlertAction(title: L10n.string("Common_cancel"), style: .cancel))
        confirm.addAction(UIAlertAction(
            title: L10n.string("Common_promote"), style: .default
        ) { _ in
            Task { @MainActor in
                do {
                    try await refresher.promote(kind: kind, urlString: urlString)
                    alert(
                        on: presenter,
                        title: L10n.string("SaveOfWeek_promote_successTitle"),
                        message: L10n.string("SaveOfWeek_promote_successMessage"))
                } catch {
                    alert(
                        on: presenter,
                        title: L10n.string("Common_couldntPromote"),
                        message: error.localizedDescription)
                }
            }
        })
        presenter.present(confirm, animated: true)
    }

    // MARK: - Anyone, key-holder included

    private static func propose(
        kind: WeeklySaveKind,
        urlString: String,
        presenter: UIViewController,
        refresher: WeeklySaveRefresher
    ) {
        Task { @MainActor in
            guard await refresher.isSignedIntoICloud() else {
                alert(
                    on: presenter,
                    title: L10n.string("SaveOfWeek_propose_needsICloudTitle"),
                    message: L10n.string("SaveOfWeek_propose_needsICloudMessage"))
                return
            }
            do {
                try await refresher.createProposal(kind: kind, urlString: urlString)
                alert(
                    on: presenter,
                    title: L10n.string("SaveOfWeek_propose_sentTitle"),
                    message: L10n.string("SaveOfWeek_propose_sentMessage"))
            } catch {
                if weeklyCloudErrorIsNotAuthenticated(error) {
                    alert(
                        on: presenter,
                        title: L10n.string("SaveOfWeek_propose_needsICloudTitle"),
                        message: L10n.string("SaveOfWeek_propose_needsICloudMessage"))
                } else {
                    alert(
                        on: presenter,
                        title: L10n.string("SaveOfWeek_propose_couldntProposeTitle"),
                        message: error.localizedDescription)
                }
            }
        }
    }

    private static func alert(on presenter: UIViewController, title: String, message: String) {
        guard presenter.view.window != nil else { return }
        let alert = UIAlertController(
            title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: L10n.string("Common_ok"), style: .default))
        presenter.present(alert, animated: true)
    }
}
