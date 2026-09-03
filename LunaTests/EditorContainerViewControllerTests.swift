//
//  EditorContainerViewControllerTests.swift
//  LunaTests
//

import UIKit
import XCTest
@testable import LunaWriterLibraryUI
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
}
