//
//  ReadingListSectioning.swift
//  Luna
//

import LunaModels
import Foundation

/// Pure, UIKit-free decision logic for how the reading list is sliced into
/// sections. Extracted from `ReadingListViewController` so it can be
/// unit-tested without a view controller, store, or simulator.
public enum ReadingListSectioning {
    /// Items older than this (by save date) and still unread fall out of the
    /// active Reading window into the Archive section.
    public static let archiveAge: TimeInterval = 7 * 24 * 60 * 60

    /// Sections the reading list groups items into. Raw values are STABLE
    /// (persisted in the collapsed-sections key), so new cases append at the
    /// end and existing ones keep their numbering; display order is
    /// `displayOrder`, not the declaration order.
    public enum Section: Int, CaseIterable {
        case reading = 0
        case archive = 2
        case error = 3
        case pasteboard = 4
        case priceTracking = 5
        case priceAlert = 6

        public var title: String {
            switch self {
            case .reading: return "Reading"
            case .archive: return "Archive"
            case .error: return "Couldn't Load"
            case .pasteboard: return "From Pasteboard"
            case .priceTracking: return "Price tracking"
            case .priceAlert: return "Price drop"
            }
        }

        /// Reading and the pasteboard suggestion are always open; the rest collapse.
        public var isCollapsible: Bool {
            switch self {
            case .reading, .pasteboard, .priceTracking, .priceAlert: return false
            case .archive, .error: return true
            }
        }
    }

    /// Top-to-bottom display order of the sections. Price tracking sits BELOW the
    /// active Reading list (a triggered-but-unviewed tracker still floats to the very
    /// top of the whole list, ahead of the pasteboard suggestion — see `assignSections`
    /// / `topUnviewedAlertingPriceTracker`).
    public static let displayOrder: [Section] = [.priceAlert, .pasteboard, .reading, .priceTracking, .archive, .error]

    /// What the list shows: everything, only articles (anything that opens in
    /// the text reader), or only media & links (everything else).
    public enum ListFilter: Int, CaseIterable {
        case all = 0
        case articles = 1
        case mediaAndLinks = 2
        case priceTrackers = 3

        public var displayName: String {
            switch self {
            case .all: return "All"
            case .articles: return "Articles"
            case .mediaAndLinks: return "Media & Links"
            case .priceTrackers: return "Price"
            }
        }

        public func includes(_ item: ReadingListItem) -> Bool {
            switch self {
            case .all: return true
            case .articles: return ReadingListSectioning.rendersAsReader(item)
            case .mediaAndLinks:
                return !ReadingListSectioning.rendersAsReader(item) && !item.isPriceTracker
            case .priceTrackers: return item.isPriceTracker
            }
        }
    }

    /// Whether the item opens in the text reader (articles, documents, emails),
    /// as opposed to media & links
    /// which open in a player, embed, or browser. Mirrors the tap routing. Price
    /// trackers are neither — they open the price-tracking screen.
    public static func rendersAsReader(_ item: ReadingListItem) -> Bool {
        !item.isPriceTracker && item.contentPlatform == nil
    }

    /// Splits the (already filter-applied) items into the Reading / Archive /
    /// Error buckets. The Archive holds both items the user archived (read) and
    /// unread items that have aged out of the active Reading window. Failed
    /// items go to Error regardless of age or read state.
    ///
    /// Returns each bucket in input order. The Pasteboard section is injected
    /// by the caller (it's a transient, unsaved suggestion).
    public static func assignSections(
        items: [ReadingListItem],
        now: Date
    ) -> (reading: [ReadingListItem], archive: [ReadingListItem], failed: [ReadingListItem],
          priceTracking: [ReadingListItem]) {
        var reading: [ReadingListItem] = []
        var archive: [ReadingListItem] = []
        var failed: [ReadingListItem] = []
        var priceTracking: [ReadingListItem] = []
        // The single triggered-but-unviewed tracker that floats to the very top (if any).
        let pinned = topUnviewedAlertingPriceTracker(items: items)
        for item in items {
            if let tracker = item.priceTracker {
                // Archived trackers drop out of the list entirely (still
                // background-refresh-excluded). The one unviewed-alerting tracker
                // floats to the top of the WHOLE list, not the price-tracking section.
                if tracker.isArchived || item.id == pinned?.id { continue }
                priceTracking.append(item)
            } else if item.state == .failed {
                failed.append(item)
            } else if item.isArchived
                        || (item.readState == .read && item.pendingArchiveAt == nil)
                        || now.timeIntervalSince(item.dateAdded) > archiveAge {
                archive.append(item)
            } else {
                reading.append(item)
            }
        }
        return (reading, archive, failed, priceTracking)
    }

    /// The single price tracker that should surface at the very TOP of the whole
    /// list, badged red: the triggered (dropped-past-threshold) AND still-UNVIEWED,
    /// non-archived tracker with the greatest discount. Ties broken by greatest
    /// discount then by id for determinism. At most one. Nil when none qualifies —
    /// including when the user has already viewed every alert, in which case the
    /// alerting trackers stay in the price-tracking section below Reading.
    public static func topUnviewedAlertingPriceTracker(items: [ReadingListItem]) -> ReadingListItem? {
        items
            .filter { $0.priceTracker?.hasUnviewedAlert == true }
            .max { lhs, rhs in
                let lhsDiscount = lhs.priceTracker?.discountFraction ?? 0
                let rhsDiscount = rhs.priceTracker?.discountFraction ?? 0
                if lhsDiscount != rhsDiscount { return lhsDiscount < rhsDiscount }
                return lhs.id.uuidString < rhs.id.uuidString
            }
    }

    /// The filter segment is meaningful when the list has at least two of the
    /// three kinds (reader, media/link, price tracker); otherwise it's pointless
    /// and hidden.
    public static func shouldShowFilter(items: [ReadingListItem]) -> Bool {
        let nonArchivedTrackers = items.filter { $0.priceTracker?.isArchived == false }
        let hasReaderItem = items.contains(where: rendersAsReader)
        let hasMediaOrLink = items.contains { !rendersAsReader($0) && !$0.isPriceTracker }
        let hasPriceTracker = !nonArchivedTrackers.isEmpty
        let kinds = [hasReaderItem, hasMediaOrLink, hasPriceTracker].filter { $0 }.count
        return kinds >= 2
    }

    public static func hasMediaAndLinks(items: [ReadingListItem]) -> Bool {
        items.contains {
            !ReadingListSectioning.rendersAsReader($0)
            && !$0.isPriceTracker
        }
    }

    /// Whether the price-tracking section/filter segment should appear — i.e. at
    /// least one non-archived tracker exists.
    public static func hasPriceTrackers(items: [ReadingListItem]) -> Bool {
        items.contains { $0.priceTracker?.isArchived == false }
    }

}

/// Which standalone Luna app a reading-list screen renders for. The three apps share
/// ONE App Group and ONE `readingList.json`: any link saved through any surface is
/// classified and stored the same way, and each app shows ONLY the single content
/// category that matches it. Items of other categories are still ingested and stored —
/// they simply surface in their own app.
///
/// `ReadingListViewController(surface:)` takes `AppSurface?`; `nil` means the legacy
/// combined list (all categories, with the filter segments) used by tests and dev tools.
public enum AppSurface {
    /// The central Luna app — every content category in one list.
    case all
    /// Luna Reader — articles, paywalled articles, documents (anything that opens in
    /// the text reader).
    case reader
    /// Luna Downloader — social / video / audio posts (media & links).
    case downloader
    /// Luna Price Tracker — product price trackers.
    case priceTracker

    /// The single content category this surface shows.
    public var baseFilter: ReadingListSectioning.ListFilter {
        switch self {
        case .all: return .all
        case .reader: return .articles
        case .downloader: return .mediaAndLinks
        case .priceTracker: return .priceTrackers
        }
    }

    /// Whether `item` belongs to this surface (and should therefore be shown here).
    public func includes(_ item: ReadingListItem) -> Bool {
        baseFilter.includes(item)
    }

    /// Per-kind capability of the app this surface belongs to. The central
    /// Luna app handles everything; each single-content app handles one kind.
    public var handlesArticles: Bool { self == .all || self == .reader }
    public var handlesMedia: Bool { self == .all || self == .downloader }
    public var handlesProducts: Bool { self == .all || self == .priceTracker }
}
