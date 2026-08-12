//
//  KindDeckProvider.swift
//  Luna
//
//  THE `CardDeckProviding` implementation — one, for every app.
//
//  A deck used to be its own provider (`deckProvider` returned `self`), so the
//  three roots each carried a copy of "read the store, order it, split off the
//  archive, fingerprint it, build the cards, offer the verbs". The copies drifted
//  in every direction the refactor plan lists. This file is that algorithm once;
//  everything in it that is a statement about a KIND is asked of
//  `CardKindPresenters.presenter(for:)` instead of switched on here.
//
//  What stays per-app is genuinely per-app and lives in `CardDeckConfiguration`:
//  whether the app has a generic link card for a save its kind holds nothing
//  for, and how its trailing circle reads. Those are properties of a home
//  screen, not of a save. ORDERING is not among them — every deck in every app
//  sorts by `bumpDate ?? dateAdded`, descending, and nothing else.
//
//  This file is compiled into ALL FOUR targets, so it may not name a kind
//  module's symbols. Everything kind-shaped arrives through the presenter
//  protocol; the one exception is the FAILED save, which carries no kind at all
//  (`ReadingListSectioning.isFailedSave`) and is therefore the deck's own card in
//  every app.
//

import LunaDesignSystem
import LunaModels
import LunaReadingList
import LunaReadingListUI
import LunaSocialUI
import LunaStorage
import UIKit

// MARK: - What is per-app about a deck

struct CardDeckConfiguration {

    /// Whether a save whose kind holds nothing to draw yet still earns a card.
    ///
    /// The central app and Reader have a generic link card to fall back on, so a
    /// platform link with no download behind it is still a card there. The
    /// Downloader and Price Tracker have no such card — they have always shown
    /// their own store's rows and nothing else — so for them such a save is not
    /// a slot at all rather than an empty rectangle.
    var showsSavesWithoutKindContent = false

    /// The card for a save whose kind returned none. Only ever reached when
    /// `showsSavesWithoutKindContent` is true.
    var fallbackContent: (ReadingListItem) -> CardContentViewController = { _ in
        CardContentViewController()
    }

    /// What a tap on a card the resolved presenter declined does. Reader toggles
    /// immersion / runs the unlock flow from its own subclass, so it passes nil.
    var fallbackTap: ((ReadingListItem, CardContentViewController?) -> Void)?

    /// The trailing bottom circle, or nil for a deck that dresses it itself
    /// (Reader hangs the focused reader's share ladder there).
    var shareButton: CardDeckShareButton?
}

// MARK: - The provider

@MainActor
final class KindDeckProvider: CardDeckProviding {

    private let configuration: CardDeckConfiguration
    private unowned let host: CardCarouselHostViewController
    private let store = ReadingListStore.shared

    private var items: [ReadingListItem] = []
    private var archivedItems: [ReadingListItem] = []
    /// What `deckPreparedSnapshot` computed, waiting for the host to say the
    /// reload is going ahead.
    private var preparedItems: [ReadingListItem] = []
    private var preparedArchivedItems: [ReadingListItem] = []
    /// The presenter that CONTRIBUTED a slot, for the stand-in items that have
    /// no reading-list row for the registry to resolve them from (see
    /// `CardKindPresenting.unbackedItems`).
    private var unbackedOwners: [UUID: CardKindPresenting] = [:]
    private var preparedUnbackedOwners: [UUID: CardKindPresenting] = [:]

    init(host: CardCarouselHostViewController, configuration: CardDeckConfiguration) {
        self.host = host
        self.configuration = configuration
    }

    /// The kind that owns a save. A stand-in for an unbacked row goes straight
    /// back to the presenter that supplied it; everything else is the registry's
    /// single resolution point. Nil means the save has no kind — a failed one.
    private func presenter(for item: ReadingListItem) -> CardKindPresenting? {
        unbackedOwners[item.id] ?? CardKindPresenters.presenter(for: item)
    }

    /// The same resolution, for the host — which owns unarchive and delete and
    /// must reach a stand-in row's presenter the same way.
    func deckPresenter(forItemID id: UUID) -> CardKindPresenting? {
        if let owner = unbackedOwners[id] { return owner }
        guard let item = (items + archivedItems).first(where: { $0.id == id })
        else { return nil }
        return CardKindPresenters.presenter(for: item)
    }

    private func item(atSlot slot: Int) -> ReadingListItem? {
        items.indices.contains(slot) ? items[slot] : nil
    }

    func deckItem(forSlot slot: Int) -> ReadingListItem? { item(atSlot: slot) }

    // MARK: - Store observation

    /// The union of what every installed kind needs watching. A deck watches its
    /// kinds' stores because its kinds say so, not because its app remembered to.
    var deckChangeNotificationNames: [Notification.Name] {
        Array(Set(CardKindPresenters.installed.flatMap(\.changeNotificationNames)))
    }

    var deckActivationNotificationNames: [Notification.Name] {
        Array(Set(CardKindPresenters.installed.flatMap(\.activationNotificationNames)))
    }

    func deckWillBeginObservingStores() {
        for presenter in CardKindPresenters.installed {
            presenter.willBeginObservingStores(host: host)
        }
    }

    /// Runs on the ABANDONED reload path too — which is exactly when a Photos
    /// asset deleted behind Luna's back needs noticing.
    func deckDidSettleReload() {
        for presenter in CardKindPresenters.installed {
            presenter.didSettleReload(host: host)
        }
    }

    // MARK: - The slot list

    func deckPreparedSnapshot() -> CardDeckSnapshot {
        for presenter in CardKindPresenters.installed {
            presenter.prepareSnapshotSideEffects()
        }

        var owners: [UUID: CardKindPresenting] = [:]
        var candidates = store.items().filter { LunaApp.current.includes($0) }
        // Media Luna holds that the reading list has no row for. Real user
        // downloads, not an edge case — see `CardKindPresenting.unbackedItems`.
        for presenter in CardKindPresenters.installed {
            for standIn in presenter.unbackedItems() {
                owners[standIn.id] = presenter
                candidates.append(standIn)
            }
        }
        preparedUnbackedOwners = owners

        let visible = candidates.filter { item in
            guard let presenter = owners[item.id] ?? CardKindPresenters.presenter(for: item)
            else { return true }   // a failed save belongs to every app
            return configuration.showsSavesWithoutKindContent || presenter.hasContent(for: item)
        }

        let archived = visible.filter { isArchived($0, owners: owners) }
        let active = visible.filter { !isArchived($0, owners: owners) }

        preparedItems = Self.ordered(active)
        preparedArchivedItems = archived.sorted {
            ($0.archivedAt ?? .distantPast) > ($1.archivedAt ?? .distantPast)
        }

        return CardDeckSnapshot(
            slots: preparedItems.map { item in
                CardDeckSlot(
                    id: item.id,
                    urlString: item.urlString,
                    fingerprint: Self.fingerprint(
                        item, prefix: "active",
                        presenter: owners[item.id] ?? CardKindPresenters.presenter(for: item)))
            },
            offstageIDs: Set(preparedArchivedItems.map(\.id)),
            offstageFingerprint: preparedArchivedItems.map { item in
                Self.fingerprint(
                    item, prefix: "archive",
                    presenter: owners[item.id] ?? CardKindPresenters.presenter(for: item))
            })
    }

    func deckCommitPreparedSnapshot() {
        items = preparedItems
        archivedItems = preparedArchivedItems
        unbackedOwners = preparedUnbackedOwners
    }

    /// Archived-ness is the KIND's answer, because the flag can live in the
    /// kind's own store (a media row's, a tracker's) rather than on the
    /// reading-list row. A failed save has only the row.
    private func isArchived(
        _ item: ReadingListItem, owners: [UUID: CardKindPresenting]
    ) -> Bool {
        guard let presenter = owners[item.id] ?? CardKindPresenters.presenter(for: item)
        else { return item.isArchived }
        return presenter.isArchived(item)
    }

    /// THE ordering, for every kind in every app: sort date descending, ties
    /// broken by id so the result is stable.
    ///
    /// There is deliberately no read/unread grouping and no per-kind sort key.
    /// The Reader used to file finished articles after unopened ones, which the
    /// central app could not adopt — "read" is an article-only notion and would
    /// have shuffled a just-watched video behind everything else — so the two
    /// decks ordered differently and the same save moved when you switched apps.
    /// Finished reads leave the deck on their own anyway, via
    /// `ReadingListStore.archivePendingFinishedItems()` at launch/background, so
    /// the grouping was buying an ordering divergence for something already
    /// handled.
    ///
    /// The sort date is `bumpDate ?? dateAdded`, and exactly three things set a
    /// bump: unarchiving any save, a price alert firing, and the existing
    /// article completion path. Nothing else has one.
    nonisolated static func ordered(_ items: [ReadingListItem]) -> [ReadingListItem] {
        items.sorted { lhs, rhs in
            let lhsDate = lhs.bumpDate ?? lhs.dateAdded
            let rhsDate = rhs.bumpDate ?? rhs.dateAdded
            if lhsDate != rhsDate { return lhsDate > rhsDate }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    /// The deck-generic half of a card's identity plus the kind's own. Two
    /// reloads with equal fingerprints are the same deck, and the second is
    /// abandoned rather than tearing down live card content to rebuild it.
    private static func fingerprint(
        _ item: ReadingListItem, prefix: String, presenter: CardKindPresenting?
    ) -> String {
        guard let presenter else {
            // A failed save's card changes when a rescue starts or stops.
            return "\(prefix)|failed|\(item.id)"
                + "|\(URLRescueCoordinator.shared.isRescuing(item.id))"
        }
        return "\(prefix)|\(item.id)|\(item.title ?? "")|\(item.state)"
            + "|\(item.thumbnailFileName ?? "")|\(item.isArchived)"
            + "|\(presenter.fingerprint(for: item))"
    }

    // MARK: - Cards

    func deckContentController(forSlot slot: Int) -> CardContentViewController {
        guard let item = item(atSlot: slot) else { return CardContentViewController() }
        // Until ingest classifies and fetches this save, every kind deliberately
        // shares one metadata-free state. In particular, don't construct an
        // article card whose fallback header would briefly say "Untitled" and
        // show a globe before this URL turns out to be a product or media save.
        guard item.state != .pending else { return PendingSaveCardContentViewController() }
        guard let presenter = presenter(for: item) else {
            // A save that FAILED gets the shared error card instead of an empty
            // one with a one-line apology: the page itself in a near-full-bleed
            // web view, a URL bar with reload + share, and "Retry with AI" in the
            // chin (`claudedocs/failed-saves.md`).
            return FailedSaveCardFactory.makeCard(
                for: item, host: host, onChanged: { [weak host] in host?.reload() })
        }
        return presenter.cardContent(for: item, host: host)
            ?? configuration.fallbackContent(item)
    }

    func deckAllowsPreparedPreview(forSlot slot: Int) -> Bool {
        guard let item = item(atSlot: slot) else { return true }
        return presenter(for: item)?.allowsPreparedPreviewContent(for: item) ?? true
    }

    /// Two kinds of broken wear the soft red rim: a failed SAVE, and a media item
    /// whose DOWNLOAD failed. The second is the kind's own answer, which is why
    /// it now shows in every app that draws media rather than only in the
    /// Downloader.
    func deckEdgeGlowColor(forSlot slot: Int) -> UIColor? {
        guard let item = item(atSlot: slot) else { return nil }
        guard let presenter = presenter(for: item) else { return LunaColors.errorAccent }
        return presenter.edgeGlowColor(for: item)
    }

    func deckLoadThumbnail(forSlot slot: Int, completion: @escaping (UIImage?) -> Void) {
        guard let item = item(atSlot: slot) else {
            completion(nil)
            return
        }
        guard item.state != .pending else {
            completion(nil)
            return
        }
        guard let presenter = presenter(for: item) else {
            completion(UIImage(systemName: "exclamationmark.triangle"))
            return
        }
        presenter.loadThumbnail(for: item, host: host, completion: completion)
    }

    func deckTitle(forSlot slot: Int) -> String? {
        guard let item = item(atSlot: slot) else { return nil }
        guard item.state != .pending else { return nil }
        guard let presenter = presenter(for: item) else {
            // A failed save has no stored title; use the same fallback chain its
            // card headline does so the scrub preview and the card agree.
            return FailedSaveCardFactory.displayTitle(for: item)
        }
        return presenter.title(for: item)
    }

    func deckLoadSourceBadge(
        forSlot slot: Int, completion: @escaping (CarouselSourceBadge?) -> Void
    ) {
        guard let item = item(atSlot: slot), let presenter = presenter(for: item) else {
            completion(nil)
            return
        }
        guard item.state != .pending else {
            completion(nil)
            return
        }
        presenter.loadSourceBadge(for: item, completion: completion)
    }

    func deckLoadMiniCarouselAccessory(
        forSlot slot: Int, completion: @escaping (UIImage?) -> Void
    ) {
        guard let item = item(atSlot: slot), let presenter = presenter(for: item) else {
            completion(nil)
            return
        }
        guard item.state != .pending else {
            completion(nil)
            return
        }
        presenter.loadMiniCarouselAccessory(for: item, completion: completion)
    }

    func deckPrefersThumbnailChip(forSlot slot: Int) -> Bool {
        guard let item = item(atSlot: slot) else { return false }
        guard item.state != .pending else { return false }
        return presenter(for: item)?.prefersThumbnailChip(for: item) ?? false
    }

    /// A card's shape is its KIND's answer. A failed save has no kind, so it
    /// keeps the deck's default — an error card is the same shape everywhere.
    func deckCardStyle(forSlot slot: Int) -> CardCarouselCardStyle? {
        guard let item = item(atSlot: slot) else { return nil }
        return presenter(for: item)?.cardStyle(for: item)
    }

    func deckTopLeadingAccessory(forSlot slot: Int) -> UIView? {
        guard let item = item(atSlot: slot) else { return nil }
        guard item.state != .pending else { return nil }
        return presenter(for: item)?.topLeadingAccessory(for: item)
    }

    // MARK: - Verbs

    func deckMenu(forSlot slot: Int) -> UIMenu? {
        guard let item = item(atSlot: slot) else { return nil }
        let delete = UIAction(
            title: L10n.string("Common_delete"), image: UIImage(systemName: "trash"),
            attributes: .destructive
        ) { [weak self] _ in self?.delete(item) }

        guard let presenter = presenter(for: item) else {
            // A failed save has no extracted text, no eBook and no audio, so the
            // richer ladder has nothing to offer: the link is the whole of it.
            return FailedSaveCardFactory.makeMenu(
                for: item, host: host,
                shareLink: { [weak self] in
                    guard let self else { return }
                    SendToFriendSheet.shareLink(
                        urlString: item.urlString, from: self.host,
                        sourceView: self.host.view)
                },
                delete: delete)
        }

        let kindActions = presenter.menuActions(for: item, host: host)
        let weekly = WeeklyPromotionMenu.actions(for: item, presenter: host)
        return UIMenu(children: kindActions + weekly + [
            UIAction(
                title: L10n.string("CardDeck_host_archiveAction"), image: UIImage(systemName: "archivebox")
            ) { [weak self] _ in self?.archive(item) },
            delete,
        ])
    }

    /// ONE archive per kind, writing every store that kind owns. The three decks
    /// used to write three different flags, so a save archived in one app stayed
    /// live in another.
    private func archive(_ item: ReadingListItem) {
        // The successor is resolved BEFORE the write, so a deck that animates
        // the swap knows where it is going. Persist inside the choreography:
        // the manual reload consumes the new truth in the same event turn and
        // the queued notification becomes a no-op, its fingerprint already
        // applied.
        if let index = items.firstIndex(where: { $0.id == item.id }),
           host.carouselIndex(forSlot: index) == host.carousel.currentIndex {
            let successor = items.indices.contains(index + 1)
                ? items[index + 1]
                : (index > 0 ? items[index - 1] : nil)
            host.pendingTransitionCenteredID = successor?.id
        }
        host.performArchive(ofItemID: item.id) { [weak self] in
            guard let self else { return }
            if let presenter = self.presenter(for: item) {
                presenter.setArchived(true, for: item)
            } else {
                self.store.setArchived(true, for: item.id)
            }
        }
    }

    /// Deleting a card deletes the save WHOLE: the kind's companion storage — a
    /// downloaded file, its Photos asset, the auto-download bookkeeping — goes
    /// with the reading-list row rather than on after it.
    private func delete(_ item: ReadingListItem) {
        if let index = items.firstIndex(where: { $0.id == item.id }),
           host.carouselIndex(forSlot: index) == host.carousel.currentIndex {
            let successor = items.indices.contains(index + 1)
                ? items[index + 1]
                : (index > 0 ? items[index - 1] : nil)
            host.pendingTransitionCenteredID = successor?.id
        }
        host.deleteSave(item)
    }

    // MARK: - Lifecycle

    func deckSlotDidCenter(_ slot: Int) {
        guard let item = item(atSlot: slot) else { return }
        // Every kind's "this took the center" work, plus the read-state mark a
        // failed save still earns.
        guard let presenter = presenter(for: item) else {
            store.markReadState(.opened, for: item.id)
            return
        }
        presenter.itemDidCenter(item, host: host)
    }

    func deckUtilCardDidCenter() {
        for presenter in CardKindPresenters.installed { presenter.utilCardDidCenter() }
    }

    func deckSlotWasTapped(_ slot: Int) {
        guard let item = item(atSlot: slot) else { return }
        let content = host.carousel.contentController(at: host.carouselIndex(forSlot: slot))
        if presenter(for: item)?.itemWasTapped(item, cardContent: content, host: host) == true {
            return
        }
        configuration.fallbackTap?(item, content)
    }

    // MARK: - The archive tray

    /// Every archived row is its kind's own tray cell. There is no generic
    /// fallback left: a FAILED save is the only kind-less card, its menu offers
    /// no Archive, and so it can never reach the tray.
    func deckArchiveTrayItems() -> [ArchiveTrayItem] {
        archivedItems.compactMap { item in
            presenter(for: item)?.archiveTrayItem(for: item, host: host)
        }
    }

    // MARK: - The trailing bottom circle

    var deckShareButton: CardDeckShareButton? { configuration.shareButton }

    func deckCanShare(slot: Int?) -> Bool {
        guard let slot, let item = item(atSlot: slot) else { return false }
        // A failed save keeps its share verbs in its own URL bar and long-press
        // menu, the same dress in every deck.
        return presenter(for: item) != nil
    }

    func deckShareMenu(slot: Int, sourceView: UIView) -> UIMenu? {
        guard let item = item(atSlot: slot) else { return nil }
        return presenter(for: item)?.shareMenu(for: item, host: host, sourceView: sourceView)
    }

    func deckShare(slot: Int, sourceView: UIView) {
        guard let item = item(atSlot: slot) else { return }
        // The path taken when the kind offers no MENU. It may still have a single
        // verb of its own — a product shares its seller's page, which is not this
        // row's URL — and only failing that does the deck share the link.
        if presenter(for: item)?.share(item, host: host, sourceView: sourceView) == true {
            return
        }
        SendToFriendSheet.shareLink(
            urlString: item.urlString, from: host, sourceView: sourceView)
    }
}
