//
//  ReadingListDiffTests.swift
//  LuneTests
//
//  Unit tests for the id-keyed grouped-model diff that drives the reading-list filter
//  animation: given old/new grouped models it must yield the correct section/row
//  inserts & deletes (so only changed cells animate) and the set of ids that persist
//  in place (so unchanged rows can be reconfigured silently, NOT wiped).
//

import LuneReadingListUI
import XCTest

final class ReadingListDiffTests: XCTestCase {

    private func id() -> UUID { UUID() }

    private func group(_ section: ReadingListSectioning.Section, _ ids: [UUID]) -> ReadingListGroup {
        ReadingListGroup(section: section, itemIDs: ids)
    }

    // MARK: - No-op

    func testIdenticalModelsProduceEmptyDiff() {
        let a = id(), b = id()
        let model = [group(.reading, [a, b]), group(.archive, [id()])]
        let diff = ReadingListDiff.compute(old: model, new: model)
        XCTAssertTrue(diff.isEmpty)
        XCTAssertEqual(diff.persistingItemIDs, Set(model.flatMap(\.itemIDs)))
    }

    // MARK: - Row-level changes within a persisting section

    func testFilteringOutSomeRowsDeletesOnlyThose() {
        let keep1 = id(), drop = id(), keep2 = id()
        // Drop the middle row (filter excludes it); the two surviving rows keep their
        // relative order but shift up — so the dropped row deletes and the shifted row
        // re-inserts at its new slot.
        let old = [group(.reading, [keep1, drop, keep2])]
        let new = [group(.reading, [keep1, keep2])]
        let diff = ReadingListDiff.compute(old: old, new: new)

        XCTAssertTrue(diff.deletedSections.isEmpty)
        XCTAssertTrue(diff.insertedSections.isEmpty)
        // keep1 stays at row 0 (unchanged). drop (row 1) deletes. keep2 moves row 2→1.
        XCTAssertEqual(Set(diff.deletedRows), [IndexPath(row: 1, section: 0), IndexPath(row: 2, section: 0)])
        XCTAssertEqual(Set(diff.insertedRows), [IndexPath(row: 1, section: 0)])
        // keep1 and keep2 persist; drop does not.
        XCTAssertEqual(diff.persistingItemIDs, [keep1, keep2])
    }

    func testAppendingRowsInsertsOnlyThem() {
        let a = id(), b = id(), c = id()
        let old = [group(.reading, [a, b])]
        let new = [group(.reading, [a, b, c])]
        let diff = ReadingListDiff.compute(old: old, new: new)
        XCTAssertTrue(diff.deletedRows.isEmpty)
        XCTAssertEqual(diff.insertedRows, [IndexPath(row: 2, section: 0)])
        XCTAssertFalse(diff.isEmpty)
    }

    func testUnchangedLeadingRowsStayOutOfTheDiff() {
        // A long stable prefix with one trailing insert: the prefix rows are NOT in the
        // delete/insert sets (they don't move) — this is what keeps them out of the wipe.
        let stable = (0..<5).map { _ in id() }
        let added = id()
        let old = [group(.reading, stable)]
        let new = [group(.reading, stable + [added])]
        let diff = ReadingListDiff.compute(old: old, new: new)
        XCTAssertEqual(diff.insertedRows, [IndexPath(row: 5, section: 0)])
        XCTAssertTrue(diff.deletedRows.isEmpty)
        for row in 0..<5 {
            XCTAssertFalse(diff.insertedRows.contains(IndexPath(row: row, section: 0)))
        }
    }

    // MARK: - Section-level changes

    func testWholeSectionRemovedIsADeletedSection() {
        let a = id()
        let old = [group(.reading, [a]), group(.archive, [id(), id()])]
        let new = [group(.reading, [a])]
        let diff = ReadingListDiff.compute(old: old, new: new)
        XCTAssertEqual(diff.deletedSections, IndexSet(integer: 1))
        XCTAssertTrue(diff.insertedSections.isEmpty)
        // Rows inside the deleted section are NOT separately listed — the section delete
        // covers them.
        XCTAssertTrue(diff.deletedRows.isEmpty)
    }

    func testWholeSectionAddedIsAnInsertedSection() {
        let a = id()
        let old = [group(.reading, [a])]
        let new = [group(.reading, [a]), group(.error, [id()])]
        let diff = ReadingListDiff.compute(old: old, new: new)
        XCTAssertEqual(diff.insertedSections, IndexSet(integer: 1))
        XCTAssertTrue(diff.insertedRows.isEmpty)
    }

    func testSectionIndicesAreRelativeToTheirOwnSide() {
        // Old has [reading, archive]; new drops reading and keeps archive → archive moves
        // from index 1 (old) to index 0 (new). The diff reports the section delete by its
        // OLD index and any row inserts by their NEW index.
        let arch = id()
        let old = [group(.reading, [id()]), group(.archive, [arch])]
        let new = [group(.archive, [arch])]
        let diff = ReadingListDiff.compute(old: old, new: new)
        XCTAssertEqual(diff.deletedSections, IndexSet(integer: 0))
        XCTAssertTrue(diff.insertedSections.isEmpty)
        // archive's single row is unchanged in place → no row deltas for it.
        XCTAssertTrue(diff.deletedRows.isEmpty)
        XCTAssertTrue(diff.insertedRows.isEmpty)
        XCTAssertEqual(diff.persistingItemIDs, [arch])
    }

    // MARK: - Empty-state transition

    func testEverythingFilteredOutDeletesAllSections() {
        let old = [group(.reading, [id(), id()]), group(.archive, [id()])]
        let new: [ReadingListGroup] = []
        let diff = ReadingListDiff.compute(old: old, new: new)
        XCTAssertEqual(diff.deletedSections, IndexSet([0, 1]))
        XCTAssertTrue(diff.insertedSections.isEmpty)
        XCTAssertFalse(diff.isEmpty)
    }
}
