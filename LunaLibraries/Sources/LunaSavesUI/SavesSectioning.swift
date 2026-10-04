//
//  SavesSectioning.swift
//  Luna
//

import LunaModels
import Foundation

/// Pure, UIKit-free rules for grouping saved items: which items an app shows,
/// which of them read as text, and the Reading/Archive/Error split that fixes
/// autoplay order. The card decks and the read-aloud queue both depend on it.
public enum SavesSectioning {
    /// The display kind inferred from the shape of a stored save.
    ///
    /// This is intentionally not `ContentKind`: ingest's classifier is allowed
    /// to refine its answer while processing (for example, a social post can
    /// become an article), while this value answers how the settled row should
    /// surface. Keep every consumer of stored-save kind on this one pure
    /// resolver rather than independently probing the row's optional payloads.
    public enum Kind: Equatable, Sendable {
        /// A save that failed before it acquired a content kind.
        case failed
        case link
        case product
        case media
        case article
    }

    /// Items older than this (by save date) and still unread fall out of the
    /// active Reading window into the Archive bucket.
    public static let archiveAge: TimeInterval = 7 * 24 * 60 * 60

    /// Resolves the kind a stored save currently presents as, solely from its
    /// persisted shape. The precedence is deliberate: a kind-less failure has
    /// no presenter, then product and media payloads own their specialised
    /// cards, and the remaining saves are reader items.
    public static func kind(for item: SavedItem) -> Kind {
        if item.state == .link { return .link }
        if item.state == .failed && !item.isPriceTracker && item.contentPlatform == nil {
            return .failed
        }
        if item.isPriceTracker { return .product }
        if item.contentPlatform != nil { return .media }
        return .article
    }

    /// Whether `item` is a kind-less failed save (the error-card state). Price
    /// trackers and platform items that merely failed a LATER step keep their own
    /// kind and their own UI, so they're excluded.
    public static func isFailedSave(_ item: SavedItem) -> Bool {
        kind(for: item) == .failed
    }

    /// Whether the item opens in the text reader (articles, documents, emails),
    /// as opposed to media & links which open in a player, embed, or browser.
    /// Mirrors the tap routing. Price trackers are neither — they open the
    /// price-tracking screen.
    public static func rendersAsReader(_ item: SavedItem) -> Bool {
        kind(for: item) == .article
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
        items: [SavedItem],
        now: Date
    ) -> (reading: [SavedItem], archive: [SavedItem], failed: [SavedItem],
          priceTracking: [SavedItem]) {
        var reading: [SavedItem] = []
        var archive: [SavedItem] = []
        var failed: [SavedItem] = []
        var priceTracking: [SavedItem] = []
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
    public static func topUnviewedAlertingPriceTracker(items: [SavedItem]) -> SavedItem? {
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
    /// `SurfaceSupport`'s ingest gate. The stored-save kind comes from
    /// `SavesSectioning.kind(for:)`, shared with the card-presenter registry.
    ///
    /// A failed save is shown by every app: it has no kind (the classifier never
    /// got far enough to give it one, which is also why the ingest gate never
    /// drops it), the app the user saved the link in is where they expect to see
    /// it break, and any app can offer the rescue that gives it a kind. Once
    /// rescued it classifies and settles into its own app.
    ///
    /// Lives here rather than on `LunaApp` in LunaModels because resolving a
    /// stored save's kind belongs to `LunaSavesUI`; the kind-free capability
    /// flags (`handlesArticles` &c.) are on the enum itself.
    func includes(_ item: SavedItem) -> Bool {
        switch SavesSectioning.kind(for: item) {
        case .failed:
            return true
        case .link:
            return self == .luna
        case .article:
            return handlesArticles
        case .media:
            return handlesMedia
        case .product:
            return handlesProducts
        }
    }
}
