//
//  FailedSaveCardFactory.swift
//  Luna
//

import LunaAppConfig
import LunaDesignSystem
import LunaFetch
import LunaModels
import LunaSaves
import LunaSavesUI
import LunaSocialUI
import LunaStorage
import UIKit

/// Assembles the shared failed-save error card for whichever carousel root asks
/// for it. Universal (compiled into every app target): it names no kind-specific
/// symbol.
///
/// This is the ONE place the card's copy and action wiring live, so the Reader
/// and Downloader roots can't drift.
@MainActor
enum FailedSaveCardFactory {

    /// The card for `item`, with its actions bound to `host`.
    /// - Parameter onChanged: called after an action that mutates the store, so
    ///   the host can reload its carousel.
    static func makeCard(
        for item: SavedItem,
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
        for item: SavedItem, surface: LunaApp = LunaApp.current
    ) -> FailedSaveCardModel {
        FailedSaveCardModel(
            itemID: item.id,
            url: item.url,
            urlText: FailedSaveCopy.displayURL(item.url, rawURLString: item.urlString),
            rescueState: rescueState(for: item),
            note: refusalNote(for: item))
    }

    /// Where this save is in its recovery. Work in flight outranks a hand-off
    /// the user started, which outranks the plain offer — there is nothing
    /// useful to show beside a bar that is already moving.
    @MainActor
    private static func rescueState(for item: SavedItem) -> FailedSaveCardModel.RescueState {
        if URLRescueCoordinator.shared.isRescuing(item.id) {
            return .running(progress: URLRescueCoordinator.shared.rescueProgress(item.id) ?? 0)
        }
        if RecoveryFileApplier.shared.isApplying(item.id) {
            return .applying(progress: RecoveryFileApplier.shared.applyProgress(item.id) ?? 0)
        }
        // A refused record is not a wait: the round trip finished and the card
        // goes back to the offer, with the reason under it.
        if let record = LLMHandoffStore.shared.record(forItemID: item.id), record.isWaiting {
            return .waiting(record.provider)
        }
        return .offer
    }

    /// Why the last file for this save was refused. The record carries it, so
    /// the card still explains itself after a relaunch; a file that arrived
    /// with no hand-off behind it falls back to the applier's own memory of
    /// this process.
    @MainActor
    private static func refusalNote(for item: SavedItem) -> String? {
        if let record = LLMHandoffStore.shared.record(forItemID: item.id) {
            return record.refusal
        }
        return RecoveryFileApplier.shared.lastFailure(forURL: item.urlString)
    }

    /// Hands the failed page to a chat model: the prompt names the page and
    /// what went wrong, the hand-off is recorded so the card can wait on it,
    /// and the provider opens.
    ///
    /// Two callers: the card's row, and `KindWiring.openLLMHandoff` when an
    /// extension's own open was refused and the app has to finish it.
    static func startHandoff(for item: SavedItem, to provider: LLMProvider) {
        let reason = SaveFailureStore.shared.record(for: item.id)?.reason
        SaveRecoveryHandoff.begin(
            item: item, provider: provider,
            failure: SaveFailureReason.rescueSentence(
                reason, attempted: SaveFailureReason.attemptKind(for: item, reason: reason)))
    }

    /// The deck's title for a failed card. The card body shows the live page
    /// rather than a headline, but the carousel chrome above it and the scrub
    /// preview both still need words, and they must agree — so both come
    /// through here.
    static func displayTitle(for item: SavedItem) -> String {
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
    /// Downloader drops the save row, the article deck also releases the
    /// save's companion storage and picks the successor card to land on.
    ///
    /// A third verb appears only when the save left a trace behind: "Share
    /// Diagnostics…" hands over the whole story of the attempt, which is the one
    /// thing a user CAN do about a failure Luna can't explain
    /// (`claudedocs/save-diagnostics.md`).
    static func makeMenu(
        for item: SavedItem, host: UIViewController,
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
        if let url = item.url, let present = FailedSavePluginRecovery.present {
            children.append(UIAction(
                title: L10n.string("Plugins_recoveryCreatePlugin"),
                image: UIImage(systemName: "wand.and.stars")
            ) { [weak host] _ in
                guard let host else { return }
                present(item.id, url, host)
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
        for item: SavedItem, from host: UIViewController, sourceView: UIView
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
        for item: SavedItem, record: SaveFailureRecord? = nil, now: Date = Date()
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
        }
        return lines.joined(separator: "\n") + "\n"
            + String(repeating: "-", count: 40) + "\n\n"
    }

    // MARK: - Actions

    private static func makeActions(
        for item: SavedItem, host: UIViewController, onChanged: @escaping () -> Void
    ) -> FailedSaveCardActions {
        let createPlugin: (() -> Void)?
        if let url = item.url, let present = FailedSavePluginRecovery.present {
            createPlugin = { present(item.id, url, host) }
        } else {
            createPlugin = nil
        }
        return FailedSaveCardActions(
            chooseProvider: { provider in
                startHandoff(for: item, to: provider)
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
            createPlugin: createPlugin,
            delete: {
                SavesStore.shared.delete(item)
                onChanged()
            })
    }

    // MARK: - Naming

    /// One light metadata read per failed item per launch, persisted into the
    /// failure sidecar so a cold launch shows the same words without refetching.
    /// Feeds the deck's card TITLE (`FailedSaveNaming.displayTitle`), not the card
    /// body — the card body is the live page.
    private static func resolveNaming(
        for item: SavedItem, completion: @escaping () -> Void
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
