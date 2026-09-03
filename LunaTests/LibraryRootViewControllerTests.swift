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
}
