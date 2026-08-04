//
//  MediaCardPresenter.swift
//  Luna
//
//  The media kind's card behavior, defined ONCE for every app that shows a
//  Downloader save — the Downloader itself and the central Luna app. Compiled
//  into exactly those two targets (Reader and Price Tracker exclude it through
//  the synchronized group's membership exceptions, the same mechanism that keeps
//  `MediaCardFactory` out of them).
//
//  Before this existed, the Downloader's deck and the central app's all-kinds
//  deck each answered these questions separately and disagreed about: the failed
//  -download red rim (Downloader only), which store an archive wrote, whether
//  deleting an archived save released its file, the display scale, the
//  fingerprint's components, share prewarming, and the Photos reconciliation
//  pass. All of those were the same save behaving differently depending on which
//  icon you tapped.
//

import AVFoundation
import AVKit
import LunaDesignSystem
import LunaMediaDownload
import LunaModels
import LunaPlatforms
import LunaReadingListUI
import LunaSocialUI
import LunaStorage
import Photos
import UIKit

@MainActor
final class MediaCardPresenter: CardKindPresenting {

    private let store = SavedMediaStore.shared
    private let photoSaver = PhotoLibrarySaver()

    /// The downloaded media behind a platform save, if Luna holds any.
    private func media(for item: ReadingListItem) -> SavedMediaItem? {
        guard item.contentPlatform != nil else { return nil }
        return store.item(forURLString: item.urlString)
    }

    // MARK: - Slot data

    /// The media half of a card's identity: which still it shows and where its
    /// file is. Both decks now carry both components — the central app's used to
    /// omit the thumbnail, so a download that produced a poster left the card
    /// showing the old one.
    func fingerprint(for item: ReadingListItem) -> String {
        guard let media = media(for: item) else { return "" }
        return "\(media.thumbnailFileName ?? "")|\(MediaItemActions.storageStateKey(media))"
    }

    /// A media row is written by a SECOND store under its own id, so the source
    /// URL travels with the slot and a just-saved link can still be centered.
    func slotURLStrings(for item: ReadingListItem) -> [String] {
        media(for: item).map { [$0.sourceURLString] } ?? []
    }

    /// Archived in EITHER store means archived. The two used to be written
    /// separately — the Downloader archived the media row, the central deck
    /// archived the reading-list row — so a save archived in one app was still
    /// live in the other. `setArchived` now writes both; reading leniently is
    /// what reconciles the rows that were written before it did.
    func isArchived(_ item: ReadingListItem) -> Bool {
        item.isArchived || media(for: item)?.isArchived == true
    }

    var changeNotificationNames: [Notification.Name] { [.savedMediaChanged] }

    /// Darwin notifications are dropped while suspended, so also catch up on
    /// activation — which covers iPad multitasking, where the app can stay
    /// foregrounded the whole time an extension runs alongside it.
    var activationNotificationNames: [Notification.Name] {
        [UIApplication.didBecomeActiveNotification]
    }
}
