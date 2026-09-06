//
//  LibraryRootViewControllerTests.swift
//  LunaTests
//

import UIKit
import XCTest
@testable import LunaWriterLibraryUI
import LunaWriterModels
import LunaWriterStorage

final class LibraryRootViewControllerTests: XCTestCase {

    // MARK: - Display mode (organiser #7)

    func testTripleColumnOnlyWhenTheEditorWouldStillGetItsMinimumWidth() {
        XCTAssertEqual(LibraryRootViewController.displayMode(forContainerWidth: 390), .automatic)
        XCTAssertEqual(LibraryRootViewController.displayMode(forContainerWidth: 744), .oneBesideSecondary)
        XCTAssertEqual(LibraryRootViewController.displayMode(forContainerWidth: 1024), .oneBesideSecondary)
        XCTAssertEqual(
            LibraryRootViewController.displayMode(forContainerWidth: LibraryRootViewController.tripleColumnMinWidth),
            .twoBesideSecondary)
        XCTAssertEqual(LibraryRootViewController.displayMode(forContainerWidth: 1366), .twoBesideSecondary)
    }

    @MainActor
    func testTheLiveSplitViewFollowsTheSameThresholdsAfterLayout() throws {
        let stack = try makeWriterStack()
        let root = LibraryRootViewController(environment: makeLibraryEnvironment(stack: stack))

        layoutWriterScreen(root, width: 390, height: 844)
        XCTAssertEqual(root.preferredDisplayMode, .automatic)

        layoutWriterScreen(root, width: 1366, height: 1024)
        XCTAssertEqual(root.preferredDisplayMode, .twoBesideSecondary)
    }

    // MARK: - Keyboard commands (organiser #11)

    @MainActor
    func testRootOffersKeyCommandsForEveryOrganiserAction() throws {
        let stack = try makeWriterStack()
        let root = LibraryRootViewController(environment: makeLibraryEnvironment(stack: stack))
        layoutWriterScreen(root)

        let commands = try XCTUnwrap(root.keyCommands)
        let inputs = Set(commands.map { "\($0.modifierFlags.rawValue)-\($0.input ?? "")" })
        XCTAssertEqual(commands.count, 11)
        XCTAssertTrue(inputs.contains("\(UIKeyModifierFlags.command.rawValue)-n"), "new sheet")
        XCTAssertTrue(
            inputs.contains("\(UIKeyModifierFlags([.command, .shift]).rawValue)-n"), "new group")
        XCTAssertTrue(inputs.contains("\(UIKeyModifierFlags.command.rawValue)-,"), "settings")
    }

    // MARK: - Compact width (organiser #29)

    /// A 390 pt root is collapsed: the sheets column has no loaded view when
    /// the sidebar's first tap arrives. Selecting a scope and creating a
    /// document from the sidebar must both work there.
    @MainActor
    func testSidebarSelectionAndNewDocumentWorkOnACompactWidth() throws {
        let stack = try makeWriterStack()
        let group = try stack.library.createGroup(name: "G", icon: "folder", parent: nil)
        let inGroup = try stack.library.createDocument(in: group.id, title: "In G")
        let editorMaker = FakeDocumentEditorMaker()
        let root = LibraryRootViewController(environment: makeLibraryEnvironment(stack: stack, editorMaker: editorMaker))
        // An offscreen window never finishes a push animation, and UIKit
        // drops a stack change made mid-transition; the app waits for the
        // transition, the test just turns animation off.
        UIView.setAnimationsEnabled(false)
        defer { UIView.setAnimationsEnabled(true) }
        let window = hostWriterScreen(root, width: 390, height: 844)
        defer { window.isHidden = true }
        XCTAssertTrue(root.isCollapsed)

        let sidebar = try XCTUnwrap(
            (root.viewController(for: .primary) as? UINavigationController)?.viewControllers.first
                as? GroupsViewController)
        let primaryStack = try XCTUnwrap(root.viewController(for: .primary) as? UINavigationController)

        root.groupsViewController(sidebar, didSelect: .group(group.id))
        pollUntil { primaryStack.topViewController is SheetsViewController }
        let sheets = try XCTUnwrap(
            primaryStack.topViewController as? SheetsViewController,
            "the collapsed stack pushes the sheets list rather than leaving the sidebar on screen")
        layoutWriterScreen(sheets)
        XCTAssertEqual(sheets.visibleRowsForTesting, [.document(inGroup.id)])

        root.groupsViewController(sidebar, requestsNewDocumentIn: nil)
        XCTAssertEqual(editorMaker.madeEditors.count, 1)
        let opened = try XCTUnwrap(root.currentDocumentIDForTesting)
        XCTAssertEqual(try XCTUnwrap(stack.library.document(opened)).groupID, stack.library.inboxGroupID)
        pollUntil { primaryStack.topViewController is EditorContainerViewController }
        XCTAssertTrue(
            primaryStack.topViewController is EditorContainerViewController,
            "the new document's editor is pushed onto the collapsed stack")
    }

    // MARK: - Selection and re-selection (organiser #10)

    @MainActor
    func testReselectingTheOpenSheetDoesNotRebuildTheEditor() throws {
        let stack = try makeWriterStack()
        let group = try stack.library.createGroup(name: "G", icon: "folder", parent: nil)
        let document = try stack.library.createDocument(in: group.id, title: "Sheet")
        let editorMaker = FakeDocumentEditorMaker()
        let root = LibraryRootViewController(environment: makeLibraryEnvironment(stack: stack, editorMaker: editorMaker))
        layoutWriterScreen(root)

        root.show(document: document)
        XCTAssertEqual(editorMaker.madeEditors.count, 1)
        XCTAssertTrue(root.hasOpenDocumentForTesting)
        XCTAssertEqual(root.currentDocumentIDForTesting, document.id)

        root.show(document: document)
        XCTAssertEqual(editorMaker.madeEditors.count, 1, "the same sheet re-selected builds no second editor")
    }

    @MainActor
    func testSwitchingToADifferentSheetFlushesTheOutgoingEditorFirst() throws {
        let stack = try makeWriterStack()
        let group = try stack.library.createGroup(name: "G", icon: "folder", parent: nil)
        let first = try stack.library.createDocument(in: group.id, title: "First")
        let second = try stack.library.createDocument(in: group.id, title: "Second")
        let editorMaker = FakeDocumentEditorMaker()
        let root = LibraryRootViewController(environment: makeLibraryEnvironment(stack: stack, editorMaker: editorMaker))
        layoutWriterScreen(root)

        root.show(document: first)
        XCTAssertEqual(editorMaker.madeEditors.first?.flushCount, 0)

        root.show(document: second)
        XCTAssertEqual(editorMaker.madeEditors.count, 2)
        XCTAssertEqual(editorMaker.madeEditors.first?.flushCount, 1, "the outgoing editor is flushed before it is replaced")
        XCTAssertEqual(root.currentDocumentIDForTesting, second.id)
    }

    // MARK: - Document closed (organiser #9)

    @MainActor
    func testTrashingTheOpenSheetClosesTheEditorColumn() throws {
        let stack = try makeWriterStack()
        let group = try stack.library.createGroup(name: "G", icon: "folder", parent: nil)
        let document = try stack.library.createDocument(in: group.id, title: "Sheet")
        let root = LibraryRootViewController(environment: makeLibraryEnvironment(stack: stack))
        layoutWriterScreen(root)

        root.show(document: document)
        XCTAssertTrue(root.hasOpenDocumentForTesting)

        try stack.library.trash(document.id)
        pollUntil { !root.hasOpenDocumentForTesting }
        XCTAssertFalse(root.hasOpenDocumentForTesting)
        XCTAssertNil(root.currentDocumentIDForTesting)
    }

    @MainActor
    func testDocumentDidCloseIgnoresAnIDThatIsNotTheOpenOne() throws {
        let stack = try makeWriterStack()
        let group = try stack.library.createGroup(name: "G", icon: "folder", parent: nil)
        let document = try stack.library.createDocument(in: group.id, title: "Sheet")
        let root = LibraryRootViewController(environment: makeLibraryEnvironment(stack: stack))
        layoutWriterScreen(root)

        root.show(document: document)
        root.documentDidClose(DocumentID())
        XCTAssertTrue(root.hasOpenDocumentForTesting)
        XCTAssertEqual(root.currentDocumentIDForTesting, document.id)
    }
    // MARK: - Restoring the last page (WP-A)

    /// A phone comes back to the sheet it was on, three deep, with nothing
    /// left mid-transition — no sidebar, no travelling there.
    @MainActor
    func testACollapsedRootRestoresTheOpenSheetOnTopOfItsList() throws {
        let stack = try makeWriterStack()
        let group = try stack.library.createGroup(name: "G", icon: "folder", parent: nil)
        let document = try stack.library.createDocument(in: group.id, title: "Sheet")
        stack.sessionState.snapshot = WriterSessionState.Snapshot(
            documentID: document.id, selection: .group(group.id), caretLocation: 4,
            keyboardVisible: true)
        let editorMaker = FakeDocumentEditorMaker()
        let root = LibraryRootViewController(
            environment: makeLibraryEnvironment(stack: stack, editorMaker: editorMaker))
        UIView.setAnimationsEnabled(false)
        defer { UIView.setAnimationsEnabled(true) }
        let window = hostWriterScreen(root, width: 390, height: 844)
        defer { window.isHidden = true }
        XCTAssertTrue(root.isCollapsed)

        let primaryStack = try XCTUnwrap(root.viewController(for: .primary) as? UINavigationController)
        XCTAssertEqual(primaryStack.viewControllers.count, 3)
        XCTAssertTrue(primaryStack.viewControllers[0] is GroupsViewController)
        let sheets = try XCTUnwrap(primaryStack.viewControllers[1] as? SheetsViewController)
        XCTAssertTrue(primaryStack.viewControllers[2] is EditorContainerViewController)
        XCTAssertNil(primaryStack.transitionCoordinator, "the restored stack is set, not pushed")
        XCTAssertEqual(root.currentDocumentIDForTesting, document.id)
        // The middle of a collapsed stack has no loaded view until it is
        // uncovered, which is when it applies the scope it was given.
        layoutWriterScreen(sheets)
        XCTAssertEqual(sheets.visibleRowsForTesting, [.document(document.id)], "the recorded scope")
        XCTAssertEqual(
            editorMaker.madeEditors.first?.restoredStates,
            [EditorEditingState(caretLocation: 4, isKeyboardVisible: true)])
    }

    /// On an iPad the sheet goes back into its own column beside the two
    /// lists, which stay on the scope it was opened from.
    @MainActor
    func testAnExpandedRootRestoresTheSheetIntoTheSecondaryColumn() throws {
        let stack = try makeWriterStack()
        let group = try stack.library.createGroup(name: "G", icon: "folder", parent: nil)
        let document = try stack.library.createDocument(in: group.id, title: "Sheet")
        stack.sessionState.snapshot = WriterSessionState.Snapshot(
            documentID: document.id, selection: .group(group.id))
        let root = LibraryRootViewController(environment: makeLibraryEnvironment(stack: stack))
        root.traitOverrides.horizontalSizeClass = .regular
        UIView.setAnimationsEnabled(false)
        defer { UIView.setAnimationsEnabled(true) }
        let window = hostWriterScreen(root, width: 1366, height: 1024)
        defer { window.isHidden = true }
        XCTAssertFalse(root.isCollapsed)

        let secondary = try XCTUnwrap(root.viewController(for: .secondary) as? EditorContainerViewController)
        XCTAssertEqual(secondary.document.id, document.id)
        XCTAssertEqual(root.currentDocumentIDForTesting, document.id)
        let sheets = try XCTUnwrap(
            (root.viewController(for: .supplementary) as? UINavigationController)?
                .viewControllers.first as? SheetsViewController)
        XCTAssertEqual(sheets.visibleRowsForTesting, [.document(document.id)])
        XCTAssertEqual(sheets.openDocumentID, document.id)
    }

    /// The sheet was trashed since the app was last open. The scope is still
    /// a page; the trashed sheet is not.
    @MainActor
    func testATrashedRecordedSheetRestoresTheScopeAlone() throws {
        let stack = try makeWriterStack()
        let group = try stack.library.createGroup(name: "G", icon: "folder", parent: nil)
        let document = try stack.library.createDocument(in: group.id, title: "Gone")
        _ = try stack.library.trash(document.id)
        stack.sessionState.snapshot = WriterSessionState.Snapshot(
            documentID: document.id, selection: .favorites)
        let editorMaker = FakeDocumentEditorMaker()
        let root = LibraryRootViewController(
            environment: makeLibraryEnvironment(stack: stack, editorMaker: editorMaker))
        UIView.setAnimationsEnabled(false)
        defer { UIView.setAnimationsEnabled(true) }
        let window = hostWriterScreen(root, width: 390, height: 844)
        defer { window.isHidden = true }

        XCTAssertEqual(editorMaker.madeEditors.count, 0, "no editor is built for a trashed sheet")
        XCTAssertNil(root.currentDocumentIDForTesting)
        XCTAssertNil(stack.sessionState.snapshot.documentID, "the gone sheet is forgotten")
        let primaryStack = try XCTUnwrap(root.viewController(for: .primary) as? UINavigationController)
        XCTAssertTrue(
            primaryStack.topViewController is SheetsViewController,
            "the recorded scope is still the page to come back to")
    }

    /// A library that was never opened has no page; the app must not push a
    /// sheets list over the sidebar on a first run.
    @MainActor
    func testAFirstRunOpensNothingAndPushesNothing() throws {
        let stack = try makeWriterStack()
        let editorMaker = FakeDocumentEditorMaker()
        let root = LibraryRootViewController(
            environment: makeLibraryEnvironment(stack: stack, editorMaker: editorMaker))
        UIView.setAnimationsEnabled(false)
        defer { UIView.setAnimationsEnabled(true) }
        let window = hostWriterScreen(root, width: 390, height: 844)
        defer { window.isHidden = true }

        let primaryStack = try XCTUnwrap(root.viewController(for: .primary) as? UINavigationController)
        XCTAssertEqual(editorMaker.madeEditors.count, 0)
        XCTAssertTrue(primaryStack.topViewController is GroupsViewController)
    }

    // MARK: - Recording the page

    @MainActor
    func testOpeningASheetAndAScopeRecordsThePageToComeBackTo() throws {
        let stack = try makeWriterStack()
        let group = try stack.library.createGroup(name: "G", icon: "folder", parent: nil)
        let document = try stack.library.createDocument(in: group.id, title: "Sheet")
        let editorMaker = FakeDocumentEditorMaker()
        let root = LibraryRootViewController(
            environment: makeLibraryEnvironment(stack: stack, editorMaker: editorMaker))
        layoutWriterScreen(root)

        let sidebar = try XCTUnwrap(
            (root.viewController(for: .primary) as? UINavigationController)?.viewControllers.first
                as? GroupsViewController)
        root.groupsViewController(sidebar, didSelect: .group(group.id))
        XCTAssertEqual(stack.sessionState.snapshot.selection, .group(group.id))

        root.show(document: document)
        XCTAssertEqual(stack.sessionState.snapshot.documentID, document.id)

        let editor = try XCTUnwrap(editorMaker.madeEditors.last)
        editor.simulateEditingState(EditorEditingState(caretLocation: 11, isKeyboardVisible: true))
        XCTAssertEqual(stack.sessionState.snapshot.caretLocation, 11)
        XCTAssertTrue(stack.sessionState.snapshot.keyboardVisible)
    }

    /// The way to the background is the last chance to record a caret the
    /// autosave has not caught up with.
    @MainActor
    func testRecordingOnTheWayToTheBackgroundTakesTheEditorsCurrentCaret() throws {
        let stack = try makeWriterStack()
        let document = try stack.library.createDocument(in: stack.library.inboxGroupID, title: "Sheet")
        let editorMaker = FakeDocumentEditorMaker()
        let root = LibraryRootViewController(
            environment: makeLibraryEnvironment(stack: stack, editorMaker: editorMaker))
        layoutWriterScreen(root)
        root.show(document: document)
        let editor = try XCTUnwrap(editorMaker.madeEditors.last)
        editor.editingState = EditorEditingState(caretLocation: 27, isKeyboardVisible: true)

        root.recordSessionState()

        XCTAssertEqual(stack.sessionState.snapshot.documentID, document.id)
        XCTAssertEqual(stack.sessionState.snapshot.caretLocation, 27)
        XCTAssertTrue(stack.sessionState.snapshot.keyboardVisible)
    }

    @MainActor
    func testClosingTheOpenSheetForgetsIt() throws {
        let stack = try makeWriterStack()
        let document = try stack.library.createDocument(in: stack.library.inboxGroupID, title: "Sheet")
        let root = LibraryRootViewController(environment: makeLibraryEnvironment(stack: stack))
        layoutWriterScreen(root)
        root.show(document: document)
        XCTAssertEqual(stack.sessionState.snapshot.documentID, document.id)

        root.documentDidClose(document.id)

        XCTAssertNil(stack.sessionState.snapshot.documentID)
        XCTAssertNil(stack.sessionState.snapshot.caretLocation)
    }

}
