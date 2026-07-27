//
//  ReadingListSectioning.swift
//  Luna
//

import LunaModels
import Foundation

/// Pure, UIKit-free decision rules about which saved items belong where. Named
/// for the sectioned table list it was extracted from; that list is gone, and
/// what survived is the part the CARD DECKS and the read-aloud queue rely on —
/// which items an app shows, which of them read as text, and the
/// Reading/Archive/Error split that fixes autoplay order.
///
/// Everything the list alone needed (the `Section` enum and its display order,
/// the `ListFilter` segments, the filter-visibility helpers) was deleted with it.
public enum ReadingListSectioning {
    /// Items older than this (by save date) and still unread fall out of the
    /// active Reading window into the Archive bucket.
    public static let archiveAge: TimeInterval = 7 * 24 * 60 * 60

    /// Whether `item` is a kind-less failed save (the error-card state). Price
    /// trackers and platform items that merely failed a LATER step keep their own
    /// kind and their own UI, so they're excluded.
    public static func isFailedSave(_ item: ReadingListItem) -> Bool {
        item.state == .failed && !item.isPriceTracker && item.contentPlatform == nil
    }

    /// Whether the item opens in the text reader (articles, documents, emails),
    /// as opposed to media & links which open in a player, embed, or browser.
    /// Mirrors the tap routing. Price trackers are neither — they open the
    /// price-tracking screen.
    public static func rendersAsReader(_ item: ReadingListItem) -> Bool {
        !item.isPriceTracker && item.contentPlatform == nil
    }

    /// Splits items into the Reading / Archive / Error / price buckets. The
    /// Archive holds both items the user archived (read) and unread items that
    /// have aged out of the active Reading window. Failed items go to Error
    /// regardless of age or read state.
    ///
    /// Still load-bearing: `AudioPlaybackQueue` reproduces the reader surface's
    /// order from these buckets, so autoplay-next picks the same article a reader
    /// would reach next.
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
                // Archived trackers drop out entirely (still background-refresh-
                // excluded). The one unviewed-alerting tracker floats to the top of
                // the WHOLE list, not the price bucket.
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

    /// The single price tracker that should surface at the very TOP, badged red:
    /// the triggered (dropped-past-threshold) AND still-UNVIEWED, non-archived
    /// tracker with the greatest discount. Ties broken by greatest discount then
    /// by id for determinism. At most one. Nil when none qualifies — including
    /// when the user has already viewed every alert.
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
}

public extension LunaApp {
    /// Whether this app SHOWS `item` — the display counterpart to
    /// `SurfaceSupport`'s ingest gate, and the same three-way kind split.
    ///
    /// A failed save is shown by every app: it has no kind (the classifier never
    /// got far enough to give it one, which is also why the ingest gate never
    /// drops it), the app the user saved the link in is where they expect to see
    /// it break, and any app can offer the rescue that gives it a kind. Once
    /// rescued it classifies and settles into its own app.
    ///
    /// Lives here rather than on `LunaApp` in LunaModels because it needs the
    /// sectioning predicates above; the kind-free capability flags
    /// (`handlesArticles` &c.) are on the enum itself.
    func includes(_ item: ReadingListItem) -> Bool {
        if ReadingListSectioning.isFailedSave(item) { return true }
        switch self {
        case .luna: return true
        case .reader: return ReadingListSectioning.rendersAsReader(item)
        case .downloader:
            return !ReadingListSectioning.rendersAsReader(item) && !item.isPriceTracker
        case .priceTracker: return item.isPriceTracker
        }
    }
}
