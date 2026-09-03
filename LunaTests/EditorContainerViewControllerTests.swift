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
}
