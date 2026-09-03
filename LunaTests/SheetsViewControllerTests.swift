//
//  SheetsViewControllerTests.swift
//  LunaTests
//

import UIKit
import XCTest
@testable import LunaWriterLibraryUI
import LunaWriterModels
import LunaWriterStorage

final class SheetsViewControllerTests: XCTestCase {

    @MainActor
    func testSelectingAGroupShowsOnlyItsOwnSheets() throws {
        let stack = try makeWriterStack()
        let groupA = try stack.library.createGroup(name: "A", icon: "folder", parent: nil)
        let groupB = try stack.library.createGroup(name: "B", icon: "folder", parent: nil)
        let inA = try stack.library.createDocument(in: groupA.id, title: "In A")
        _ = try stack.library.createDocument(in: groupB.id, title: "In B")

        let controller = SheetsViewController(library: stack.library, notes: stack.library)
        layoutWriterScreen(controller)
        controller.select(.group(groupA.id))

        XCTAssertEqual(controller.visibleRowsForTesting, [.document(inA.id)])
    }

    @MainActor
    func testManualSortOrdersByTitleWhenAsked() throws {
        let stack = try makeWriterStack()
        let group = try stack.library.createGroup(name: "G", icon: "folder", parent: nil)
        let zebra = try stack.library.createDocument(in: group.id, title: "Zebra")
        let apple = try stack.library.createDocument(in: group.id, title: "Apple")

        let controller = SheetsViewController(library: stack.library, notes: stack.library)
        layoutWriterScreen(controller)
        controller.select(.group(group.id))
        controller.currentSortForTesting = .titleAscending

        XCTAssertEqual(controller.visibleRowsForTesting, [.document(apple.id), .document(zebra.id)])
    }

    @MainActor
    func testSearchNarrowsToMatchingSheetsOnly() throws {
        let stack = try makeWriterStack()
        let group = try stack.library.createGroup(name: "G", icon: "folder", parent: nil)
        var matching = try stack.library.createDocument(in: group.id, title: "Whatever")
        var nonMatching = try stack.library.createDocument(in: group.id, title: "Whatever Else")
        try stack.textStore.saveText("# Whatever\n\nSomething about lighthouses.", for: &matching)
        try stack.textStore.saveText("# Whatever Else\n\nSomething about kitchens.", for: &nonMatching)

        let controller = SheetsViewController(library: stack.library, notes: stack.library)
        layoutWriterScreen(controller)
        controller.select(.group(group.id))
        controller.currentSearchQueryForTesting = "lighthouses"

        XCTAssertEqual(controller.visibleRowsForTesting, [.document(matching.id)])
    }

    @MainActor
    func testTrailingSwipeTrashesASheetAndLeadingSwipeTogglesFavorite() throws {
        let stack = try makeWriterStack()
        let group = try stack.library.createGroup(name: "G", icon: "folder", parent: nil)
        let document = try stack.library.createDocument(in: group.id, title: "Sheet")

        let controller = SheetsViewController(library: stack.library, notes: stack.library)
        layoutWriterScreen(controller)
        controller.select(.group(group.id))

        let leading = try XCTUnwrap(controller.leadingSwipeActions(for: document.id))
        let favoriteAction = try XCTUnwrap(leading.actions.first)
        var favoriteCompleted = false
        favoriteAction.handler(favoriteAction, UIView()) { success in favoriteCompleted = success }
        XCTAssertTrue(favoriteCompleted)
        XCTAssertEqual(try stack.library.document(document.id)?.isFavorite, true)

        let trailing = try XCTUnwrap(controller.trailingSwipeActions(for: document.id))
        let trashAction = try XCTUnwrap(trailing.actions.first { $0.style == .destructive })
        var trashCompleted = false
        trashAction.handler(trashAction, UIView()) { success in trashCompleted = success }
        XCTAssertTrue(trashCompleted)
        XCTAssertNotNil(try stack.library.document(document.id)?.trashedAt)
    }

    @MainActor
    func testRestoreSwipeActionAppearsOnlyInTheTrashAndUndoesIt() throws {
        let stack = try makeWriterStack()
        let group = try stack.library.createGroup(name: "G", icon: "folder", parent: nil)
        let document = try stack.library.createDocument(in: group.id, title: "Sheet")
        try stack.library.trash(document.id)

        let controller = SheetsViewController(library: stack.library, notes: stack.library)
        layoutWriterScreen(controller)
        controller.select(.trash)

        XCTAssertTrue(controller.visibleRowsForTesting.contains(.document(document.id)))
        let trailing = try XCTUnwrap(controller.trailingSwipeActions(for: document.id))
        let restoreAction = try XCTUnwrap(trailing.actions.first)
        var completed = false
        restoreAction.handler(restoreAction, UIView()) { success in completed = success }
        XCTAssertTrue(completed)
        XCTAssertNil(try stack.library.document(document.id)?.trashedAt)
    }

    @MainActor
    func testInboxListsUnattachedNotesInASecondSection() throws {
        let stack = try makeWriterStack()
        let note = WriterNote(text: "A loose thought", source: .typed)
        try stack.library.insert(note)

        let controller = SheetsViewController(library: stack.library, notes: stack.library)
        layoutWriterScreen(controller)
        controller.select(.inbox)

        XCTAssertTrue(controller.visibleRowsForTesting.contains(.unattachedNote(note.id)))
    }

    @MainActor
    func testAttachingAnUnattachedNoteMovesItOutOfTheInboxListing() throws {
        let stack = try makeWriterStack()
        let group = try stack.library.createGroup(name: "G", icon: "folder", parent: nil)
        let document = try stack.library.createDocument(in: group.id, title: "Target")
        let note = WriterNote(text: "A loose thought", source: .typed)
        try stack.library.insert(note)

        let controller = SheetsViewController(library: stack.library, notes: stack.library)
        layoutWriterScreen(controller)
        controller.select(.inbox)
        XCTAssertTrue(controller.visibleRowsForTesting.contains(.unattachedNote(note.id)))

        XCTAssertTrue(controller.attachNote(note.id, to: document.id))
        XCTAssertFalse(controller.visibleRowsForTesting.contains(.unattachedNote(note.id)))
        XCTAssertTrue(try stack.library.notes(for: document.id).contains { $0.id == note.id })
    }

    @MainActor
    func testCreatingASheetLandsInTheSelectedGroupAndNotifiesTheDelegate() throws {
        final class Recorder: SheetsSelectionDelegate {
            var selected: WriterDocument?
            func sheetsViewController(_ controller: SheetsViewController, didSelect document: WriterDocument) {
                selected = document
            }
        }

        let stack = try makeWriterStack()
        let group = try stack.library.createGroup(name: "G", icon: "folder", parent: nil)
        let controller = SheetsViewController(library: stack.library, notes: stack.library)
        let recorder = Recorder()
        controller.selectionDelegate = recorder
        layoutWriterScreen(controller)
        controller.select(.group(group.id))

        let created = try XCTUnwrap(controller.createSheet())
        XCTAssertEqual(created.groupID, group.id)
        XCTAssertEqual(recorder.selected?.id, created.id)
    }
}
