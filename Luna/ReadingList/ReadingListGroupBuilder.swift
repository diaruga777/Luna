//
//  ReadingListGroupBuilder.swift
//  Luna
//

import LunaModels
import LunaReadingListUI
import Foundation

/// Builds the reading list's non-empty grouped model (sections x items, in
/// display order) as a pure function of its inputs — no store reads, no
/// mutable state. `ReadingListViewController` resolves the store contents,
/// current filter, and pasteboard-suggestion row itself and passes them in,
/// so a filter change (or any other reload) can diff the old/new models
/// without this step reaching back into anything live.
enum ReadingListGroupBuilder {

    static func buildGroups(
        items unfiltered: [ReadingListItem],
        filter: ReadingListSectioning.ListFilter,
        surface: AppSurface?,
        pasteboardRow: ReadingListItem?,
        now: Date
    ) -> [(section: ReadingListSectioning.Section, items: [ReadingListItem])] {
        // A concrete surface restricts the whole list to its single category (other
        // categories live in the same store but surface in their own app); the combined
        // list (surface == nil) honours the user-selected filter segment.
        let all = unfiltered.filter { surface?.includes($0) ?? filter.includes($0) }
        let buckets = ReadingListSectioning.assignSections(items: all, now: now)
        var bySection: [ReadingListSectioning.Section: [ReadingListItem]] =
            [.reading: buckets.reading, .archive: buckets.archive, .error: buckets.failed]

        // The price-tracking section sits BELOW Reading. The single triggered-but-
        // UNVIEWED tracker floats to the very TOP of the whole list as its own
        // one-row `.priceAlert` section, badged red; it's excluded from the
        // price-tracking section body by `assignSections`. Once viewed, it rejoins
        // the price-tracking section below Reading.
        bySection[.priceTracking] = buckets.priceTracking
        if let pinned = ReadingListSectioning.topUnviewedAlertingPriceTracker(items: all) {
            bySection[.priceAlert] = [pinned]
        }

        // The pasteboard suggestion: a spinner row while evaluating, then the
        // resolved candidate (unless it's since been saved by some path — the
        // caller is responsible for that check; this step just renders what
        // it's handed).
        if let pasteboardRow {
            bySection[.pasteboard] = [pasteboardRow]
        }

        return ReadingListSectioning.displayOrder.compactMap { section in
            let items = bySection[section] ?? []
            return items.isEmpty ? nil : (section, items)
        }
    }
}
