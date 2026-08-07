//
//  FailedSaveCardFactory.swift
//  Luna
//

import LunaDesignSystem
import LunaFetch
import LunaModels
import LunaReadingList
import LunaReadingListUI
import LunaSocialUI
import LunaStorage
import UIKit

/// Assembles the shared failed-save error card for whichever carousel root asks
/// for it. Universal (compiled into every app target): it names no kind-specific
/// symbol, and it passes NO rescue hint — the model classifies the page itself,
/// which is why the card has no content-type picker in any app, central one
/// included.
///
/// This is the ONE place the card's copy, action wiring, and terminal-state
/// policy live, so the Reader and Downloader roots can't drift.
enum FailedSaveCardFactory {

    /// The card for `item`, with its actions bound to `host`.
    /// - Parameter onChanged: called after an action that mutates the store
    ///   (delete, rescue start), so the host can reload its carousel.
    static func makeCard(
        for item: ReadingListItem,
        host: UIViewController,
        surface: LunaApp = LunaApp.current,
        onChanged: @escaping () -> Void
    ) -> FailedSaveCardViewController {
        let card = FailedSaveCardViewController(
            model: makeModel(for: item),
            actions: makeActions(for: item, host: host, onChanged: onChanged),
            stateProvider: { makeModel(for: item, surface: surface) })
        // The page has no title of its own (that's WHY it failed), and the deck's
        // chrome above the card wants one. A cheap head-only read gets it, cached
        // into the failure sidecar so a cold launch shows the same words.
        resolveNaming(for: item) { onChanged() }
        return card
    }

    /// The rendered model — also used on its own by the hosts' in-place updates
    /// (a rescue starting, advancing, or finishing).
    static func makeModel(
        for item: ReadingListItem, surface: LunaApp = LunaApp.current
    ) -> FailedSaveCardModel {
        FailedSaveCardModel(
            itemID: item.id,
            url: item.url,
            urlText: FailedSaveNaming.displayURL(item.url, rawURLString: item.urlString),
            isRescuing: URLRescueCoordinator.shared.isRescuing(item.id),
            progress: URLRescueCoordinator.shared.rescueProgress(item.id) ?? 0,
            // A `.notContent` failure has no article for the model to find, so the
            // card shows the terminal apology rather than offering an attempt it
            // would only spend proving that.
            canRescue: URLRescueCoordinator.engine?.isAvailable() == true
                && (SaveFailureStore.shared.record(for: item.id)?.reason?.isWorthRescuing ?? true),
            hasSpentAIAttempt: SaveFailureStore.shared.hasSpentAIAttempt(item.id))
    }

    /// The deck's title for a failed card. The card body no longer shows a
    /// headline (it shows the live page), but the carousel chrome above it and the
    /// scrub preview both still need words, and they must agree — so both come
    /// through here.
    static func displayTitle(for item: ReadingListItem) -> String {
        let record = SaveFailureStore.shared.record(for: item.id)
        return FailedSaveNaming.displayTitle(
            url: item.url, itemTitle: item.title, resolvedTitle: record?.resolvedTitle)
    }

    /// The long-press menu for a failed card, in one place because two decks show
    /// one. Archiving an empty shell would only file it where the user can't act
    /// on it, so sharing the link and getting rid of it are the only honest verbs
    /// (`claudedocs/failed-saves.md`) — the same two the card's own chin offers.
    ///
    /// Both legs are supplied because each deck deletes on its own terms: the
    /// Downloader drops the reading-list row, the article deck also releases the
    /// save's companion storage and picks the successor card to land on.
    static func makeMenu(shareLink: @escaping () -> Void, delete: UIAction) -> UIMenu {
        UIMenu(children: [
            UIAction(
                title: L10n.string("Common_shareLinkEllipsis"),
                image: UIImage(systemName: "square.and.arrow.up")
            ) { _ in shareLink() },
            delete,
        ])
    }

    /// "Tried 3 times · 2 days ago" — provenance that makes a stubborn failure
    /// legible. Suppressed for a single fresh attempt, which needs no history.
    /// No longer on the card (the page itself is the explanation now), but the
    /// list rows still show it.
    static func attemptFooter(_ record: SaveFailureRecord?, now: Date = Date()) -> String? {
        guard let record, record.failureCount > 1 else { return nil }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        let when = formatter.localizedString(for: record.lastFailureDate, relativeTo: now)
        return L10n.string("CardDeck_failedSave_attemptFooter", record.failureCount, when)
    }

    // MARK: - Actions

    private static func makeActions(
        for item: ReadingListItem, host: UIViewController, onChanged: @escaping () -> Void
    ) -> FailedSaveCardActions {
        FailedSaveCardActions(
            rescue: {
                // No hint: `RescueRequest.ContentHint.auto`, so the model decides
                // whether this page is an article, a product, or media.
                URLRescueCoordinator.shared.requestManualRescue(itemID: item.id, hint: nil)
                onChanged()
            },
            share: { sourceView in
                // A failed save has no content, no eBook, no media — the raw URL is
                // the only thing there is to share, so this goes straight to the
                // system sheet instead of the reader's richer share ladder (which
                // isn't compiled into the Downloader/Price Tracker targets anyway).
                SendToFriendSheet.shareLink(
                    urlString: item.urlString, from: host, sourceView: sourceView)
            },
            delete: {
                ReadingListStore.shared.delete(item)
                onChanged()
            })
    }

    // MARK: - Naming

    /// One light metadata read per failed item per launch, persisted into the
    /// failure sidecar so a cold launch shows the same words without refetching.
    /// Feeds the deck's card TITLE (`FailedSaveNaming.displayTitle`), not the card
    /// body — the card body is the live page.
    private static func resolveNaming(
        for item: ReadingListItem, completion: @escaping () -> Void
    ) {
        guard let url = item.url else { return }
        let record = SaveFailureStore.shared.record(for: item.id)
        guard record?.resolvedTitle == nil || record?.siteName == nil else { return }
        guard beginNaming(item.id) else { return }
        Task {
            let metadata = await PageMetadataFetcher().fetchMetadata(for: url)
            await MainActor.run {
                endNaming(item.id)
                guard !metadata.isEmpty else { return }
                SaveFailureStore.shared.recordMetadata(
                    item.id, title: metadata.title, siteName: metadata.siteName)
                completion()
            }
        }
    }

    /// Keeps the two mounted copies of one card — the centered card and its side
    /// peek, built independently — from both firing the same metadata read.
    private static let namingLock = NSLock()
    private static var inFlightNaming: Set<UUID> = []

    private static func beginNaming(_ id: UUID) -> Bool {
        namingLock.lock(); defer { namingLock.unlock() }
        return inFlightNaming.insert(id).inserted
    }

    private static func endNaming(_ id: UUID) {
        namingLock.lock(); defer { namingLock.unlock() }
        inFlightNaming.remove(id)
    }
}
