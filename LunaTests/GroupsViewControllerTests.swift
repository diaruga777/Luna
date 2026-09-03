//
//  GroupsViewControllerTests.swift
//  LunaTests
//

import UIKit
import XCTest
@testable import LunaWriterLibraryUI
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
            Set([.libraryAll, .libraryRecent, .libraryFavorites, .inboxRow, .trashRow]) as Set<GroupsRow>,
            Set(rows).intersection([.libraryAll, .libraryRecent, .libraryFavorites, .inboxRow, .trashRow]))
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
}
