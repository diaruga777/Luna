//
//  SheetsViewControllerTests.swift
//  LunaTests
//

import UIKit
import XCTest
@testable import LunaWriterLibraryUI
import LunaModels
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

        let controller = SheetsViewController(library: stack.library, notes: stack.library, textStore: stack.textStore)
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

        let controller = SheetsViewController(library: stack.library, notes: stack.library, textStore: stack.textStore)
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

        let controller = SheetsViewController(library: stack.library, notes: stack.library, textStore: stack.textStore)
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

        let controller = SheetsViewController(library: stack.library, notes: stack.library, textStore: stack.textStore)
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
    func testSwipeActionsAreReachableThroughTheRealCompositionalLayoutConfiguration() throws {
        // organiser #18: a plain (non-`override`) delegate method for swipe
        // actions is never called by a compositional list layout, so this
        // pulls the actions through the SAME `UICollectionLayoutListConfiguration`
        // providers the live layout was built from, rather than calling
        // `leadingSwipeActions(for:)`/`trailingSwipeActions(for:)` directly.
        let stack = try makeWriterStack()
        let group = try stack.library.createGroup(name: "G", icon: "folder", parent: nil)
        let document = try stack.library.createDocument(in: group.id, title: "Sheet")

        let controller = SheetsViewController(library: stack.library, notes: stack.library, textStore: stack.textStore)
        layoutWriterScreen(controller)
        controller.select(.group(group.id))

        let configuration = try XCTUnwrap(controller.swipeConfigurationForTesting)
        let leadingProvider = try XCTUnwrap(configuration.leadingSwipeActionsConfigurationProvider)
        let trailingProvider = try XCTUnwrap(configuration.trailingSwipeActionsConfigurationProvider)
        let indexPath = IndexPath(item: 0, section: 0)

        let leading = try XCTUnwrap(leadingProvider(indexPath))
        let favoriteAction = try XCTUnwrap(leading.actions.first)
        var favoriteCompleted = false
        favoriteAction.handler(favoriteAction, UIView()) { success in favoriteCompleted = success }
        XCTAssertTrue(favoriteCompleted)
        XCTAssertEqual(try stack.library.document(document.id)?.isFavorite, true)

        let trailing = try XCTUnwrap(trailingProvider(indexPath))
        XCTAssertTrue(trailing.actions.contains { $0.style == .destructive })
    }

    @MainActor
    func testContextMenuOnASheetOffersOpenFavoriteMoveKeywordsGoalDuplicateAndTrash() throws {
        let stack = try makeWriterStack()
        let group = try stack.library.createGroup(name: "G", icon: "folder", parent: nil)
        let document = try stack.library.createDocument(in: group.id, title: "Sheet")

        let controller = SheetsViewController(library: stack.library, notes: stack.library, textStore: stack.textStore)
        layoutWriterScreen(controller)
        controller.select(.group(group.id))

        let indexPath = IndexPath(item: 0, section: 0)
        XCTAssertNotNil(controller.collectionView(
            controller.collectionView, contextMenuConfigurationForItemsAt: [indexPath], point: .zero))
        let menu = try XCTUnwrap(controller.documentContextMenu(for: document.id))
        let titles = menu.children.compactMap { ($0 as? UIAction)?.title }
        XCTAssertEqual(
            Set(titles),
            Set([
                L10n.string("WriterLibrary_editor_openAction"),
                L10n.string("WriterLibrary_sheets_favoriteAction"),
                L10n.string("WriterLibrary_sheets_moveAction"),
                L10n.string("WriterLibrary_editor_keywordsAction"),
                L10n.string("WriterLibrary_editor_goalAction"),
                L10n.string("WriterLibrary_sheets_duplicateAction"),
                L10n.string("Common_delete"),
            ]))
        _ = document
    }

    @MainActor
    func testDuplicatingASheetCopiesItsTextIntoANewSheet() throws {
        let stack = try makeWriterStack()
        let group = try stack.library.createGroup(name: "G", icon: "folder", parent: nil)
        var document = try stack.library.createDocument(in: group.id, title: "Original")
        try stack.textStore.saveText("# Original\n\nSome body text.", for: &document)

        let controller = SheetsViewController(library: stack.library, notes: stack.library, textStore: stack.textStore)
        layoutWriterScreen(controller)
        controller.select(.group(group.id))

        let copy = try XCTUnwrap(controller.duplicateDocument(document.id))
        XCTAssertNotEqual(copy.id, document.id)
        XCTAssertEqual(copy.groupID, document.groupID)
        XCTAssertEqual(try stack.textStore.loadText(copy), try stack.textStore.loadText(document))
    }

    @MainActor
    func testColumnTitleNamesTheSelectedGroupOrFilter() throws {
        let stack = try makeWriterStack()
        let group = try stack.library.createGroup(name: "Essays", icon: "folder", parent: nil)
        let filter = WriterFilter(scopeGroupID: nil, name: "Drafts")
        try stack.library.save(filter)

        let controller = SheetsViewController(library: stack.library, notes: stack.library, textStore: stack.textStore)
        layoutWriterScreen(controller)

        controller.select(.group(group.id))
        XCTAssertEqual(controller.title, "Essays")

        controller.select(.filter(filter.id))
        XCTAssertEqual(controller.title, "Drafts")
    }

    @MainActor
    func testRestoreSwipeActionAppearsOnlyInTheTrashAndUndoesIt() throws {
        let stack = try makeWriterStack()
        let group = try stack.library.createGroup(name: "G", icon: "folder", parent: nil)
        let document = try stack.library.createDocument(in: group.id, title: "Sheet")
        try stack.library.trash(document.id)

        let controller = SheetsViewController(library: stack.library, notes: stack.library, textStore: stack.textStore)
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

        let controller = SheetsViewController(library: stack.library, notes: stack.library, textStore: stack.textStore)
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

        let controller = SheetsViewController(library: stack.library, notes: stack.library, textStore: stack.textStore)
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
        let controller = SheetsViewController(library: stack.library, notes: stack.library, textStore: stack.textStore)
        let recorder = Recorder()
        controller.selectionDelegate = recorder
        layoutWriterScreen(controller)
        controller.select(.group(group.id))

        let created = try XCTUnwrap(controller.createSheet())
        XCTAssertEqual(created.groupID, group.id)
        XCTAssertEqual(recorder.selected?.id, created.id)
    }
}
