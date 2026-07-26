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
/// symbol, and the rescue hint it passes is implied by the running app's
/// surface — except in the central Luna app, which shows the picker because a
/// failed link there could legitimately have been any of the three kinds.
///
/// This is the ONE place the card's copy, naming fallback chain, favicon load,
/// and action wiring live, so the Reader and Downloader roots can't drift.
enum FailedSaveCardFactory {

    /// The card for `item`, with its actions bound to `host`.
    /// - Parameter onChanged: called after an action that mutates the store
    ///   (delete/retry/rescue start), so the host can reload its carousel.
    static func makeCard(
        for item: ReadingListItem,
        host: UIViewController,
        surface: AppSurface = AppSurfaceConfig.current,
        onChanged: @escaping () -> Void
    ) -> FailedSaveCardViewController {
        let card = FailedSaveCardViewController(
            model: makeModel(for: item, surface: surface),
            actions: makeActions(for: item, host: host, onChanged: onChanged),
            loadIcon: { completion in loadIcon(for: item, completion: completion) })
        // A page Luna never read has no title of its own. Ask the site for one
        // (a cheap head-only read, plus its homepage for a publisher name) and
        // re-render in place when it lands.
        resolveNaming(for: item) { [weak card] in
            guard let card else { return }
            card.update(makeModel(for: item, surface: surface))
        }
        return card
    }

    /// The rendered model — also used on its own by the hosts' in-place updates
    /// (a rescue starting or finishing re-posts `.readingListChanged`).
    static func makeModel(
        for item: ReadingListItem, surface: AppSurface = AppSurfaceConfig.current
    ) -> FailedSaveCardModel {
        let record = SaveFailureStore.shared.record(for: item.id)
        let reason = record?.reason
        return FailedSaveCardModel(
            title: FailedSaveNaming.displayTitle(
                url: item.url, itemTitle: item.title, resolvedTitle: record?.resolvedTitle),
            siteName: FailedSaveNaming.displaySiteName(
                url: item.url, siteName: record?.siteName),
            urlText: FailedSaveNaming.displayURL(item.url, rawURLString: item.urlString),
            detail: reason?.headline ?? SaveFailureReason.unknown.headline,
            suggestion: reason?.suggestion,
            attemptFooter: attemptFooter(record),
            isRescuing: URLRescueCoordinator.shared.isRescuing(item.id),
            hintChoices: hintChoices(for: surface),
            canRescue: URLRescueCoordinator.engine?.isAvailable() == true,
            canRetry: reason?.isWorthRetrying ?? true)
    }

    /// Every app implies its own hint; only the central Luna app — which handles
    /// all three kinds — has a genuine question to ask, so only it gets a picker.
    static func hintChoices(for surface: AppSurface) -> [RescueHint] {
        surface == .all
            ? RescueHint.allCases
            : [URLRescueWiring.defaultHint(for: surface)]
    }

    /// "Tried 3 times · 2 days ago" — provenance that makes a stubborn failure
    /// legible. Suppressed for a single fresh attempt, which needs no history.
    static func attemptFooter(_ record: SaveFailureRecord?, now: Date = Date()) -> String? {
        guard let record, record.failureCount > 1 else { return nil }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        let when = formatter.localizedString(for: record.lastFailureDate, relativeTo: now)
        return L10n.string("Tried \(record.failureCount) times · last \(when)")
    }

    // MARK: - Actions

    private static func makeActions(
        for item: ReadingListItem, host: UIViewController, onChanged: @escaping () -> Void
    ) -> FailedSaveCardActions {
        FailedSaveCardActions(
            rescue: { hint in
                URLRescueCoordinator.shared.requestManualRescue(itemID: item.id, hint: hint)
                onChanged()
            },
            openInBrowser: {
                guard let url = item.url else { return }
                WebPageViewController.present(url: url, from: host)
            },
            share: { sourceView in
                // A failed save has no content, no eBook, no media — the URL is
                // the only thing there is to share, so this goes straight to the
                // system sheet instead of the reader's richer share ladder (which
                // isn't compiled into the Downloader/Price Tracker targets anyway).
                SendToFriendSheet.shareLink(
                    urlString: item.urlString, from: host, sourceView: sourceView)
            },
            retry: {
                Task {
                    await ReadingListIngestor.shared.ingest(item)
                    await MainActor.run { onChanged() }
                }
                onChanged()
            })
    }

    // MARK: - Naming + icon

    /// Loads the site's favicon, falling back to nothing (the card shows a
    /// question mark of its own). Same cache the mini-card badges use, so a warm
    /// icon resolves synchronously.
    private static func loadIcon(
        for item: ReadingListItem, completion: @escaping (UIImage?) -> Void
    ) {
        guard let url = item.url else {
            completion(nil)
            return
        }
        SourceIconCache.shared.icon(forPageURL: url, completion: completion)
    }

    /// One light metadata read per failed item per launch, persisted into the
    /// failure sidecar so a cold launch shows the same words without refetching.
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
