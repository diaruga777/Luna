//
//  FailedSaveCardFactory.swift
//  Luna
//

import LunaAppConfig
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
            urlText: FailedSaveCopy.displayURL(item.url, rawURLString: item.urlString),
            rescueState: rescueState(for: item))
    }

    /// A running rescue takes precedence over the terminal states — there is
    /// nothing useful to show alongside a bar that's already moving.
    private static func rescueState(for item: ReadingListItem) -> FailedSaveCardModel.RescueState {
        if URLRescueCoordinator.shared.isRescuing(item.id) {
            return .running(progress: URLRescueCoordinator.shared.rescueProgress(item.id) ?? 0)
        }
        // A guardrailed item is terminal for good, not just for this version: the
        // prompt is derived from the page, so the same page trips the same safety
        // guardrail on every future build too. `.unavailable` rather than
        // `.spent` because `.spent` promises the button comes back after an
        // update, and this one never does. (The two render identically — no
        // button, the apology, Delete — so this is a promise, not a pixel.)
        if RescueLedgerStore.shared.isGuardrailed(item.id) {
            return .unavailable
        }
        if SaveFailureStore.shared.hasSpentAIAttempt(item.id) {
            return .spent
        }
        // A `.notContent` failure has no article for the model to find, so the
        // card shows the terminal apology rather than offering an attempt it
        // would only spend proving that.
        let canRescue = URLRescueCoordinator.engine?.isAvailable() == true
            && (SaveFailureStore.shared.record(for: item.id)?.reason?.isWorthRescuing ?? true)
        return canRescue ? .idle : .unavailable
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
    ///
    /// A third verb appears only when the save left a trace behind: "Share
    /// Diagnostics…" hands over the whole story of the attempt, which is the one
    /// thing a user CAN do about a failure Luna can't explain
    /// (`claudedocs/save-diagnostics.md`).
    static func makeMenu(
        for item: ReadingListItem, host: UIViewController,
        shareLink: @escaping () -> Void, delete: UIAction
    ) -> UIMenu {
        var children: [UIMenuElement] = [
            UIAction(
                title: L10n.string("Common_shareLinkEllipsis"),
                image: UIImage(systemName: "square.and.arrow.up")
            ) { _ in shareLink() },
        ]
        if SaveDiagnosticsStore.shared.hasDiagnostics(for: item.id) {
            children.append(UIAction(
                title: L10n.string("CardDeck_failedSave_shareDiagnostics"),
                image: UIImage(systemName: "doc.text.magnifyingglass")
            ) { [weak host] _ in
                guard let host else { return }
                shareDiagnostics(for: item, from: host, sourceView: host.view)
            })
        }
        children.append(delete)
        return UIMenu(children: children)
    }

    // MARK: - Diagnostics export

    /// Writes the item's trace to a shareable .txt — the same header shape
    /// `DiagnosticLog.exportFile` uses, plus what this particular save knows
    /// about itself — and puts it in the system share sheet.
    ///
    /// The file is built off the main thread (it can be a couple of hundred KB
    /// of accumulated retries) and presented back on it, matching
    /// `ArticleExportService.presentShareSheet`'s shape.
    static func shareDiagnostics(
        for item: ReadingListItem, from host: UIViewController, sourceView: UIView
    ) {
        let header = diagnosticsHeader(for: item)
        DispatchQueue.global(qos: .userInitiated).async { [weak host, weak sourceView] in
            let fileURL = try? SaveDiagnosticsStore.shared.exportFile(
                for: item.id, header: header)
            DispatchQueue.main.async {
                guard let host, let fileURL else { return }
                LunaShareSheet.present(
                    items: [fileURL], from: host, anchor: .view(sourceView ?? host.view))
            }
        }
    }

    /// Context the trace itself doesn't carry: which build produced it, which
    /// link it is about, and what the failure sidecar concluded.
    static func diagnosticsHeader(
        for item: ReadingListItem, record: SaveFailureRecord? = nil, now: Date = Date()
    ) -> String {
        let record = record ?? SaveFailureStore.shared.record(for: item.id)
        let os = ProcessInfo.processInfo.operatingSystemVersion
        var lines = [
            "Luna save diagnostics",
            "App: \(AppConfig.appVersion) (\(LunaApp.current.storageIdentifier))",
            "OS: iOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
            "Exported: \(ISO8601DateFormatter().string(from: now))",
            "Item: \(item.id.uuidString)",
            "URL: \(item.urlString)",
        ]
        if let record {
            lines.append("Reason: " + (record.reason?.headline ?? "unrecorded"))
            lines.append("Attempts: \(record.failureCount)")
            lines.append(
                "Last failed: \(ISO8601DateFormatter().string(from: record.lastFailureDate))")
            if let version = record.aiAttemptVersion {
                lines.append("AI rescue spent under: \(version)")
            }
        }
        return lines.joined(separator: "\n") + "\n"
            + String(repeating: "-", count: 40) + "\n\n"
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
            // Nil unless this save actually flushed a trace, which is what keeps
            // the share control a plain button on a failure Luna never got to
            // watch (an item that failed before per-save capture shipped).
            shareDiagnostics: SaveDiagnosticsStore.shared.hasDiagnostics(for: item.id)
                ? { [weak host] sourceView in
                    guard let host else { return }
                    shareDiagnostics(for: item, from: host, sourceView: sourceView)
                }
                : nil,
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
