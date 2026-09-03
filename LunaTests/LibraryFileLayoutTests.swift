//
//  LibraryFileLayoutTests.swift
//  LunaTests
//

import Foundation
import XCTest
@testable import LunaWriterStorage

final class LibraryFileLayoutTests: XCTestCase {

    // MARK: - Names

    func testANameLosesTheCharactersAFileSystemWouldRefuse() {
        XCTAssertEqual(LibraryFileLayout.sanitize("Notes: 3/4 done?"), "Notes- 3-4 done-")
        XCTAssertEqual(LibraryFileLayout.sanitize("  spaced   out  "), "spaced out")
        XCTAssertEqual(LibraryFileLayout.sanitize("line\nbreak"), "line break")
    }

    func testANameIsCappedAndNeverEndsUpEmpty() {
        let long = String(repeating: "a", count: 400)
        XCTAssertEqual(
            LibraryFileLayout.sanitize(long).count, LibraryFileLayout.maximumNameLength)
        XCTAssertFalse(LibraryFileLayout.sanitize("   ").isEmpty)
        XCTAssertFalse(LibraryFileLayout.sanitize("...").isEmpty)
    }

    // MARK: - Paths

    func testTheFolderPathMirrorsTheGroupTree() {
        let book = WriterGroup(name: "Book: one")
        let chapter = WriterGroup(parentID: book.id, name: "Chapter 2")

        XCTAssertEqual(
            LibraryFileLayout.folderPath(for: chapter.id, groups: [book, chapter]),
            ["Book- one", "Chapter 2"])
        XCTAssertEqual(LibraryFileLayout.folderPath(for: book.id, groups: [book, chapter]),
                       ["Book- one"])
    }

    func testASheetSitsUnderItsGroupWithAMarkdownExtension() {
        let group = WriterGroup(name: "Essays")
        let document = WriterDocument(groupID: group.id, title: "On rivers")

        XCTAssertEqual(
            LibraryFileLayout.path(for: document, groups: [group]), "Essays/On rivers.md")
    }

    func testAClashTakesTheNextNumberRatherThanOverwriting() {
        let group = WriterGroup(name: "Essays")
        let document = WriterDocument(groupID: group.id, title: "On rivers")

        XCTAssertEqual(
            LibraryFileLayout.path(
                for: document, groups: [group], taken: ["Essays/On rivers.md"]),
            "Essays/On rivers 2.md")
        XCTAssertEqual(
            LibraryFileLayout.path(
                for: document, groups: [group],
                taken: ["essays/on rivers.md", "Essays/On rivers 2.md"]),
            "Essays/On rivers 3.md",
            "a case-insensitive file system makes these the same name")
    }

    func testAMovePlanNamesOnlyTheFilesThatHaveToMove() {
        let group = WriterGroup(name: "Essays")
        let settled = WriterDocument(
            groupID: group.id, title: "Settled", fileRelativePath: "Essays/Settled.md")
        let renamed = WriterDocument(
            groupID: group.id, title: "Renamed", fileRelativePath: "Essays/Old name.md")
        let twin = WriterDocument(
            groupID: group.id, title: "Settled", fileRelativePath: "")

        let moves = LibraryFileLayout.movePlan(for: [settled, renamed, twin], groups: [group])

        XCTAssertEqual(moves.count, 2)
        XCTAssertEqual(moves.first { $0.documentID == renamed.id }?.to, "Essays/Renamed.md")
        XCTAssertEqual(moves.first { $0.documentID == twin.id }?.to, "Essays/Settled 2.md")
        XCTAssertNil(moves.first { $0.documentID == settled.id })
    }

    func testAFolderPathFindsTheGroupItBelongsTo() {
        let book = WriterGroup(name: "Book")
        let chapter = WriterGroup(parentID: book.id, name: "Chapter")

        XCTAssertEqual(
            LibraryFileLayout.group(forFolderPath: ["Book", "Chapter"], groups: [book, chapter]),
            chapter.id)
        XCTAssertNil(
            LibraryFileLayout.group(forFolderPath: ["Book", "Missing"], groups: [book, chapter]))
    }

    // MARK: - The store on disk

    func testSavingWritesTheFileAndDerivesEverythingTheListShows() throws {
        let stack = try makeWriterStack()
        var document = try stack.library.createDocument(
            in: stack.library.inboxGroupID, title: nil)

        try stack.textStore.saveText("# On rivers\n\nThey run downhill.", for: &document)

        XCTAssertEqual(document.title, "On rivers")
        XCTAssertEqual(document.snippet, "They run downhill.")
        XCTAssertEqual(document.wordCount, 5)
        XCTAssertEqual(document.revision, 1)
        XCTAssertEqual(document.fileRelativePath, "Inbox/On rivers.md")
        let url = stack.libraryRoot.appendingPathComponent(document.fileRelativePath)
        XCTAssertEqual(
            try String(contentsOf: url, encoding: .utf8), "# On rivers\n\nThey run downhill.")
        XCTAssertEqual(try stack.library.document(document.id)?.title, "On rivers")
    }

    func testRenamingTheHeadingMovesTheFileAndLeavesNothingBehind() throws {
        let stack = try makeWriterStack()
        var document = try stack.library.createDocument(in: stack.library.inboxGroupID, title: nil)
        try stack.textStore.saveText("# First name\n\nBody.", for: &document)
        let firstPath = document.fileRelativePath

        try stack.textStore.saveText("# Second name\n\nBody.", for: &document)

        XCTAssertEqual(document.fileRelativePath, "Inbox/Second name.md")
        XCTAssertEqual(document.revision, 2)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: stack.libraryRoot.appendingPathComponent(firstPath).path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: stack.libraryRoot.appendingPathComponent(document.fileRelativePath).path))
    }

    func testTwoSheetsWithTheSameHeadingGetSeparateFiles() throws {
        let stack = try makeWriterStack()
        var first = try stack.library.createDocument(in: stack.library.inboxGroupID, title: nil)
        var second = try stack.library.createDocument(in: stack.library.inboxGroupID, title: nil)

        try stack.textStore.saveText("# Notes\n\nOne.", for: &first)
        try stack.textStore.saveText("# Notes\n\nTwo.", for: &second)

        XCTAssertEqual(first.fileRelativePath, "Inbox/Notes.md")
        XCTAssertEqual(second.fileRelativePath, "Inbox/Notes 2.md")
        XCTAssertEqual(try stack.textStore.loadText(first), "# Notes\n\nOne.")
        XCTAssertEqual(try stack.textStore.loadText(second), "# Notes\n\nTwo.")
    }

    func testLoadingASheetThatWasNeverSavedGivesEmptyTextRatherThanThrowing() throws {
        let stack = try makeWriterStack()
        let document = try stack.library.createDocument(in: stack.library.inboxGroupID, title: "New")

        XCTAssertEqual(try stack.textStore.loadText(document), "")
    }

    func testDeletingASheetsTextRemovesItsFile() throws {
        let stack = try makeWriterStack()
        var document = try stack.library.createDocument(in: stack.library.inboxGroupID, title: nil)
        try stack.textStore.saveText("# Gone\n\nSoon.", for: &document)

        try stack.textStore.deleteText(document)

        XCTAssertFalse(FileManager.default.fileExists(
            atPath: stack.libraryRoot.appendingPathComponent(document.fileRelativePath).path))
    }

    // MARK: - Scanning

    func testTheScanReportsOnlyMarkdownFilesWithPathsRelativeToTheRoot() throws {
        let stack = try makeWriterStack()
        try writeWriterFile("# One", at: "Inbox/One.md", in: stack)
        try writeWriterFile("# Two", at: "Essays/Deep/Two.md", in: stack)
        try writeWriterFile("not a sheet", at: "Inbox/notes.txt", in: stack)

        let files = LibraryFolderWatcher.scan(stack.libraryRoot)

        XCTAssertEqual(files.map(\.relativePath), ["Essays/Deep/Two.md", "Inbox/One.md"])
    }
}
