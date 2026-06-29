//
//  ReadingListDiff.swift
//  ClipReadingListUI
//
//  Pure, table-agnostic diff of the reading list's grouped model between two states
//  (e.g. before/after a filter change), keyed by `ReadingListItem.id`. It yields the
//  index-path inserts/deletes and section inserts/deletes a `performBatchUpdates` needs,
//  plus the set of item ids that PERSIST (same id present on both sides) so the caller
//  can reconfigure those cells in place without animating them.
//
//  Why id-keyed rather than positional: a filter swaps which items are present, so the
//  same logical item can move sections/rows. The diff treats an item as unchanged when
//  its id stays in the SAME (section, row) slot; anything else is a delete of the old
//  slot + an insert of the new one. That keeps the dot-matrix wipe confined to the rows
//  that actually appear/disappear/move — untouched rows stay out of the changed region.
//

import ClipModels
import Foundation

/// One grouped section of the list: its `Section` kind and the items shown in it. A
/// lightweight mirror of the view controller's `(section, items)` tuples, made an
/// explicit type so the diff is unit-testable without a table view.
public struct ReadingListGroup: Equatable {
    public let section: ReadingListSectioning.Section
    public let itemIDs: [UUID]

    public init(section: ReadingListSectioning.Section, itemIDs: [UUID]) {
        self.section = section
        self.itemIDs = itemIDs
    }
}

/// The index-path / section changes to feed a `UITableView.performBatchUpdates`, derived
/// purely from old/new grouped models. Section indices are positions in the respective
/// (old for deletes, new for inserts) group arrays — exactly what the table expects.
public struct ReadingListDiff: Equatable {
    /// Sections present in old-but-not-new, by their index in the OLD groups.
    public var deletedSections: IndexSet
    /// Sections present in new-but-not-old, by their index in the NEW groups.
    public var insertedSections: IndexSet
    /// Rows removed from sections that persist, as index paths in the OLD layout.
    public var deletedRows: [IndexPath]
    /// Rows added to sections that persist, as index paths in the NEW layout.
    public var insertedRows: [IndexPath]
    /// Item ids present (same id) in BOTH old and new — candidates for in-place
    /// reconfiguration (their content may have changed even though the row didn't move).
    public var persistingItemIDs: Set<UUID>

    public var isEmpty: Bool {
        deletedSections.isEmpty && insertedSections.isEmpty
            && deletedRows.isEmpty && insertedRows.isEmpty
    }

    /// Diff two grouped models. A section is matched across sides by its `Section` kind
    /// (kinds are unique within a model). Within a persisting section, a row is "deleted"
    /// if its old item id is absent from the new section, and "inserted" if its new item
    /// id is absent from the old section; an id that stays but changes row index is
    /// modelled as a delete + insert (so the wipe covers both its old and new slot).
    public static func compute(old: [ReadingListGroup], new: [ReadingListGroup]) -> ReadingListDiff {
        let oldSectionIndex = Dictionary(
            uniqueKeysWithValues: old.enumerated().map { ($0.element.section, $0.offset) })
        let newSectionIndex = Dictionary(
            uniqueKeysWithValues: new.enumerated().map { ($0.element.section, $0.offset) })

        var deletedSections = IndexSet()
        var insertedSections = IndexSet()
        var deletedRows: [IndexPath] = []
        var insertedRows: [IndexPath] = []

        // Whole-section deletes/inserts.
        for (idx, group) in old.enumerated() where newSectionIndex[group.section] == nil {
            deletedSections.insert(idx)
        }
        for (idx, group) in new.enumerated() where oldSectionIndex[group.section] == nil {
            insertedSections.insert(idx)
        }

        // Row-level deltas only for sections that persist across both sides. (Rows inside
        // a deleted/inserted section are covered by the section delete/insert itself.)
        for (oldIdx, group) in old.enumerated() {
            guard let newIdx = newSectionIndex[group.section] else { continue }
            let oldIDs = group.itemIDs
            let newIDs = new[newIdx].itemIDs
            let oldSet = Set(oldIDs)
            let newSet = Set(newIDs)

            // A row "stays put" only when its id is at the SAME row index on both sides;
            // otherwise it's a delete of its old slot and an insert of its new slot.
            for (row, id) in oldIDs.enumerated() {
                let stays = row < newIDs.count && newIDs[row] == id
                if !stays { deletedRows.append(IndexPath(row: row, section: oldIdx)) }
                _ = newSet  // (kept for clarity; membership handled by the index check)
            }
            for (row, id) in newIDs.enumerated() {
                let stays = row < oldIDs.count && oldIDs[row] == id
                if !stays { insertedRows.append(IndexPath(row: row, section: newIdx)) }
                _ = oldSet
            }
        }

        // Persisting ids: same id present anywhere on both sides.
        let allOld = Set(old.flatMap(\.itemIDs))
        let allNew = Set(new.flatMap(\.itemIDs))
        let persisting = allOld.intersection(allNew)

        return ReadingListDiff(
            deletedSections: deletedSections,
            insertedSections: insertedSections,
            deletedRows: deletedRows,
            insertedRows: insertedRows,
            persistingItemIDs: persisting)
    }
}
