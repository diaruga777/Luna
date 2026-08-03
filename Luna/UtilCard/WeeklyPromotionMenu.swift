//
//  WeeklyPromotionMenu.swift
//  Luna
//

import LunaModels
import LunaReadingListUI
import LunaWeekly
import UIKit

/// The long-press verb every deck grows: promote this save, if you hold the
/// key, or propose it if you don't.
///
/// One factory, three call sites (the article, media and product decks), so the
/// wording, the kind mapping and the "a failed save is not a candidate" rule
/// can't drift apart.
@MainActor
enum WeeklyPromotionMenu {

    /// The action to append above Archive/Delete, or nil when this item can
    /// never be a Save of the Week.
    static func action(
        for item: ReadingListItem,
        presenter: UIViewController,
        refresher: WeeklySaveRefresher = .shared,
        isKeyHolder: Bool = WeeklyPromotionKeyStore.isKeyHolder,
        app: LunaApp = .current
    ) -> UIAction? {
        guard let kind = weeklyKind(for: item) else { return nil }
        return action(
            kind: kind, urlString: item.urlString, title: item.title,
            presenter: presenter, refresher: refresher,
            isKeyHolder: isKeyHolder, app: app)
    }

    /// The same verb for a surface whose saves aren't `ReadingListItem`s (the
    /// Downloader deck keeps its own `SavedMediaItem` — a type this shared
    /// shell file must not import, since it compiles into all four apps).
    static func action(
        kind: WeeklySaveKind,
        urlString: String,
        title: String?,
        presenter: UIViewController,
        refresher: WeeklySaveRefresher = .shared,
        isKeyHolder: Bool = WeeklyPromotionKeyStore.isKeyHolder,
        app: LunaApp = .current
    ) -> UIAction {
        if isKeyHolder {
            return UIAction(
                title: WeeklySaveLabels.promoteMenuTitle(for: app),
                image: UIImage(systemName: "crown")
            ) { _ in
                confirmPromotion(
                    kind: kind, urlString: urlString, title: title,
                    presenter: presenter, refresher: refresher, app: app)
            }
        }
        return UIAction(
            title: WeeklySaveLabels.proposeMenuTitle,
            image: UIImage(systemName: "star.circle")
        ) { _ in
            propose(
                kind: kind, urlString: urlString,
                presenter: presenter, refresher: refresher)
        }
    }

    /// A save's kind, in weekly terms. A failed save has no content to stand
    /// behind, so it is never a candidate.
    static func weeklyKind(for item: ReadingListItem) -> WeeklySaveKind? {
        guard !ReadingListSectioning.isFailedSave(item), item.state != .failed
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
        confirm.addAction(UIAlertAction(title: L10n.string("Cancel"), style: .cancel))
        confirm.addAction(UIAlertAction(
            title: L10n.string("Promote"), style: .default
        ) { _ in
            Task { @MainActor in
                do {
                    try await refresher.promote(kind: kind, urlString: urlString)
                    alert(
                        on: presenter,
                        title: L10n.string("Promoted"),
                        message: L10n.string("Every Luna will show it on its next check."))
                } catch {
                    alert(
                        on: presenter,
                        title: L10n.string("Couldn't Promote"),
                        message: error.localizedDescription)
                }
            }
        })
        presenter.present(confirm, animated: true)
    }

    // MARK: - Everyone else

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
                    title: L10n.string("Sign in to iCloud"),
                    message: L10n.string(
                        "Proposing a Save of the Week needs an iCloud account. Sign in from Settings and try again."))
                return
            }
            do {
                try await refresher.createProposal(kind: kind, urlString: urlString)
                alert(
                    on: presenter,
                    title: L10n.string("Proposal Sent"),
                    message: L10n.string("Thanks — it's in the queue."))
            } catch {
                if weeklyCloudErrorIsNotAuthenticated(error) {
                    alert(
                        on: presenter,
                        title: L10n.string("Sign in to iCloud"),
                        message: L10n.string(
                            "Proposing a Save of the Week needs an iCloud account. Sign in from Settings and try again."))
                } else {
                    alert(
                        on: presenter,
                        title: L10n.string("Couldn't Propose"),
                        message: error.localizedDescription)
                }
            }
        }
    }

    private static func alert(on presenter: UIViewController, title: String, message: String) {
        guard presenter.view.window != nil else { return }
        let alert = UIAlertController(
            title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: L10n.string("OK"), style: .default))
        presenter.present(alert, animated: true)
    }
}
