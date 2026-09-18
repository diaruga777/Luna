//
//  ChapterOrganizerTests.swift
//  LunaWriterTests
//

import UIKit
import XCTest
@testable import LunaWriterStorage
@testable import LunaWriterLibraryUI
import LunaWriterModels

final class ChapterOrganizerTests: XCTestCase {

    private func makeSheet(_ text: String, in group: GroupID? = nil, stack: WriterStorageStack) throws -> WriterDocument {
        var document = try stack.library.createDocument(in: group ?? stack.library.inboxGroupID, title: nil)
        try stack.textStore.saveText(text, for: &document)
        return document
    }

    func testTheFirstSplitOfAnInboxSheetMakesATopLevelProjectAroundIt() throws {
        let stack = try makeWriterStack()
        let sheet = try makeSheet("# Voyage\n\nThe sea was calm.", stack: stack)
        let organizer = ChapterOrganizer(library: stack.library, textStore: stack.textStore)

        let chapter = try organizer.startNewChapter(after: sheet, text: "\n\nThen the storm.")

        let project = try XCTUnwrap(stack.library.groups().first { $0.kind == .project })
        XCTAssertEqual(project.name, "Voyage")
        XCTAssertNil(project.parentID)
        XCTAssertEqual(project.iconName, ChapterOrganizer.projectIcon)
        let chapters = try stack.library.documents(in: project.id, sort: .manual)
        XCTAssertEqual(chapters.map(\.id), [sheet.id, chapter.id])
        XCTAssertEqual(chapter.title, "Chapter 2")
        XCTAssertEqual(try stack.textStore.loadText(chapter), "# Chapter 2\n\nThen the storm.")
    }

    func testALaterSplitAddsTheChapterRightAfterTheCurrentOne() throws {
        let stack = try makeWriterStack()
        let sheet = try makeSheet("# Voyage\n\nOne.", stack: stack)
        let organizer = ChapterOrganizer(library: stack.library, textStore: stack.textStore)
        let second = try organizer.startNewChapter(after: sheet, text: "Two.")
        let third = try organizer.startNewChapter(after: second, text: "Three.")
        let inserted = try organizer.startNewChapter(after: sheet, text: "Between.")

        let projects = try stack.library.groups().filter { $0.kind == .project }
        XCTAssertEqual(projects.count, 1, "the second split reuses the project")
        let chapters = try stack.library.documents(in: projects[0].id, sort: .manual)
        XCTAssertEqual(chapters.map(\.id), [sheet.id, inserted.id, second.id, third.id])
        XCTAssertEqual(third.title, "Chapter 3")
        XCTAssertEqual(inserted.title, "Chapter 2", "numbered by its place, not by how many exist")
    }

    func testMovedTextThatStartsWithAHeadingKeepsItAsTheChapterTitle() throws {
        let stack = try makeWriterStack()
        let sheet = try makeSheet("# Voyage\n\nOne.", stack: stack)
        let organizer = ChapterOrganizer(library: stack.library, textStore: stack.textStore)
        let chapter = try organizer.startNewChapter(after: sheet, text: "\n\n## The Storm\n\nTwo.")
        XCTAssertEqual(chapter.title, "The Storm")
        XCTAssertEqual(try stack.textStore.loadText(chapter), "## The Storm\n\nTwo.")
    }

    func testASheetInsideAFolderGetsItsProjectInsideThatFolder() throws {
        let stack = try makeWriterStack()
        let folder = try stack.library.createGroup(name: "Drafts", icon: "folder", parent: nil)
        let sheet = try makeSheet("Untitled thoughts", in: folder.id, stack: stack)
        let organizer = ChapterOrganizer(library: stack.library, textStore: stack.textStore)
        _ = try organizer.startNewChapter(after: sheet, text: "")

        let project = try XCTUnwrap(stack.library.groups().first { $0.kind == .project })
        XCTAssertEqual(project.parentID, folder.id)
        XCTAssertEqual(project.name, "Untitled thoughts")
        XCTAssertTrue(try stack.library.documents(in: folder.id, sort: .manual).isEmpty, "the sheet moved in")
    }

    @MainActor
    func testProjectListOpensInChapterOrderAndReorders() throws {
        let stack = try makeWriterStack()
        let first = try makeSheet("# Voyage", stack: stack)
        let organizer = ChapterOrganizer(library: stack.library, textStore: stack.textStore)
        let second = try organizer.startNewChapter(after: first, text: "# Storm")
        let third = try organizer.startNewChapter(after: second, text: "# Home")
        let project = try XCTUnwrap(stack.library.groups().first { $0.kind == .project })
        let controller = SheetsViewController(library: stack.library, notes: stack.library, textStore: stack.textStore)
        layoutWriterScreen(controller)
        controller.select(.group(project.id))
        XCTAssertEqual(controller.currentSortForTesting, .manual)
        XCTAssertEqual(controller.visibleRowsForTesting, [first, second, third].map { .document($0.id) })
        XCTAssertTrue(controller.reorderDocument(third.id, toIndex: 1))
        XCTAssertEqual(controller.visibleRowsForTesting, [first, third, second].map { .document($0.id) })
        controller.select(.inbox)
        XCTAssertEqual(controller.currentSortForTesting, .modifiedDescending)
    }

    @MainActor
    func testTheSidebarListsAProjectLikeAFolder() throws {
        let stack = try makeWriterStack()
        let sheet = try makeSheet("# Voyage", stack: stack)
        _ = try ChapterOrganizer(library: stack.library, textStore: stack.textStore)
            .startNewChapter(after: sheet, text: "")
        let project = try XCTUnwrap(stack.library.groups().first { $0.kind == .project })

        let controller = GroupsViewController(library: stack.library, notes: stack.library)
        layoutWriterScreen(controller)
        XCTAssertTrue(controller.visibleRowsForTesting.contains(.group(project.id)))
    }
}
