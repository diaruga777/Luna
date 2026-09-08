//
//  LibraryFileLayoutTests.swift
//  LunaWriterTests
//

import Foundation
import XCTest
@testable import LunaWriterStorage
import LunaWriterModels

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

    func testTwoTitlesDifferingOnlyByUnicodeNormalisationCollideOntoOneFile() {
        let group = WriterGroup(name: "Essays")
        // "café" precomposed (é as U+00E9) versus decomposed (e + combining
        // acute, U+0065 U+0301) — the same word, two different byte forms.
        let precomposed = WriterDocument(groupID: group.id, title: "Café")
        let decomposedTaken = "Essays/Cafe\u{0301}.md"

        XCTAssertEqual(
            LibraryFileLayout.path(for: precomposed, groups: [group], taken: [decomposedTaken]),
            "Essays/Café 2.md",
            "a decomposed name already on disk still counts as taken")
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

    func testASaveWhoseOldFileCannotBeRemovedStillKeepsTheNewFileAndRow() throws {
        let root = try makeWriterTemporaryDirectory()
        let database = try WriterDatabase(fileURL: root.appendingPathComponent("writer.sqlite"))
        let library = try SQLiteWriterLibrary(database: database)
        let libraryRoot = root.appendingPathComponent("Library", isDirectory: true)
        let throwingManager = ThrowingRemoveFileManager()
        let store = FileDocumentTextStore(
            rootDirectory: libraryRoot, library: library, fileManager: throwingManager)

        var document = try library.createDocument(in: library.inboxGroupID, title: nil)
        try store.saveText("# First name\n\nBody.", for: &document)
        let firstPath = document.fileRelativePath
        throwingManager.pathsThatFailToRemove = [libraryRoot.appendingPathComponent(firstPath).path]

        try store.saveText("# Second name\n\nBody.", for: &document)

        XCTAssertEqual(document.fileRelativePath, "Inbox/Second name.md")
        XCTAssertEqual(
            try String(
                contentsOf: libraryRoot.appendingPathComponent(document.fileRelativePath),
                encoding: .utf8),
            "# Second name\n\nBody.")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: libraryRoot.appendingPathComponent(firstPath).path),
            "the stale file is left behind rather than the save failing")
    }

    func testALatin1FileIsDecodedRatherThanReadAsEmpty() throws {
        let stack = try makeWriterStack()
        let text = "# Notes\n\nA Latin-1 file, not UTF-8."
        let url = stack.libraryRoot.appendingPathComponent("Inbox/Notes.md")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.data(using: .isoLatin1)!.write(to: url)

        let outcome = try stack.reconciler.reconcile(LibraryFolderWatcher.scan(stack.libraryRoot))

        let document = try XCTUnwrap(
            try stack.library.document(try XCTUnwrap(outcome.added.first)))
        XCTAssertTrue(document.snippet.contains("Latin-1 file, not UTF-8."))
    }

    func testAZeroByteFileAdoptsAsAGenuinelyEmptySheet() throws {
        let stack = try makeWriterStack()
        let url = stack.libraryRoot.appendingPathComponent("Inbox/Blank.md")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: url)

        let outcome = try stack.reconciler.reconcile(LibraryFolderWatcher.scan(stack.libraryRoot))

        XCTAssertEqual(outcome.added.count, 1)
    }

    func testALookupByPathFindsTheSheetRegardlessOfTrashState() throws {
        let stack = try makeWriterStack()
        var document = try stack.library.createDocument(in: stack.library.inboxGroupID, title: nil)
        try stack.textStore.saveText("# On rivers\n\nThey run downhill.", for: &document)

        let found = try stack.library.document(atPath: document.fileRelativePath)

        XCTAssertEqual(found?.id, document.id)
        XCTAssertNil(try stack.library.document(atPath: "Inbox/Nothing here.md"))
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
