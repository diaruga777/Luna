//
//  ReadingListSectioning.swift
//  Clip
//

import Foundation

/// Pure, UIKit-free decision logic for how the reading list is sliced into
/// sections, which items qualify for catch-up, and when the catch-up
/// "action needed" dot lights up. Extracted from `ReadingListViewController`
/// so it can be unit-tested without a view controller, store, or simulator.
enum ReadingListSectioning {
    /// Items older than this (by save date) and still unread fall out of the
    /// active Reading window into the Archive section.
    static let archiveAge: TimeInterval = 7 * 24 * 60 * 60

    /// The unread count at (and above) which the catch-up dot turns on even
    /// without a locked save.
    static let catchUpDotUnreadThreshold = 10

    /// Sections the reading list groups items into. Raw values are STABLE
    /// (persisted in the collapsed-sections key), so new cases append at the
    /// end and existing ones keep their numbering; display order is
    /// `displayOrder`, not the declaration order.
    enum Section: Int, CaseIterable {
        case reading = 0
        case archive = 2
        case error = 3
        case pasteboard = 4

        var title: String {
            switch self {
            case .reading: return "Reading"
            case .archive: return "Archive"
            case .error: return "Couldn't Load"
            case .pasteboard: return "From Pasteboard"
            }
        }

        /// Reading and the pasteboard suggestion are always open; the rest collapse.
        var isCollapsible: Bool {
            switch self {
            case .reading, .pasteboard: return false
            case .archive, .error: return true
            }
        }
    }

    /// Top-to-bottom display order of the sections.
    static let displayOrder: [Section] = [.pasteboard, .reading, .archive, .error]

    /// What the list shows: everything, only articles (anything that opens in
    /// the text reader), or only media & links (everything else).
    enum ListFilter: Int, CaseIterable {
        case all = 0
        case articles = 1
        case mediaAndLinks = 2

        var displayName: String {
            switch self {
            case .all: return "All"
            case .articles: return "Articles"
            case .mediaAndLinks: return "Media & Links"
            }
        }

        func includes(_ item: ReadingListItem) -> Bool {
            switch self {
            case .all: return true
            case .articles: return ReadingListSectioning.rendersAsReader(item)
            case .mediaAndLinks: return !ReadingListSectioning.rendersAsReader(item)
            }
        }
    }

    /// Whether the item opens in the text reader (articles, documents, emails),
    /// as opposed to media & links (YouTube, platform posts, music/podcasts)
    /// which open in a player, embed, or browser. Mirrors the tap routing.
    static func rendersAsReader(_ item: ReadingListItem) -> Bool {
        item.contentPlatform == nil && !item.isYouTubeVideo
    }

    /// Splits the (already filter-applied) items into the Reading / Archive /
    /// Error buckets. The Archive holds both items the user archived (read) and
    /// unread items that have aged out of the active Reading window. Failed
    /// items go to Error regardless of age or read state.
    ///
    /// Returns each bucket in input order. The Pasteboard section is injected
    /// by the caller (it's a transient, unsaved suggestion).
    static func assignSections(
        items: [ReadingListItem],
        now: Date
    ) -> (reading: [ReadingListItem], archive: [ReadingListItem], failed: [ReadingListItem]) {
        var reading: [ReadingListItem] = []
        var archive: [ReadingListItem] = []
        var failed: [ReadingListItem] = []
        for item in items {
            if item.state == .failed {
                failed.append(item)
            } else if item.readState == .read
                        || now.timeIntervalSince(item.dateAdded) > archiveAge {
                archive.append(item)
            } else {
                reading.append(item)
            }
        }
        return (reading, archive, failed)
    }

    /// The Articles / Media filter is only meaningful when the list has BOTH a
    /// reader item and a media/link item; otherwise it's pointless and hidden.
    static func shouldShowFilter(items: [ReadingListItem]) -> Bool {
        let hasReaderItem = items.contains(where: rendersAsReader)
        let hasMediaOrLink = items.contains { !rendersAsReader($0) }
        return hasReaderItem && hasMediaOrLink
    }

    /// Items worth catching up on: unread (incl. partially read), and
    /// renderable (ready articles or locked paywalled articles, or any
    /// platform/media item), oldest first by bump date (falling back to save
    /// date).
    static func catchUpQueue(items: [ReadingListItem]) -> [ReadingListItem] {
        items.filter { item in
            guard item.readState != .read else { return false }
            // Locked (needsCaptcha) articles show as locked cards; other
            // readers need their content ready; non-readers always qualify.
            return rendersAsReader(item)
                ? (item.state == .ready || item.state == .needsCaptcha) : true
        }.sorted { ($0.bumpDate ?? $0.dateAdded) < ($1.bumpDate ?? $1.dateAdded) }
    }

    /// Whether the red "action needed" dot should show: once there are 10+
    /// unread items, OR whenever there's an unarchived LOCKED (paywalled,
    /// awaiting unlock) save — regardless of count.
    static func shouldShowCatchUpDot(items: [ReadingListItem]) -> Bool {
        let unread = items.filter { $0.readState != .read }
        let hasLockedSave = unread.contains { $0.state == .needsCaptcha }
        return unread.count >= catchUpDotUnreadThreshold || hasLockedSave
    }
}
