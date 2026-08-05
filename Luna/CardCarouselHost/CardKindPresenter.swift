//
//  CardKindPresenter.swift
//  Luna
//
//  ONE definition per KIND of save, shared by every app that shows that kind.
//
//  `CardDeckProviding` splits the deck into "the machinery" and "the kind", but
//  it splits it PER DECK: each root view controller is its own provider, so
//  three deck subclasses each answered the same questions about the same saves
//  and the central app — which shows all of them — needed a fourth, hand-listed
//  adapter (`AllKindsCardProviding`) to forward the ones it could not name.
//  Anything not explicitly forwarded diverged silently: a failed download's red
//  rim existed only in the Downloader, archiving wrote a different store in each
//  app, deleting an archived media save centrally leaked its file, products
//  rendered as generic link cards.
//
//  This is the same fix the ingest side already made with kind packs
//  (`ArticleKindComposition` and friends): a kind's card behavior is defined
//  ONCE, in a file compiled only into the apps that link that kind, and each
//  `KindWiring+<App>` installs exactly the presenters for the kinds its app
//  handles. `KindCompositionRootTests` fails the build when a root's installed
//  presenters don't match its app's kinds, when anything outside a presenter
//  install path writes the registry, and when the deck switches on kind itself.
//
//  A presenter answers questions about a `ReadingListItem` — never about a slot
//  index. Slot arithmetic, the util-card offset, the reload's fingerprint diff
//  and the centering ladder all stay in the host, which is the only place that
//  has ever needed them.
//

import LunaDesignSystem
import LunaModels
import LunaReadingListUI
import LunaStorage
import UIKit

// MARK: - What a presenter may ask of its deck

/// The deck, as the kind drawing into it sees it. A presenter holds no
/// reference to this — every call that needs the deck is handed it — so a
/// process-wide registry entry can never outlive, or capture, one screen.
@MainActor
protocol CardPresenterHost: AnyObject {
    /// Where a presenter presents from: share sheets, alerts, fullscreen
    /// players, the price editor.
    var presentingController: UIViewController { get }

    /// The scale of the screen this deck is ACTUALLY on, for card and thumbnail
    /// rendering. Resolved from the deck's own window rather than
    /// `UIScreen.main` — the two disagreed between the Downloader's deck and the
    /// central app's, which is how the same media save was rendered at two
    /// different scales depending on which app you opened it in.
    var displayScale: CGFloat { get }

    /// Re-read the stores and rebuild the deck. A presenter calls this after a
    /// write the store's own notification won't cover in the same event turn.
    func reloadDeck()

    /// The mounted card view for an item, for popover anchoring. Nil when the
    /// item has no card mounted right now (it is offstage, or archived).
    func cardView(forItemID id: UUID) -> UIView?

    /// Unarchive this save and bring it back onto the deck, with whatever
    /// choreography this deck has (the Reader's cross-dissolves the tray cell
    /// into the destination card). The store write is still the KIND's —
    /// `setArchived(false:)` — so every companion flag and the row's bump date
    /// move together.
    func unarchive(_ item: ReadingListItem, from sourceView: UIView?)

    /// Delete this save WHOLE: the kind's companion storage — a downloaded file,
    /// its Photos asset, its auto-download bookkeeping — and then the row.
    /// Reachable from a card's menu and from an archive-tray cell, which is the
    /// point: the tray's delete used to skip the companion half.
    func deleteSave(_ item: ReadingListItem)

    /// A presenter's archive-tray download bars changed. Progress ticks arrive
    /// several times a second, so the tray updates its visible cells in place
    /// rather than reloading the deck.
    func archiveDownloadProgressDidChange()

    /// Bring this save to the center on the next applied reload. Presenters
    /// speak in items, never in slots — the deck owns that arithmetic — so this
    /// is the item-shaped face of the host's own centering request.
    func requestCentering(onItemID id: UUID)
}

// MARK: - The kind

/// Everything that is a statement about a KIND of save. One implementation per
/// kind, compiled into every app that links that kind and into no other.
///
/// Every hook has a default, so a presenter states only what its kind actually
/// does — `edgeGlowColor` absent means "this kind has no rim", not "this kind
/// forgot", exactly as `CardDeckProviding` reads.
@MainActor
protocol CardKindPresenting: AnyObject {

    // MARK: Slot data

    /// Everything about this save that its card renders and the deck-generic
    /// fingerprint does not already carry. A media download finishing turns a
    /// placeholder into a player; a price change must re-render the graph.
    func fingerprint(for item: ReadingListItem) -> String

    /// Whether this kind holds anything of its own to draw for this save yet —
    /// a media row behind a platform link, a tracker behind a product URL.
    ///
    /// A deck with a generic link card of its own shows the save regardless (see
    /// `CardDeckConfiguration.showsSavesWithoutKindContent`); a deck without one
    /// gives it no slot, which is what the Downloader and Price Tracker have
    /// always done by reading their own store rather than the reading list.
    func hasContent(for item: ReadingListItem) -> Bool

    /// Whether this save currently belongs on the deck at all. A media row
    /// archived in the media store is gone from the deck even though its
    /// reading-list row is live.
    func isArchived(_ item: ReadingListItem) -> Bool

    /// Saves this kind holds that have NO reading-list row to find them by.
    ///
    /// The deck's slot list is the reading list, because that is the one store
    /// every kind writes. Media is the exception, and not a theoretical one: a
    /// media row is keyed by its own store's id and its `sourceURLString` is
    /// whatever the URL was when the DOWNLOAD started, which is not always what
    /// the reading-list row says. A Reddit `/r/…/s/<token>` share link is
    /// network-resolved to its permalink inside `gateAndPrepare`; a wrapper URL
    /// is resolved by the share driver, which then deletes the wrapper row. Both
    /// leave real, downloaded user media with no row pointing at it —
    /// `SavedMediaStore.purgeExpired`'s own comment records that an earlier
    /// membership sweep was removed because it was deleting exactly these.
    ///
    /// A presenter returns stand-in items for them (id and URL from its own
    /// store) and the deck routes those slots straight back to it, so they get
    /// the same card, verbs and archive behavior as any other save of the kind
    /// without the deck learning what a `SavedMediaItem` is.
    func unbackedItems() -> [ReadingListItem]

    // MARK: The card

    /// The real card for this save. Nil leaves the deck's generic card in place
    /// (a reader for an article, a title-and-link card otherwise).
    func cardContent(for item: ReadingListItem, host: CardPresenterHost)
        -> CardContentViewController?
    func topLeadingAccessory(for item: ReadingListItem) -> UIView?
    func edgeGlowColor(for item: ReadingListItem) -> UIColor?

    // MARK: Strip and scrub preview

    func title(for item: ReadingListItem) -> String?
    func loadThumbnail(
        for item: ReadingListItem, host: CardPresenterHost,
        completion: @escaping (UIImage?) -> Void)
    func loadSourceBadge(
        for item: ReadingListItem, completion: @escaping (CarouselSourceBadge?) -> Void)
    func loadMiniCarouselAccessory(
        for item: ReadingListItem, completion: @escaping (UIImage?) -> Void)
    /// Whether this save's strip chip is its own full-bleed still rather than a
    /// mini card with a source badge.
    func prefersThumbnailChip(for item: ReadingListItem) -> Bool

    /// This card's SHAPE — how it fills the room, whether its content
    /// dissolves at the edges, whether the scrub strip plays it, and whether a
    /// horizontal swipe across it pages the deck.
    ///
    /// A property of what the card SHOWS, not of the screen it is on: a
    /// downloaded video is 9:16 with hard edges whether you opened it in the
    /// Downloader or in the central app. It used to be a deck-level style, and
    /// the central app consequently stretched every media card to the reader's
    /// `.aspectFromBottom` and dissolved its edges with a 28pt reader fade.
    func cardStyle(for item: ReadingListItem) -> CardCarouselCardStyle
    /// Whether the scrub strip may build this card's real content ahead of the
    /// finger. A card backed by a video player answers false — sweeping the
    /// strip must never spin up one player per chip.
    func allowsPreparedPreviewContent(for item: ReadingListItem) -> Bool

    // MARK: Verbs

    /// Kind-specific actions, offered above the deck's own Archive/Delete.
    func menuActions(for item: ReadingListItem, host: CardPresenterHost) -> [UIMenuElement]

    /// This save's share ladder for the deck's trailing circle. Nil when the
    /// kind has nothing of its own to offer, which is also what leaves the
    /// circle a plain tap running `share` below.
    func shareMenu(for item: ReadingListItem, host: CardPresenterHost, sourceView: UIView)
        -> UIMenu?

    /// The single share verb, for a kind whose share is one action rather than a
    /// ladder — a product shares its SELLER's page, which is not the reading-list
    /// row's URL. Return false to let the deck share the row's link instead.
    @discardableResult
    func share(_ item: ReadingListItem, host: CardPresenterHost, sourceView: UIView) -> Bool

    /// THE archive implementation for this kind — every store the kind owns, in
    /// one place. Archiving a media save in the Downloader and archiving it in
    /// the central app are the same write, because there is only one.
    func setArchived(_ archived: Bool, for item: ReadingListItem)

    /// Companion storage (a downloaded file, a Photos asset, auto-download
    /// bookkeeping) released when the save is deleted — from the deck OR from
    /// the archive tray. `host` is supplied so a failure that needs the user's
    /// attention (Photos permission) can be reported.
    func deleteCompanionStorage(for item: ReadingListItem, host: CardPresenterHost?)

    // MARK: Lifecycle

    /// This save's card took the center: mark it opened, acknowledge its price
    /// alert, prewarm its share export.
    func itemDidCenter(_ item: ReadingListItem, host: CardPresenterHost)

    /// The permanent util card took the center; whatever the previous card had
    /// warmed up for itself is no longer wanted.
    func utilCardDidCenter()

    /// The centered card was tapped and its content did not consume the tap.
    /// Return true when the presenter handled it; false falls through to the
    /// deck's own behavior (reader immersion, the unlock flow).
    @discardableResult
    func itemWasTapped(
        _ item: ReadingListItem, cardContent: CardContentViewController?,
        host: CardPresenterHost) -> Bool

    // MARK: Stores

    /// Change notifications BESIDES `.readingListChanged`, which every deck
    /// watches, that must reload a deck showing this kind.
    var changeNotificationNames: [Notification.Name] { get }

    /// Notifications besides `willEnterForeground` that mean "catch up on
    /// whatever happened while we weren't looking".
    var activationNotificationNames: [Notification.Name] { get }

    /// One-time store wiring run before a deck's first reload: cross-process
    /// bridging, a job-progress observer.
    func willBeginObservingStores(host: CardPresenterHost)

    /// Store maintenance a snapshot read implies (expiry purge). Runs on every
    /// prepared snapshot, before the slots are read.
    func prepareSnapshotSideEffects()

    /// Runs at the end of EVERY reload, applied or abandoned — which is exactly
    /// when a Photos asset deleted behind Luna's back needs noticing.
    func didSettleReload(host: CardPresenterHost)

    // MARK: The archive tray

    /// In-flight download progress for this kind's ARCHIVED rows, keyed by the
    /// slot id. An archived row has no card to draw a bar in — tapping an
    /// unavailable tray cell re-downloads in place — so the cell carries it.
    var archiveDownloadProgress: [UUID: Double] { get }

    /// This kind's archived rows, as tray cells. The deck supplies the verbs it
    /// owns (unarchive choreography); the presenter supplies everything that is
    /// a statement about the kind.
    func archiveTrayItem(for item: ReadingListItem, host: CardPresenterHost)
        -> ArchiveTrayItem?

    /// Open this save outside the deck (a deep link, an archive-tray tap on a
    /// row with no card). Return true when the presenter took it.
    @discardableResult
    func openExternally(_ item: ReadingListItem, host: CardPresenterHost) -> Bool
}

// Every hook a kind doesn't need.
extension CardKindPresenting {
    func fingerprint(for item: ReadingListItem) -> String { "" }
    func hasContent(for item: ReadingListItem) -> Bool { true }
    func isArchived(_ item: ReadingListItem) -> Bool { item.isArchived }
    func unbackedItems() -> [ReadingListItem] { [] }
    func cardContent(for item: ReadingListItem, host: CardPresenterHost)
        -> CardContentViewController? { nil }
    func topLeadingAccessory(for item: ReadingListItem) -> UIView? { nil }
    func edgeGlowColor(for item: ReadingListItem) -> UIColor? { nil }
    func title(for item: ReadingListItem) -> String? { nil }
    func loadThumbnail(
        for item: ReadingListItem, host: CardPresenterHost,
        completion: @escaping (UIImage?) -> Void
    ) { completion(nil) }
    func loadSourceBadge(
        for item: ReadingListItem, completion: @escaping (CarouselSourceBadge?) -> Void
    ) { completion(nil) }
    func loadMiniCarouselAccessory(
        for item: ReadingListItem, completion: @escaping (UIImage?) -> Void
    ) { completion(nil) }
    func prefersThumbnailChip(for item: ReadingListItem) -> Bool { false }
    func cardStyle(for item: ReadingListItem) -> CardCarouselCardStyle { .init() }
    func allowsPreparedPreviewContent(for item: ReadingListItem) -> Bool { true }
    func menuActions(for item: ReadingListItem, host: CardPresenterHost) -> [UIMenuElement] { [] }
    func shareMenu(for item: ReadingListItem, host: CardPresenterHost, sourceView: UIView)
        -> UIMenu? { nil }
    @discardableResult
    func share(_ item: ReadingListItem, host: CardPresenterHost, sourceView: UIView) -> Bool {
        false
    }
    /// The row, and — on the way BACK — its sort date. Every deck orders on
    /// `bumpDate ?? dateAdded`, so a kind that unarchives without bumping
    /// returns the save to wherever it was originally buried. A kind with a
    /// companion store overrides this to write that too, and calls the bump for
    /// the same reason.
    func setArchived(_ archived: Bool, for item: ReadingListItem) {
        ReadingListStore.shared.setArchived(archived, for: item.id)
        if !archived { ReadingListStore.shared.bump(item.id) }
    }
    func deleteCompanionStorage(for item: ReadingListItem, host: CardPresenterHost?) {}
    func itemDidCenter(_ item: ReadingListItem, host: CardPresenterHost) {}
    func utilCardDidCenter() {}
    @discardableResult
    func itemWasTapped(
        _ item: ReadingListItem, cardContent: CardContentViewController?,
        host: CardPresenterHost
    ) -> Bool { false }
    var changeNotificationNames: [Notification.Name] { [] }
    var activationNotificationNames: [Notification.Name] { [] }
    func willBeginObservingStores(host: CardPresenterHost) {}
    func prepareSnapshotSideEffects() {}
    func didSettleReload(host: CardPresenterHost) {}
    var archiveDownloadProgress: [UUID: Double] { [:] }
    func archiveTrayItem(for item: ReadingListItem, host: CardPresenterHost)
        -> ArchiveTrayItem? { nil }
    @discardableResult
    func openExternally(_ item: ReadingListItem, host: CardPresenterHost) -> Bool { false }
}

// MARK: - The registry

/// The installed presenters, and the ONE place a save is mapped to its kind.
///
/// Resolution order is fixed and lives here, not at call sites: the deck asks
/// `presenter(for:)` and never asks what kind of save it is holding. That is
/// the invariant `CardKindPresenterCompositionTests` enforces by reading the
/// deck's own source.
@MainActor
enum CardKindPresenters {

    static var article: CardKindPresenting?
    static var media: CardKindPresenting?
    static var product: CardKindPresenting?

    /// The kind that owns this save, or nil when nothing does.
    ///
    /// A FAILED save is kind-less by definition — the classifier never got one —
    /// so it belongs to no presenter and the deck draws the shared error card
    /// itself. That is also why every app shows failed saves.
    static func presenter(for item: ReadingListItem) -> CardKindPresenting? {
        if ReadingListSectioning.isFailedSave(item) { return nil }
        if item.isPriceTracker { return product }
        if item.contentPlatform != nil { return media }
        return article
    }

    /// Every installed presenter, for the hooks the deck asks of all of them at
    /// once (store observation, purge, settle).
    static var installed: [CardKindPresenting] {
        [article, media, product].compactMap { $0 }
    }

    /// Whether this save has a home on the deck at all: its kind's presenter is
    /// installed, or it is a kind-less failed save (which belongs everywhere).
    static func isSurfaced(_ item: ReadingListItem) -> Bool {
        if ReadingListSectioning.isFailedSave(item) { return true }
        return presenter(for: item) != nil
    }

    #if DEBUG
    /// Tests install production-shaped presenters explicitly, exactly as they do
    /// for `ShareKindPresenters`.
    static func resetForTesting() {
        article = nil
        media = nil
        product = nil
    }
    #endif
}
