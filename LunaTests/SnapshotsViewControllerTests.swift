//
//  SnapshotsViewControllerTests.swift
//  LunaTests
//

import UIKit
import XCTest
@testable import LunaWriterLibraryUI
import LunaWriterModels
import LunaWriterStorage

final class SnapshotsViewControllerTests: XCTestCase {

    /// organiser #39: restoring used to write straight through `textStore`
    /// while the open editor kept showing the pre-restore text, so its next
    /// autosave silently overwrote the restore. Restore now also hands the
    /// text to the open editor.
    @MainActor
    func testRestoreRoutesThroughTheOpenEditorWhenOneIsSet() throws {
        let stack = try makeWriterStack()
        let group = try stack.library.createGroup(name: "G", icon: "folder", parent: nil)
        var document = try stack.library.createDocument(in: group.id, title: "Sheet")
        try stack.textStore.saveText("First version.", for: &document)
        try stack.library.recordSnapshot("First version.", for: document.id)
        try stack.textStore.saveText("Second version.", for: &document)

        let screen = SnapshotsViewController(
            snapshotStore: stack.library, textStore: stack.textStore, document: document)
        let editor = FakeDocumentEditor(document: document)
        screen.editor = editor
        layoutWriterScreen(screen)

        let snapshot = try XCTUnwrap(screen.snapshotsForTesting.first)
        XCTAssertTrue(screen.restore(snapshot))

        XCTAssertEqual(editor.replacedTexts, [snapshot.text])
        // `restore` re-derives the title from the restored text and can move
        // the file; re-read the row rather than trust this test's now-stale
        // `document.fileRelativePath`.
        let latest = try XCTUnwrap(try stack.library.document(document.id))
        XCTAssertEqual(try stack.textStore.loadText(latest), snapshot.text)
    }

    /// With no open editor (the sheet is not on screen), restore still
    /// writes through `textStore` alone.
    @MainActor
    func testRestoreWritesThroughTextStoreAloneWithNoOpenEditor() throws {
        let stack = try makeWriterStack()
        let group = try stack.library.createGroup(name: "G", icon: "folder", parent: nil)
        var document = try stack.library.createDocument(in: group.id, title: "Sheet")
        try stack.textStore.saveText("First version.", for: &document)
        try stack.library.recordSnapshot("First version.", for: document.id)
        try stack.textStore.saveText("Second version.", for: &document)

        let screen = SnapshotsViewController(
            snapshotStore: stack.library, textStore: stack.textStore, document: document)
        layoutWriterScreen(screen)

        let snapshot = try XCTUnwrap(screen.snapshotsForTesting.first)
        XCTAssertTrue(screen.restore(snapshot))
        let latest = try XCTUnwrap(try stack.library.document(document.id))
        XCTAssertEqual(try stack.textStore.loadText(latest), snapshot.text)
    }
}
