//
//  ReadingListRowMenuFactory.swift
//  Luna
//

import LunaMediaDownload
import LunaModels
import LunaURLClassification
import UIKit

/// The handler closures (and the couple of environment facts the item alone
/// doesn't carry — whether it's in the Reading section, whether Kindle is set
/// up) that `ReadingListRowMenuFactory.menu(for:actions:)` wires into the
/// `UIMenu` it builds. Every closure is fired by exactly one action.
struct RowMenuActions {
    /// Only a Reading-section item offers "Bump to Top".
    let isInReadingSection: Bool
    /// Gates the "Send to Kindle" row — the long-press menu only offers a
    /// destination when it's configured.
    let isKindleConfigured: Bool
    let sendToFriend: () -> Void
    let sendToKindle: () -> Void
    let shareEbook: () -> Void
    let shareLink: () -> Void
    let copyLink: () -> Void
    let saveMediaToPhotos: () -> Void
    let bumpToTop: () -> Void
    let toggleTrackerArchived: () -> Void
    let unarchive: () -> Void
    let delete: () -> Void
    let editList: () -> Void
}

/// The long-press row-menu policy: which actions apply to `item`'s shape
/// (price tracker / video / document / article), independent of any
/// `UIContextMenuConfiguration` plumbing.
enum ReadingListRowMenuFactory {

    static func menu(for item: ReadingListItem, actions: RowMenuActions) -> UIMenu {
        let sendToFriend = UIAction(
            title: "Send to Contact…", image: UIImage(systemName: "person.2")
        ) { _ in actions.sendToFriend() }
        let sendToKindle = UIAction(
            title: "Send to Kindle", image: UIImage(systemName: "paperplane")
        ) { _ in actions.sendToKindle() }
        let shareEbook = UIAction(
            title: "Share eBook…", image: UIImage(systemName: "square.and.arrow.up")
        ) { _ in actions.shareEbook() }
        let shareLink = UIAction(
            title: "Share Link…", image: UIImage(systemName: "link")
        ) { _ in actions.shareLink() }
        let copyLink = UIAction(
            title: "Copy Link", image: UIImage(systemName: "doc.on.doc")
        ) { _ in actions.copyLink() }
        let delete = UIAction(
            title: "Delete", image: UIImage(systemName: "trash"), attributes: .destructive
        ) { _ in actions.delete() }
        // Videos: share to friends + delete. Documents: ereaders + read +
        // delete. Articles: everything. Each ereader row shows only when
        // that destination is set up.

        // Price trackers get a focused menu: share the tracker to a friend,
        // archive/unarchive it (archived = hidden + excluded from refresh), delete.
        if let tracker = item.priceTracker {
            var trackerChildren: [UIAction] = []
            trackerChildren.append(sendToFriend)
            let archiveTitle = tracker.isArchived ? "Unarchive Tracker" : "Archive Tracker"
            let archiveIcon = tracker.isArchived ? "tray.and.arrow.up" : "archivebox"
            trackerChildren.append(UIAction(
                title: archiveTitle, image: UIImage(systemName: archiveIcon)
            ) { _ in actions.toggleTrackerArchived() })
            trackerChildren.append(delete)
            return UIMenu(title: tracker.productName, children: trackerChildren)
        }

        var children: [UIAction] = []
        // Reading-section items only: jump an item to the top of the list.
        if actions.isInReadingSection {
            children.append(UIAction(
                title: "Bump to Top", image: UIImage(systemName: "arrow.up.to.line")
            ) { _ in actions.bumpToTop() })
        }
        if item.canShareToFriends {
            children.append(sendToFriend)
        }
        // Any item that kept a real web URL (articles and platform items) can
        // share that link.
        if item.isShareable {
            children.append(shareLink)
            children.append(copyLink)
        }
        // X / Instagram / TikTok posts: download the post's media.
        if MediaDownloadablePlatform.supports(item.urlString),
           DirectMediaURL.kind(for: item.urlString) != .audio {
            children.append(UIAction(
                title: "Save to Photos", image: UIImage(systemName: "photo.badge.arrow.down")
            ) { _ in actions.saveMediaToPhotos() })
        }
        // Article-only actions — ereader sends, and the eBook for text-only
        // no-url articles (email/document) that can't share a link.
        if !item.isPlatformItem {
            if actions.isKindleConfigured {
                children.append(sendToKindle)
            }
            if !item.isShareable, item.state == .ready {
                children.append(shareEbook)
            }
        }
        // Archived (read) items can be unarchived back to the Reading section.
        if item.readState == .read {
            children.append(UIAction(
                title: "Unarchive", image: UIImage(systemName: "tray.and.arrow.up")
            ) { _ in actions.unarchive() })
        }
        children.append(delete)
        // "Edit List" enters multi-select / drag-reorder edit mode (bottom item).
        let editList = UIAction(
            title: "Edit List", image: UIImage(systemName: "arrow.up.arrow.down")
        ) { _ in actions.editList() }
        return UIMenu(children: children + [editList])
    }
}
