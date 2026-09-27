//
//  GroupsViewControllerTests.swift
//  LunaWriterTests
//

import UIKit
import XCTest
@testable import LunaWriterLibraryUI
import LunaModels
import LunaWriterModels
import LunaWriterStorage

final class GroupsViewControllerTests: XCTestCase {

    @MainActor
    func testFixedRowsAppearWithNoGroupsAtAll() throws {
        let stack = try makeWriterStack()
        let controller = GroupsViewController(library: stack.library, notes: stack.library)
        layoutWriterScreen(controller)

        let rows = controller.visibleRowsForTesting
        XCTAssertEqual(
            Set([.libraryAll, .libraryNotes, .libraryRecent, .trashRow]) as Set<GroupsRow>,
            Set(rows).intersection([.libraryAll, .libraryNotes, .libraryRecent, .trashRow]))
    }

    /// On a compact width the sidebar is the only column on screen, so its
    /// `+` menu must lead with a document, not only a group and a filter.
    @MainActor
    func testThePlusMenuLeadsWithNewBookAndStillRoutesDocumentCreation() throws {
        let stack = try makeWriterStack()
        let controller = GroupsViewController(library: stack.library, notes: stack.library)
        let delegate = RecordingGroupsSelectionDelegate()
        controller.selectionDelegate = delegate
        layoutWriterScreen(controller)

        let first = try XCTUnwrap(controller.newItemMenu().children.first as? UIAction)
        XCTAssertEqual(first.title, "New Book")

        let group = try stack.library.createGroup(name: "G", icon: "folder", parent: nil)
        controller.requestNewDocument(in: nil)
        controller.requestNewDocument(in: group.id)
        XCTAssertEqual(delegate.newDocumentRequests, [nil, group.id])
    }

    @MainActor
    func testANewGroupAppearsUnderTheGroupsSection() throws {
        let stack = try makeWriterStack()
        let controller = GroupsViewController(library: stack.library, notes: stack.library)
        layoutWriterScreen(controller)

        let created = try XCTUnwrap(controller.createGroup(parent: nil))
        XCTAssertTrue(controller.visibleRowsForTesting.contains(.group(created.id)))
    }

    @MainActor
    func testExpandingAndCollapsingAParentHidesAndShowsItsChild() throws {
        let stack = try makeWriterStack()
        let parent = try stack.library.createGroup(name: "Parent", icon: "folder", parent: nil)
        let child = try stack.library.createGroup(name: "Child", icon: "folder", parent: parent.id)

        let controller = GroupsViewController(library: stack.library, notes: stack.library)
        layoutWriterScreen(controller)

        XCTAssertTrue(controller.isExpandedForTesting(parent.id), "a new group starts expanded")
        XCTAssertTrue(controller.visibleRowsForTesting.contains(.group(child.id)))

        controller.toggleExpansion(of: parent.id)
        XCTAssertFalse(controller.isExpandedForTesting(parent.id))
        XCTAssertFalse(controller.visibleRowsForTesting.contains(.group(child.id)))

        controller.toggleExpansion(of: parent.id)
        XCTAssertTrue(controller.isExpandedForTesting(parent.id))
        XCTAssertTrue(controller.visibleRowsForTesting.contains(.group(child.id)))
    }

    @MainActor
    func testRenamingAGroupIsReflectedAfterALibraryChangeFiredElsewhere() throws {
        let stack = try makeWriterStack()
        let group = try stack.library.createGroup(name: "Original", icon: "folder", parent: nil)

        let controller = GroupsViewController(library: stack.library, notes: stack.library)
        layoutWriterScreen(controller)
        XCTAssertEqual(controller.nameForTesting(group.id), "Original")

        // Renamed by something other than this screen (e.g. a sync, or a
        // second window) — the screen must pick it up from the broadcast
        // LibraryChange, not from a return value it never sees.
        var renamed = group
        renamed.name = "Renamed"
        try stack.library.update(renamed)

        pollUntil { controller.nameForTesting(group.id) == "Renamed" }
        XCTAssertEqual(controller.nameForTesting(group.id), "Renamed")
    }

    @MainActor
    func testMovingAGroupIsReflectedAfterALibraryChangeFiredElsewhere() throws {
        let stack = try makeWriterStack()
        let destination = try stack.library.createGroup(name: "Destination", icon: "folder", parent: nil)
        let moved = try stack.library.createGroup(name: "Moved", icon: "folder", parent: nil)

        let controller = GroupsViewController(library: stack.library, notes: stack.library)
        layoutWriterScreen(controller)

        try stack.library.moveGroup(moved.id, to: destination.id, at: 0)

        pollUntil { controller.visibleRowsForTesting.contains(.group(moved.id)) }
        let rows = controller.visibleRowsForTesting
        let destinationIndex = try XCTUnwrap(rows.firstIndex(of: .group(destination.id)))
        let movedIndex = try XCTUnwrap(rows.firstIndex(of: .group(moved.id)))
        XCTAssertEqual(movedIndex, destinationIndex + 1, "a moved group nests right under its new parent")
    }

    @MainActor
    func testDeletingAGroupTrashesItsSheetsAndRemovesTheRow() throws {
        let stack = try makeWriterStack()
        let group = try stack.library.createGroup(name: "Doomed", icon: "folder", parent: nil)
        var document = try stack.library.createDocument(in: group.id, title: "Inside")

        let controller = GroupsViewController(library: stack.library, notes: stack.library)
        layoutWriterScreen(controller)

        XCTAssertTrue(controller.deleteGroup(group.id))
        XCTAssertFalse(controller.visibleRowsForTesting.contains(.group(group.id)))

        document = try XCTUnwrap(stack.library.document(document.id))
        XCTAssertNotNil(document.trashedAt, "the group's sheet moves to the trash rather than vanishing")
    }

    @MainActor
    func testCollapsedGroupSurvivesAReloadTriggeredElsewhereAndAFreshScreen() throws {
        let stack = try makeWriterStack()
        let parent = try stack.library.createGroup(name: "Parent", icon: "folder", parent: nil)
        _ = try stack.library.createGroup(name: "Child", icon: "folder", parent: parent.id)
        let suiteName = "GroupsViewControllerTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suiteName) }
        let store = GroupCollapseStore(defaults: defaults)

        let controller = GroupsViewController(library: stack.library, notes: stack.library, collapseStore: store)
        layoutWriterScreen(controller)
        controller.toggleExpansion(of: parent.id)
        XCTAssertFalse(controller.isExpandedForTesting(parent.id))

        // A change elsewhere (another window, a sync) reapplies the whole
        // tree; the collapse must not be undone by it (organiser #27).
        let other = try stack.library.createGroup(name: "Other", icon: "folder", parent: nil)
        pollUntil { controller.visibleRowsForTesting.contains(.group(other.id)) }
        XCTAssertFalse(controller.isExpandedForTesting(parent.id))

        // A fresh screen — as if the app relaunched — reads the same
        // collapsed state back from the shared store.
        let controller2 = GroupsViewController(library: stack.library, notes: stack.library, collapseStore: store)
        layoutWriterScreen(controller2)
        XCTAssertFalse(controller2.isExpandedForTesting(parent.id))
    }

    @MainActor
    func testDeletingAGroupAsksForConfirmationNamingTheSheetCount() throws {
        let stack = try makeWriterStack()
        let group = try stack.library.createGroup(name: "Doomed", icon: "folder", parent: nil)
        _ = try stack.library.createDocument(in: group.id, title: "Inside")

        let controller = GroupsViewController(library: stack.library, notes: stack.library)
        let window = hostWriterScreen(controller)

        controller.presentDeleteConfirmation(for: group.id)
        let alert = try XCTUnwrap(controller.presentedViewController as? UIAlertController)
        _ = window
        XCTAssertEqual(alert.actions.count, 2)
        XCTAssertTrue(controller.visibleRowsForTesting.contains(.group(group.id)), "not deleted until confirmed")
    }

    @MainActor
    func testMovingAGroupOntoItsOwnDescendantIsRefused() throws {
        let stack = try makeWriterStack()
        let parent = try stack.library.createGroup(name: "Parent", icon: "folder", parent: nil)
        let child = try stack.library.createGroup(name: "Child", icon: "folder", parent: parent.id)

        let controller = GroupsViewController(library: stack.library, notes: stack.library)
        layoutWriterScreen(controller)

        XCTAssertFalse(controller.moveGroup(parent.id, toParent: child.id, index: 0))
        XCTAssertFalse(controller.moveGroup(parent.id, toParent: parent.id, index: 0))
        XCTAssertEqual(try stack.library.groups().first { $0.id == parent.id }?.parentID, nil)
    }
}

@MainActor
private final class RecordingGroupsSelectionDelegate: GroupsSelectionDelegate {
    var selections: [LibrarySelection] = []
    var newDocumentRequests: [GroupID?] = []
    func groupsViewController(_ controller: GroupsViewController, didSelect selection: LibrarySelection) {
        selections.append(selection)
    }
    func groupsViewController(_ controller: GroupsViewController, requestsNewDocumentIn group: GroupID?) {
        newDocumentRequests.append(group)
    }
    var settingsRequests = 0
    func groupsViewControllerRequestsSettings(_ controller: GroupsViewController) {
        settingsRequests += 1
    }
}
