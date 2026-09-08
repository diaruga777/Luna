//
//  WriterSessionStateTests.swift
//  LunaWriterTests
//

import XCTest
import LunaWriterModels
@testable import LunaWriterStorage

final class WriterSessionStateTests: XCTestCase {

    private func makeState() -> WriterSessionState {
        let suiteName = "luna.writer.session.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suiteName) }
        return WriterSessionState(defaults: defaults)
    }

    func testAFreshInstallHasNoPageToReturnTo() {
        let state = makeState()
        XCTAssertFalse(state.hasSnapshot)
        XCTAssertEqual(state.snapshot, WriterSessionState.Snapshot())
        XCTAssertNil(state.snapshot.documentID)
        XCTAssertEqual(state.snapshot.selection, .all)
    }

    func testAWrittenSnapshotComesBackWhole() {
        let state = makeState()
        let group = GroupID()
        let document = DocumentID()
        state.snapshot = WriterSessionState.Snapshot(
            documentID: document, selection: .group(group), caretLocation: 42, keyboardVisible: true)

        XCTAssertTrue(state.hasSnapshot)
        XCTAssertEqual(
            state.snapshot,
            WriterSessionState.Snapshot(
                documentID: document, selection: .group(group), caretLocation: 42,
                keyboardVisible: true))
    }

    func testEverySelectionSurvivesTheRoundTrip() {
        let cases: [LibrarySelectionValue] = [
            .all, .recent, .favorites, .inbox, .trash, .group(GroupID()), .filter(FilterID()),
        ]
        for selection in cases {
            XCTAssertEqual(
                LibrarySelectionValue(storageValue: selection.storageValue), selection,
                "\(selection)")
        }
    }

    func testAnUnreadableSelectionRestoresTheWholeLibrary() {
        XCTAssertNil(LibrarySelectionValue(storageValue: "group:not-a-uuid"))
        XCTAssertNil(LibrarySelectionValue(storageValue: "somethingElse"))

        let state = makeState()
        state.snapshot = WriterSessionState.Snapshot(selection: .favorites)
        state.recordSelection(.recent)
        XCTAssertEqual(state.snapshot.selection, .recent)
    }

    func testOpeningADifferentSheetDropsTheOldSheetsCaret() {
        let state = makeState()
        let first = DocumentID()
        state.snapshot = WriterSessionState.Snapshot(
            documentID: first, selection: .inbox, caretLocation: 12, keyboardVisible: true)

        state.recordOpenDocument(DocumentID())
        XCTAssertNil(state.snapshot.caretLocation)
        XCTAssertFalse(state.snapshot.keyboardVisible)
        XCTAssertEqual(state.snapshot.selection, .inbox, "the scope is not a property of the sheet")
    }

    func testReopeningTheSameSheetKeepsItsCaret() {
        let state = makeState()
        let document = DocumentID()
        state.snapshot = WriterSessionState.Snapshot(
            documentID: document, selection: .inbox, caretLocation: 12, keyboardVisible: true)

        state.recordOpenDocument(document)
        XCTAssertEqual(state.snapshot.caretLocation, 12)
        XCTAssertTrue(state.snapshot.keyboardVisible)
    }

    /// A closing editor reports its last caret after the sheet that replaced
    /// it was recorded; that report must not land on the new sheet.
    func testACaretReportedForAnotherSheetIsDropped() {
        let state = makeState()
        let open = DocumentID()
        state.recordOpenDocument(open)

        state.recordEditingState(EditorEditingState(caretLocation: 99, isKeyboardVisible: true), for: DocumentID())
        XCTAssertNil(state.snapshot.caretLocation)

        state.recordEditingState(EditorEditingState(caretLocation: 7, isKeyboardVisible: true), for: open)
        XCTAssertEqual(state.snapshot.caretLocation, 7)
        XCTAssertTrue(state.snapshot.keyboardVisible)
    }

    func testClearingLeavesNothingToRestore() {
        let state = makeState()
        state.snapshot = WriterSessionState.Snapshot(
            documentID: DocumentID(), selection: .trash, caretLocation: 3, keyboardVisible: true)
        state.clear()
        XCTAssertFalse(state.hasSnapshot)
        XCTAssertEqual(state.snapshot, WriterSessionState.Snapshot())
    }
}
