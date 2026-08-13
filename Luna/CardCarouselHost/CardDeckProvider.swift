//
//  CardDeckProvider.swift
//  Luna
//
//  The seam between the ONE deck implementation in
//  `CardCarouselHostViewController` and the four kinds of save that can occupy
//  a card. The host owns the parts that are the same everywhere — the slot
//  count and the index arithmetic over it, the six-phase reload, the
//  fingerprint diff, the centering ladder, the carousel's data source and
//  delegate, the archive tray's item pipeline, the flanking circles, and the
//  util card's save transition. A provider owns everything that is a statement
//  about a KIND: what a card looks like, what its long press offers, where a
//  tap goes, what deleting it releases, and how its store is ordered, filtered,
//  and watched.
//
//  `KindDeckProvider` (`CardCarouselHost/KindDeckProvider.swift`) is the one
//  conformer, shared by every app: what a card looks like, what its long
//  press offers, and how its store is ordered all come from
//  `CardKindPresenters.presenter(for:)` rather than from a per-app subclass.
//

import LunaDesignSystem
import LunaModels
import UIKit

/// One card past the deck's permanent util card — and deliberately only what
/// the shared host needs to know about it: who it is, and whether it has
/// changed. What the slot IS belongs to the kind that owns it.
struct CardDeckSlot {
    /// This slot's stable identity, for the new-save diff and for centering.
    let id: UUID
    /// The save's URL, when the slot has one.
    ///
    /// A save's id is not always the key a centering request knows it by: an
    /// ingest that reshapes the URL, or a companion store that wrote the row
    /// under its OWN id (a media download keyed by `SavedMediaItem.id`), leaves
    /// the two out of step. The URL travels alongside so either key resolves.
    let urlString: String?
    /// Everything about this slot that its card renders. Two reloads with equal
    /// fingerprints are the same deck, and the second one is abandoned rather
    /// than tearing down live card content (a playing video, a scrolled reader)
    /// to rebuild it identically.
    let fingerprint: String

    init(id: UUID, urlString: String? = nil, fingerprint: String) {
        self.id = id
        self.urlString = urlString
        self.fingerprint = fingerprint
    }
}

/// What a reload would show, computed but NOT yet adopted. The host abandons a
/// reload whose fingerprint matches the applied one, and the carousel must keep
/// pointing at the arrays it was actually built from — so preparing and
/// committing are two steps.
struct CardDeckSnapshot {
    /// The cards, in deck order. Card index = slot index + `cardOffset`.
    var slots: [CardDeckSlot]
    /// Ids the deck knows but doesn't show — its archive. Counting them as seen
    /// keeps unarchiving a row from reading as a save that just arrived.
    var offstageIDs: Set<UUID> = []
    /// Fingerprint rows for what the deck shows OFF the carousel (the archive
    /// tray), so a change there still reloads even though no card moved.
    var offstageFingerprint: [String] = []

    init(
        slots: [CardDeckSlot],
        offstageIDs: Set<UUID> = [],
        offstageFingerprint: [String] = []
    ) {
        self.slots = slots
        self.offstageIDs = offstageIDs
        self.offstageFingerprint = offstageFingerprint
    }
}

/// A request to bring one particular save to the center on the next applied
/// reload, whatever slot it turns out to occupy by then. Both keys are tried,
/// because a deck may be keyed by either (see `CardDeckSlot.urlString`).
struct CardDeckCenteringRequest {
    var itemID: UUID?
    var urlStrings: Set<String> = []

    init(itemID: UUID? = nil, urlStrings: Set<String> = []) {
        self.itemID = itemID
        self.urlStrings = urlStrings
    }

    func matches(_ slot: CardDeckSlot) -> Bool {
        if let itemID, itemID == slot.id { return true }
        guard let urlString = slot.urlString else { return false }
        return urlStrings.contains(urlString)
    }
}

/// The trailing bottom-corner circle, as its deck describes it.
struct CardDeckShareButton {
    /// How the circle reads when the centered card has nothing to share.
    enum Unavailability {
        /// It goes away — the deck's other verbs remain reachable, and an
        /// affordance for something that isn't there is worse than no
        /// affordance (Reader, Downloader).
        case hides
        /// It greys out — the deck's pill is a fixture of its chrome and a gap
        /// beside the scrub strip reads as a layout fault (Price Tracker).
        case disables
    }

    let accessibilityLabel: String
    let unavailability: Unavailability
}

/// The kind-specific half of a card deck. Everything here is a statement about
/// a KIND of save; everything the host does with it is the same for all of them.
///
/// Slot indices are always in the provider's own space — 0 is its first card,
/// with the util card's offset already taken off. The host owns that offset and
/// applies it exactly once.
@MainActor
protocol CardDeckProviding: AnyObject {

    // MARK: - Store observation

    /// Change notifications BESIDES `.readingListChanged`, which every deck
    /// watches, that must reload this deck (a media store write, a friends-list
    /// edit that renames a card's sender).
    var deckChangeNotificationNames: [Notification.Name] { get }

    /// Notifications besides `willEnterForeground` that mean "catch up on
    /// whatever happened while we weren't looking". The Downloader adds
    /// `didBecomeActive`: Darwin notifications are dropped while suspended, and
    /// on iPad the app can stay foregrounded the whole time an extension runs
    /// alongside it.
    var deckActivationNotificationNames: [Notification.Name] { get }

    /// One-time store wiring, run from `viewDidLoad` before the first reload:
    /// cross-process bridging, and any notification this deck answers with a
    /// selector of its own rather than with a reload.
    func deckWillBeginObservingStores()

    // MARK: - The slot list

    /// Read the stores and compute the slots this deck would now show — WITHOUT
    /// adopting them.
    func deckPreparedSnapshot() -> CardDeckSnapshot

    /// Adopt the snapshot `deckPreparedSnapshot` computed. Called only for a
    /// reload that is actually applied, before the carousel reloads against it.
    func deckCommitPreparedSnapshot()

    /// Runs at the end of EVERY reload, applied or abandoned. A no-op reload is
    /// exactly when the Downloader wants to notice a Photos asset that has gone.
    func deckDidSettleReload()

    // MARK: - Cards

    func deckContentController(forSlot slot: Int) -> CardContentViewController
    /// Whether the scrub strip may build this slot's real content ahead of the
    /// finger. A card backed by a video player answers false — sweeping the
    /// strip must not spin up one player per chip.
    func deckAllowsPreparedPreview(forSlot slot: Int) -> Bool
    func deckLoadThumbnail(forSlot slot: Int, completion: @escaping (UIImage?) -> Void)
    func deckTitle(forSlot slot: Int) -> String?
    func deckLoadSourceBadge(
        forSlot slot: Int, completion: @escaping (CarouselSourceBadge?) -> Void)
    func deckLoadMiniCarouselAccessory(
        forSlot slot: Int, completion: @escaping (UIImage?) -> Void)
    /// Whether this slot's strip chip is its own full-bleed still rather than a
    /// mini card with a source badge.
    func deckPrefersThumbnailChip(forSlot slot: Int) -> Bool
    /// This card's own shape (fit, edge fade, scrub-preview autoplay, in-card
    /// paging). Nil leaves the deck's own default — which is what the util
    /// card, having no kind, always gets.
    func deckCardStyle(forSlot slot: Int) -> CardCarouselCardStyle?
    func deckTopLeadingAccessory(forSlot slot: Int) -> UIView?
    func deckEdgeGlowColor(forSlot slot: Int) -> UIColor?
    func deckMenu(forSlot slot: Int) -> UIMenu?
    func deckSlotDidCenter(_ slot: Int)
    /// The permanent util card took the center; whatever the previous card had
    /// warmed up for itself is no longer wanted.
    func deckUtilCardDidCenter()
    /// The centered card was tapped and its content did not consume the tap.
    func deckSlotWasTapped(_ slot: Int)

    // MARK: - The archive tray

    func deckArchiveTrayItems() -> [ArchiveTrayItem]

    /// The kind that owns a save, as THIS deck resolves it. Normally the
    /// registry's answer, but a stand-in for an unbacked row (see
    /// `CardKindPresenting.unbackedItems`) has no reading-list row to resolve
    /// from and goes back to the presenter that supplied it.
    func deckPresenter(forItemID id: UUID) -> CardKindPresenting?

    /// The save behind a slot. The host keeps only `CardDeckSlot`s — id, URL,
    /// fingerprint — so chrome that needs the whole row (the Reader's share
    /// pill asking what the centered card IS) asks the provider for it.
    func deckItem(forSlot slot: Int) -> ReadingListItem?

    // MARK: - The trailing bottom circle

    /// nil for a deck that dresses its trailing circle itself (Reader's reader
    /// share pill drives a menu rather than a tap handler).
    var deckShareButton: CardDeckShareButton? { get }
    /// Whether the circle's verb is available for the centered card. `slot` is
    /// nil on the util card.
    func deckCanShare(slot: Int?) -> Bool
    /// The circle's MENU for the centered card, built fresh on each press. A
    /// deck that offers a ladder (media's Copy link / Share link / Share video…)
    /// answers here; one with a single verb leaves it nil and `deckShare` fires
    /// on the tap instead.
    func deckShareMenu(slot: Int, sourceView: UIView) -> UIMenu?
    func deckShare(slot: Int, sourceView: UIView)
}

// Every hook a deck doesn't need. A provider states only what its kind actually
// does, so `deckLoadSourceBadge` absent means "this deck has no source badges",
// not "this deck forgot".
extension CardDeckProviding {
    var deckChangeNotificationNames: [Notification.Name] { [] }
    var deckActivationNotificationNames: [Notification.Name] { [] }
    func deckWillBeginObservingStores() {}
    func deckDidSettleReload() {}
    func deckAllowsPreparedPreview(forSlot slot: Int) -> Bool { true }
    func deckTitle(forSlot slot: Int) -> String? { nil }
    func deckLoadSourceBadge(
        forSlot slot: Int, completion: @escaping (CarouselSourceBadge?) -> Void
    ) { completion(nil) }
    func deckLoadMiniCarouselAccessory(
        forSlot slot: Int, completion: @escaping (UIImage?) -> Void
    ) { completion(nil) }
    func deckPrefersThumbnailChip(forSlot slot: Int) -> Bool { false }
    func deckCardStyle(forSlot slot: Int) -> CardCarouselCardStyle? { nil }
    func deckTopLeadingAccessory(forSlot slot: Int) -> UIView? { nil }
    func deckEdgeGlowColor(forSlot slot: Int) -> UIColor? { nil }
    func deckMenu(forSlot slot: Int) -> UIMenu? { nil }
    func deckSlotDidCenter(_ slot: Int) {}
    func deckUtilCardDidCenter() {}
    func deckSlotWasTapped(_ slot: Int) {}
    func deckArchiveTrayItems() -> [ArchiveTrayItem] { [] }
    func deckPresenter(forItemID id: UUID) -> CardKindPresenting? { nil }
    func deckItem(forSlot slot: Int) -> ReadingListItem? { nil }
    var deckShareButton: CardDeckShareButton? { nil }
    func deckCanShare(slot: Int?) -> Bool { slot != nil }
    func deckShareMenu(slot: Int, sourceView: UIView) -> UIMenu? { nil }
    func deckShare(slot: Int, sourceView: UIView) {}
}
