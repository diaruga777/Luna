//
//  ArticleCardPresenter.swift
//  Luna
//
//  The article kind's card behavior — the live reader card, its source badge,
//  its title, its verbs, and its archive rows. Defined ONCE for every app that
//  shows an article: Luna Reader and the central Luna app. Compiled into exactly
//  those two targets.
//
//  The article kind is also the one with real SCREEN chrome behind it (the
//  header row, immersion, the mode switcher, the footer veil, the hosted scroll
//  indicator, the inline second column, and the archive/unarchive
//  choreography). That is not a statement about a card, so it does not live
//  here: it stays on `ArticleCardsViewController`, which is now a deck SUBCLASS
//  and nothing else — no slot arrays, no ordering, no provider conformance. The
//  two meet at `ArticleDeckChromeHosting` below, which is the whole of what a
//  per-save answer needs to ask of the screen around it.
//

import LunaDesignSystem
import LunaFetch
import LunaModels
import LunaReaderUI
import LunaSavesUI
import LunaSocial
import LunaStorage
import UIKit

/// The screen chrome an article card is drawn into, as the presenter sees it.
///
/// Only the Reader-shaped roots (Luna Reader and the central app, which share
/// `ArticleCardsViewController`) conform. A presenter reaches it by asking its
/// host, and gets nil on any deck that has no reader chrome — which is exactly
/// the decks that never hold an article.
@MainActor
protocol ArticleDeckChromeHosting: AnyObject {
    /// Who receives a reader card's immersion, layout and hierarchy callbacks.
    var readerCardDelegate: ReaderCardContentDelegate? { get }
    /// The card's top content-edge fade, applied at CONSTRUCTION rather than on
    /// centering: a scrubber jump stages index ±2 immediately before the
    /// eclipse, and that incoming card must already share the visible window's
    /// title/header geometry.
    var readerCardTopContentInset: CGFloat { get }
    /// Bring this save's card to the center; false when it has none here.
    func centerCard(forItemID id: UUID) -> Bool
    /// The archive.today CAPTCHA flow for a locked save.
    func presentUnlockFlow(for item: SavedItem, articleURL: URL)
    /// Push a fullscreen reader — the fallback for a save with no card here.
    func pushReader(for item: SavedItem)
    /// Toggle the reading immersion the card's own tap drives.
    func toggleImmersion(for card: ReaderCardContentViewController)
}

@MainActor
final class ArticleCardPresenter: CardKindPresenting {

    private let store = SavesStore.shared

    private func chrome(_ host: CardPresenterHost) -> ArticleDeckChromeHosting? {
        host.presentingController as? ArticleDeckChromeHosting
    }

    // MARK: - Slot data

    /// The article half of a card's identity. The deck-generic components (id,
    /// title, state, thumbnail) stay with the deck; this is what only an article
    /// knows — who sent it, which changes when a contact is renamed.
    func fingerprint(for item: SavedItem) -> String {
        Self.senderName(for: item) ?? ""
    }

    /// A renamed contact changes what an emailed card's header says.
    var changeNotificationNames: [Notification.Name] { [.friendsListChanged] }

    /// The card's SIZE is the deck's, not the article's (`CardDeckGeometry`).
    /// What an article does state: scrolled text dissolves at both edges rather
    /// than hitting a hard clip, and a horizontal swipe pages the deck because a
    /// reader has no timeline of its own to scrub.
    func cardStyle(for item: SavedItem) -> CardCarouselCardStyle {
        var style = CardCarouselCardStyle()
        style.contentEdgeFadeHeight = Self.contentEdgeFade
        style.pagesOnInCardSwipes = true
        return style
    }

    /// The run scrolled reader content dissolves over at the card's top and
    /// bottom edges. The reader reserves the same measure as its own content
    /// inset, so the resting first line starts fully legible.
    static let contentEdgeFade: CGFloat = 28

    func title(for item: SavedItem) -> String? {
        item.title ?? item.url?.host ?? item.urlString
    }

    /// An instant fallback (initials / mail / document / globe) first, then the
    /// site's real favicon once fetched. Cached icons resolve synchronously, so
    /// a warm strip shows favicons at once — which is why the completion may
    /// fire twice.
    func loadSourceBadge(
        for item: SavedItem, completion: @escaping (CarouselSourceBadge?) -> Void
    ) {
        completion(ArticleSourceBadge.fallback(for: item))
        guard ArticleSourceBadge.wantsFavicon(item), let url = item.url else { return }
        SiteIconCache.shared.icon(forPageURL: url) { image in
            if let image { completion(.icon(image)) }
        }
    }

    // MARK: - The card

    /// EVERY mounted card is a full live reader, side peeks included, so paging
    /// never shows a placeholder — the card view IS the fullscreen reader view.
    func cardContent(for item: SavedItem, host: CardPresenterHost)
        -> CardContentViewController?
    {
        let content = ReaderCardContentViewController(
            item: item, senderName: Self.senderName(for: item))
        if let chrome = chrome(host) {
            content.setTopContentInset(chrome.readerCardTopContentInset)
            content.delegate = chrome.readerCardDelegate
        }
        return content
    }

    // MARK: - Lifecycle

    func itemDidCenter(_ item: SavedItem, host: CardPresenterHost) {
        store.markReadState(.opened, for: item.id)
    }

    /// A reader card's own touches (links, RSVP play/pause) are handled inside
    /// it; what reaches here is a tap on plain content, which toggles immersion.
    /// A LOCKED save has no reader behind it at all, so its tap opens the unlock
    /// flow instead. Either way the article kind consumes the tap — there is no
    /// deck-level fallback left for it to fall through to.
    @discardableResult
    func itemWasTapped(
        _ item: SavedItem, cardContent: CardContentViewController?,
        host: CardPresenterHost
    ) -> Bool {
        guard let chrome = chrome(host) else { return false }
        guard let card = cardContent as? ReaderCardContentViewController,
              card.rabbitHoleReader != nil
        else {
            guard host.presentingController.presentedViewController == nil,
                  item.state == .needsCaptcha, let url = item.url
            else { return true }
            chrome.presentUnlockFlow(for: item, articleURL: url)
            store.markReadState(.opened, for: item.id)
            return true
        }
        chrome.toggleImmersion(for: card)
        return true
    }

    // MARK: - External open

    /// Deep-link / Safari hand-off: CENTER the card. A card in this deck already
    /// IS the reader, so pushing a fullscreen one would bury the deck under a
    /// second copy of the same article and leave a back button where the
    /// hand-off should simply have landed. The push survives only as the
    /// fallback for a save with no card here — an archived one.
    @discardableResult
    func openExternally(_ item: SavedItem, host: CardPresenterHost) -> Bool {
        guard let chrome = chrome(host) else { return false }
        let centered = chrome.centerCard(forItemID: item.id)
        // A locked save still needs its unlock flow, but centre first so the
        // deck behind the modal — and the deck left behind by a cancel — already
        // shows the article that was asked for.
        if item.state == .needsCaptcha, let url = item.url {
            chrome.presentUnlockFlow(for: item, articleURL: url)
            store.markReadState(.opened, for: item.id)
            return true
        }
        if centered { return true }
        chrome.pushReader(for: item)
        return true
    }

    // MARK: - The archive tray

    /// An archived article: its favicon, its title, and the date it was SAVED
    /// (not the date it was archived — the tray footer has always shown the
    /// original save).
    func archiveTrayItem(for item: SavedItem, host: CardPresenterHost)
        -> ArchiveTrayItem?
    {
        ArchiveTrayItem(
            id: item.id,
            title: item.title ?? item.url?.host ?? item.urlString,
            footer: Self.trayDateFormatter.string(from: item.dateAdded),
            showsMetadata: true,
            isAvailable: true,
            loadImage: { completion in
                guard let url = item.url else {
                    completion(UIImage(systemName: item.isDocument ? "doc" : "globe"))
                    return
                }
                completion(UIImage(systemName: "globe"))
                SiteIconCache.shared.icon(forPageURL: url) { image in
                    if let image { completion(image) }
                }
            },
            tap: { [weak host] in
                guard let host else { return }
                _ = self.openExternally(item, host: host)
            },
            share: { [weak host] sourceView in
                guard let host else { return }
                AppReaderShareProvider.shared.presentShareSheet(
                    urlString: item.urlString, title: item.title,
                    from: host.presentingController, sourceView: sourceView)
            },
            unarchive: { [weak host] sourceView in
                host?.unarchive(item, from: sourceView)
            },
            delete: { [weak host] in host?.deleteSave(item) })
    }

    private static let trayDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    // MARK: - Sender

    /// Incoming-email cards follow the contact's CURRENT name, falling back to
    /// the name captured from the original From header for legacy/unknown
    /// senders.
    static func senderName(for item: SavedItem) -> String? {
        resolvedSenderName(for: item) { email in
            FriendsStore.shared.friend(withEmail: email)?.displayName
        }
    }

    /// Pure, and deliberately `nonisolated`: it is the half of sender resolution
    /// that takes the contact lookup as an argument, so it is testable without a
    /// main-actor hop or a live FriendsStore.
    nonisolated static func resolvedSenderName(
        for item: SavedItem,
        contactNameForEmail: (String) -> String?
    ) -> String? {
        guard item.effectiveCaptureSource == .email else { return nil }
        if let email = item.incomingSenderEmail,
           let currentName = contactNameForEmail(email) {
            return currentName
        }
        return item.senderName
    }
}
