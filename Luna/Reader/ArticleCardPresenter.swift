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
//  indicator, the inline second column). That is not a statement about a card,
//  so it does not live here: the presenter supplies a chrome coordinator the
//  deck installs once, and everything per-save stays on this side.
//

import LunaDesignSystem
import LunaModels
import LunaReaderUI
import LunaReadingListUI
import LunaSocial
import LunaStorage
import UIKit

@MainActor
final class ArticleCardPresenter: CardKindPresenting {

    private let store = ReadingListStore.shared

    // MARK: - Slot data

    /// The article half of a card's identity. The deck-generic components (id,
    /// title, state, thumbnail) stay with the deck; this is what only an article
    /// knows — who sent it, which changes when a contact is renamed.
    func fingerprint(for item: ReadingListItem) -> String {
        Self.senderName(for: item) ?? ""
    }

    /// A renamed contact changes what an emailed card's header says.
    var changeNotificationNames: [Notification.Name] { [.friendsListChanged] }

    func title(for item: ReadingListItem) -> String? {
        item.title ?? item.url?.host ?? item.urlString
    }

    /// An instant fallback (initials / mail / document / globe) first, then the
    /// site's real favicon once fetched. Cached icons resolve synchronously, so
    /// a warm strip shows favicons at once — which is why the completion may
    /// fire twice.
    func loadSourceBadge(
        for item: ReadingListItem, completion: @escaping (CarouselSourceBadge?) -> Void
    ) {
        completion(ArticleSourceBadge.fallback(for: item))
        guard ArticleSourceBadge.wantsFavicon(item), let url = item.url else { return }
        SourceIconCache.shared.icon(forPageURL: url) { image in
            if let image { completion(.icon(image)) }
        }
    }

    // MARK: - Sender

    /// Incoming-email cards follow the contact's CURRENT name, falling back to
    /// the name captured from the original From header for legacy/unknown
    /// senders.
    static func senderName(for item: ReadingListItem) -> String? {
        resolvedSenderName(for: item) { email in
            FriendsStore.shared.friend(withEmail: email)?.displayName
        }
    }

    static func resolvedSenderName(
        for item: ReadingListItem,
        contactNameForEmail: (String) -> String?
    ) -> String? {
        guard item.effectiveCaptureSource == .email else { return nil }
        if let email = item.incomingSenderEmail,
           let currentName = contactNameForEmail(email) {
            return currentName
        }
        return item.channelName
    }
}
