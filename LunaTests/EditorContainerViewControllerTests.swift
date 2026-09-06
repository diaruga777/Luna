//
//  EditorContainerViewControllerTests.swift
//  LunaTests
//

import UIKit
import XCTest
@testable import LunaWriterLibraryUI
import LunaModels
import LunaWriterModels
import LunaWriterStorage

final class EditorContainerViewControllerTests: XCTestCase {

    @MainActor
    func testHeaderTitleFollowsTheEditorDelegateUpdate() throws {
        let stack = try makeWriterStack()
        let group = try stack.library.createGroup(name: "G", icon: "folder", parent: nil)
        let document = try stack.library.createDocument(in: group.id, title: "Original Title")
        let editorMaker = FakeDocumentEditorMaker()
        let environment = makeLibraryEnvironment(stack: stack, editorMaker: editorMaker)

        let container = EditorContainerViewController(environment: environment, document: document)
        layoutWriterScreen(container)
        XCTAssertEqual(container.headerTitleForTesting, "Original Title")

        let editor = try XCTUnwrap(editorMaker.madeEditors.first)
        var updated = document
        updated.title = "New Title"
        editor.simulateUpdate(updated)

        XCTAssertEqual(container.headerTitleForTesting, "New Title")
    }

    /// A save fires `editor(_:didUpdate:)` roughly one second after every
    /// typing burst. The trailing controls (the notes button and the ⋯
    /// button) must be the same views before and after, not rebuilt ones.
    @MainActor
    func testTrailingControlsIdentityIsStableAcrossADelegateUpdate() throws {
        let stack = try makeWriterStack()
        let group = try stack.library.createGroup(name: "G", icon: "folder", parent: nil)
        let document = try stack.library.createDocument(in: group.id, title: "Original Title")
        let editorMaker = FakeDocumentEditorMaker()
        let environment = makeLibraryEnvironment(stack: stack, editorMaker: editorMaker)

        let container = EditorContainerViewController(environment: environment, document: document)
        layoutWriterScreen(container)
        let before = container.trailingControlsForTesting

        let editor = try XCTUnwrap(editorMaker.madeEditors.first)
        var updated = document
        updated.title = "New Title"
        editor.simulateUpdate(updated)

        let after = container.trailingControlsForTesting
        XCTAssertEqual(before.count, after.count)
        XCTAssertEqual(before.map(ObjectIdentifier.init), after.map(ObjectIdentifier.init))
    }

    @MainActor
    func testEmptyTitleShowsUntitledInTheHeader() throws {
        let stack = try makeWriterStack()
        let group = try stack.library.createGroup(name: "G", icon: "folder", parent: nil)
        let document = try stack.library.createDocument(in: group.id, title: nil)
        let environment = makeLibraryEnvironment(stack: stack)

        let container = EditorContainerViewController(environment: environment, document: document)
        layoutWriterScreen(container)

        XCTAssertEqual(container.headerTitleForTesting, "Untitled")
    }

    @MainActor
    func testNotesPanelIsASideChildOnAWideLayout() throws {
        let stack = try makeWriterStack()
        let group = try stack.library.createGroup(name: "G", icon: "folder", parent: nil)
        let document = try stack.library.createDocument(in: group.id, title: "Sheet")
        let environment = makeLibraryEnvironment(stack: stack)

        let container = EditorContainerViewController(environment: environment, document: document)
        layoutWriterScreen(container, width: 1024, height: 768)

        container.toggleNotesPanel()
        XCTAssertTrue(container.isNotesPanelChildForTesting)
        XCTAssertFalse(container.isNotesPanelPresentedForTesting)
        XCTAssertTrue(container.children.contains { $0 is DocumentNotesPanelViewController })
    }

    @MainActor
    func testNotesPanelIsAPresentedSheetOnACompactLayout() throws {
        let stack = try makeWriterStack()
        let group = try stack.library.createGroup(name: "G", icon: "folder", parent: nil)
        let document = try stack.library.createDocument(in: group.id, title: "Sheet")
        let environment = makeLibraryEnvironment(stack: stack)

        let container = EditorContainerViewController(environment: environment, document: document)
        layoutWriterScreen(container, width: 390, height: 844)

        container.toggleNotesPanel()
        XCTAssertFalse(container.isNotesPanelChildForTesting)
        XCTAssertTrue(container.isNotesPanelPresentedForTesting)
    }

    @MainActor
    func testEditorRequestingTheNotesPanelOpensIt() throws {
        let stack = try makeWriterStack()
        let group = try stack.library.createGroup(name: "G", icon: "folder", parent: nil)
        let document = try stack.library.createDocument(in: group.id, title: "Sheet")
        let editorMaker = FakeDocumentEditorMaker()
        let environment = makeLibraryEnvironment(stack: stack, editorMaker: editorMaker)

        let container = EditorContainerViewController(environment: environment, document: document)
        layoutWriterScreen(container)
        XCTAssertFalse(container.isNotesPanelPresentedForTesting || container.isNotesPanelChildForTesting)

        let editor = try XCTUnwrap(editorMaker.madeEditors.first)
        editor.simulateNotesPanelRequest()

        XCTAssertTrue(container.isNotesPanelPresentedForTesting || container.isNotesPanelChildForTesting)
    }

    @MainActor
    func testTogglingFavoriteWritesThroughToTheStore() throws {
        let stack = try makeWriterStack()
        let group = try stack.library.createGroup(name: "G", icon: "folder", parent: nil)
        let document = try stack.library.createDocument(in: group.id, title: "Sheet")
        let environment = makeLibraryEnvironment(stack: stack)

        let container = EditorContainerViewController(environment: environment, document: document)
        layoutWriterScreen(container)

        XCTAssertTrue(container.toggleFavorite())
        XCTAssertEqual(try stack.library.document(document.id)?.isFavorite, true)
    }

    /// The ⋯ menu's favourite action reads `document.isFavorite` when the
    /// menu is opened (`ellipsisMenuForTesting` resolves the same children
    /// the deferred element would), not when the trailing controls were
    /// built — so a toggle needs no control rebuild to stay correct.
    @MainActor
    func testFavoriteToggleNeedsNoTrailingControlsRebuildToStayCorrect() throws {
        let stack = try makeWriterStack()
        let group = try stack.library.createGroup(name: "G", icon: "folder", parent: nil)
        let document = try stack.library.createDocument(in: group.id, title: "Sheet")
        let environment = makeLibraryEnvironment(stack: stack)

        let container = EditorContainerViewController(environment: environment, document: document)
        layoutWriterScreen(container)
        let before = container.trailingControlsForTesting

        XCTAssertTrue(container.toggleFavorite())

        XCTAssertEqual(before.map(ObjectIdentifier.init), container.trailingControlsForTesting.map(ObjectIdentifier.init))
        let favoriteAction = try XCTUnwrap(container.ellipsisMenuForTesting.children.compactMap { $0 as? UIAction }
            .first { $0.title == L10n.string("WriterLibrary_sheets_unfavoriteAction") })
        XCTAssertEqual(favoriteAction.title, L10n.string("WriterLibrary_sheets_unfavoriteAction"))
    }

    @MainActor
    func testStatisticsMessageReflectsTheSheetsSavedText() throws {
        let stack = try makeWriterStack()
        let group = try stack.library.createGroup(name: "G", icon: "folder", parent: nil)
        var document = try stack.library.createDocument(in: group.id, title: "Sheet")
        try stack.textStore.saveText("one two three four", for: &document)
        let environment = makeLibraryEnvironment(stack: stack)

        let container = EditorContainerViewController(environment: environment, document: document)
        layoutWriterScreen(container)

        XCTAssertTrue(container.statisticsMessage().contains("4"))
    }

    /// organiser #12: the export action sheet crashed on iPad with no
    /// popover anchor. The formats now live as a `UIMenu` submenu of the ⋯
    /// menu instead, so there is nothing to anchor.
    @MainActor
    func testEllipsisMenuHasAnExportSubmenuListingEveryFormat() throws {
        let stack = try makeWriterStack()
        let group = try stack.library.createGroup(name: "G", icon: "folder", parent: nil)
        let document = try stack.library.createDocument(in: group.id, title: "Sheet")
        let environment = makeLibraryEnvironment(stack: stack)

        let container = EditorContainerViewController(environment: environment, document: document)
        layoutWriterScreen(container)

        let exportMenu = try XCTUnwrap(container.ellipsisMenuForTesting.children.first {
            ($0 as? UIMenu)?.identifier == EditorContainerViewController.exportMenuIdentifier
        } as? UIMenu)
        XCTAssertEqual(exportMenu.children.count, DocumentExportFormat.allCases.count)
    }

    /// organiser #13: a swipe-down dismissal of the presented notes sheet
    /// never called `dismissNotesPanel`, so the next tap tried to dismiss a
    /// controller that was already gone.
    @MainActor
    func testInteractiveDismissalOfThePresentedNotesPanelClearsItsState() throws {
        let stack = try makeWriterStack()
        let group = try stack.library.createGroup(name: "G", icon: "folder", parent: nil)
        let document = try stack.library.createDocument(in: group.id, title: "Sheet")
        let environment = makeLibraryEnvironment(stack: stack)

        let container = EditorContainerViewController(environment: environment, document: document)
        layoutWriterScreen(container, width: 390, height: 844)
        container.toggleNotesPanel()
        XCTAssertTrue(container.isNotesPanelPresentedForTesting)

        let dismissed = UIPresentationController(
            presentedViewController: UIViewController(), presenting: nil)
        container.presentationControllerDidDismiss(dismissed)

        XCTAssertFalse(container.isNotesPanelPresentedForTesting)
        XCTAssertFalse(container.isNotesPanelChildForTesting)

        // A second toggle opens a fresh panel rather than trying to dismiss
        // the one that is already gone.
        container.toggleNotesPanel()
        XCTAssertTrue(container.isNotesPanelPresentedForTesting)
    }

    /// organiser #15: a favourite/goal/keyword change made elsewhere (the
    /// sheets list, an intent) is not reported through `DocumentEditingDelegate`
    /// — the container has to observe the library itself to pick it up.
    @MainActor
    func testHeaderFollowsADocumentChangePostedThroughTheLibrary() throws {
        let stack = try makeWriterStack()
        let group = try stack.library.createGroup(name: "G", icon: "folder", parent: nil)
        let document = try stack.library.createDocument(in: group.id, title: "Original")
        let environment = makeLibraryEnvironment(stack: stack)

        let container = EditorContainerViewController(environment: environment, document: document)
        layoutWriterScreen(container)
        XCTAssertEqual(container.headerTitleForTesting, "Original")

        // Simulates a rename made elsewhere (e.g. the sheets list), which
        // reaches the library directly rather than through this editor.
        var renamed = document
        renamed.title = "Renamed Elsewhere"
        try stack.library.update(renamed)

        // `LibraryChangeBroadcaster` posts on the main queue after the write
        // commits, so the container's observer callback lands one run-loop
        // turn later.
        pollUntil { container.headerTitleForTesting == "Renamed Elsewhere" }
        XCTAssertEqual(container.headerTitleForTesting, "Renamed Elsewhere")
    }

    // MARK: - Chrome

    @MainActor
    func testWantsChromeHiddenHidesTheHeaderAndRepinsTheEditorToTheViewTop() throws {
        let stack = try makeWriterStack()
        let group = try stack.library.createGroup(name: "G", icon: "folder", parent: nil)
        let document = try stack.library.createDocument(in: group.id, title: "Sheet")
        let editorMaker = FakeDocumentEditorMaker()
        let environment = makeLibraryEnvironment(stack: stack, editorMaker: editorMaker)

        let container = EditorContainerViewController(environment: environment, document: document)
        layoutWriterScreen(container)
        let shownTop = container.editor.view.frame.minY
        XCTAssertGreaterThan(shownTop, 0, "the editor starts below the header")
        XCTAssertFalse(container.isChromeHiddenForTesting)

        let editor = try XCTUnwrap(editorMaker.madeEditors.first)
        editor.simulateChromeHiddenRequest(true)
        container.view.layoutIfNeeded()

        XCTAssertTrue(container.isChromeHiddenForTesting)
        XCTAssertEqual(container.editor.view.frame.minY, 0, "hidden chrome pins the editor to the view's own top")
    }

    @MainActor
    func testWantsChromeShownRestoresTheHeaderAndTheOriginalPin() throws {
        let stack = try makeWriterStack()
        let group = try stack.library.createGroup(name: "G", icon: "folder", parent: nil)
        let document = try stack.library.createDocument(in: group.id, title: "Sheet")
        let editorMaker = FakeDocumentEditorMaker()
        let environment = makeLibraryEnvironment(stack: stack, editorMaker: editorMaker)

        let container = EditorContainerViewController(environment: environment, document: document)
        layoutWriterScreen(container)
        let shownTop = container.editor.view.frame.minY
        let editor = try XCTUnwrap(editorMaker.madeEditors.first)

        editor.simulateChromeHiddenRequest(true)
        container.view.layoutIfNeeded()
        editor.simulateChromeHiddenRequest(false)
        container.view.layoutIfNeeded()

        XCTAssertFalse(container.isChromeHiddenForTesting)
        XCTAssertEqual(container.editor.view.frame.minY, shownTop)
    }

    @MainActor
    func testChromeToggleFlipsTheHiddenState() throws {
        let stack = try makeWriterStack()
        let group = try stack.library.createGroup(name: "G", icon: "folder", parent: nil)
        let document = try stack.library.createDocument(in: group.id, title: "Sheet")
        let editorMaker = FakeDocumentEditorMaker()
        let environment = makeLibraryEnvironment(stack: stack, editorMaker: editorMaker)

        let container = EditorContainerViewController(environment: environment, document: document)
        layoutWriterScreen(container)
        let editor = try XCTUnwrap(editorMaker.madeEditors.first)
        XCTAssertFalse(container.isChromeHiddenForTesting)

        editor.simulateChromeToggleRequest()
        XCTAssertTrue(container.isChromeHiddenForTesting)

        editor.simulateChromeToggleRequest()
        XCTAssertFalse(container.isChromeHiddenForTesting)
    }
}
