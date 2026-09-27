import XCTest
import UIKit
@testable import LunaWriterEditor
import LunaWriterStorage

@MainActor
final class CommandPaletteOverlayTests: XCTestCase {
    private func descendants(_ view: UIView) -> [UIView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }

    func testEmptyPaletteHasNoHeadingOrCommands() {
        let overlay = CommandPaletteOverlayView()
        overlay.update(rows: [], highlightedIndex: nil)
        XCTAssertEqual(overlay.rowCount, 0)
        XCTAssertFalse(descendants(overlay).contains { $0 is UILabel })
        XCTAssertFalse(descendants(overlay).contains { $0 is UIButton })
    }

    func testQueryGlassFollowsWrappedInputWithoutEditingTextOrTakingTouches() throws {
        let textView = WriterTextView()
        textView.frame = CGRect(x: 0, y: 0, width: 280, height: 500)
        textView.text = "Prose @a long command that wraps to the next line"
        textView.layoutIfNeeded()
        let original = textView.text
        let decoration = PaletteQueryDecoration()
        let marker = 6
        decoration.update(range: NSRange(location: marker, length: 0), in: textView)
        let empty = try XCTUnwrap(descendants(textView).first {
            $0.accessibilityIdentifier == "writer.commandPalette.queryGlass"
        })
        let start = try XCTUnwrap(textView.position(from: textView.beginningOfDocument, offset: marker))
        XCTAssertTrue(empty.frame.contains(textView.caretRect(for: start)))
        decoration.update(range: NSRange(location: marker, length: (original! as NSString).length - marker), in: textView)
        let segments = descendants(textView).filter { $0.accessibilityIdentifier == "writer.commandPalette.queryGlass" }
        XCTAssertGreaterThan(segments.count, 1)
        XCTAssertTrue(segments.allSatisfy { !$0.isUserInteractionEnabled })
        XCTAssertEqual(textView.text, original)
        decoration.update(range: nil, in: textView)
        XCTAssertFalse(descendants(textView).contains { $0.accessibilityIdentifier == "writer.commandPalette.queryGlass" })
    }

    func testOriginStaysFixedAcrossPendingSearchResultsAndWrappedCaret() {
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        let overlay = CommandPaletteOverlayView()
        container.addSubview(overlay)
        overlay.place(anchoredTo: CGRect(x: 310, y: 300, width: 2, height: 24), in: container, keyboardTop: 540)
        let origin = overlay.frame.origin
        let rows = (0..<7).map { PaletteRow(title: "Result \($0)", symbolName: "note", action: .createNote) }
        for results in [rows, [], Array(rows.prefix(2))] {
            overlay.update(rows: results, highlightedIndex: nil)
            overlay.place(anchoredTo: CGRect(x: 24, y: 330, width: 2, height: 24), in: container, keyboardTop: 540)
            XCTAssertEqual(overlay.frame.origin, origin)
            XCTAssertLessThanOrEqual(overlay.frame.maxY, 540)
        }
        overlay.resetPlacement()
        overlay.place(anchoredTo: CGRect(x: 24, y: 430, width: 2, height: 24), in: container, keyboardTop: 540)
        XCTAssertNotEqual(overlay.frame.origin, origin)
    }

    func testSymbolTilesShareARowAndKeepTheirOwnActionsAndHighlight() throws {
        let rows = [
            PaletteRow(title: "Right Arrow", symbolName: "character", action: .insertText("→"), symbolCharacter: "→"),
            PaletteRow(title: "A note", detail: "Unnecessary explanation", symbolName: "note", action: .createNote),
            PaletteRow(title: "Left Arrow", symbolName: "character", action: .insertText("←"), symbolCharacter: "←"),
        ]
        let overlay = CommandPaletteOverlayView(frame: CGRect(x: 0, y: 0, width: 360, height: 180))
        overlay.update(rows: rows, highlightedIndex: 2)
        overlay.layoutIfNeeded()
        let buttons = descendants(overlay).compactMap { $0 as? UIButton }
        let right = try XCTUnwrap(buttons.first { $0.tag == 0 })
        let left = try XCTUnwrap(buttons.first { $0.tag == 2 })
        XCTAssertTrue(left.superview === right.superview)
        XCTAssertEqual(right.configuration?.title, "→")
        XCTAssertEqual(left.configuration?.title, "←")
        XCTAssertTrue(left.accessibilityTraits.contains(.selected))
        XCTAssertFalse(right.accessibilityTraits.contains(.selected))
        XCTAssertEqual(PaletteRow.displayGroups(in: rows), [[0, 2], [1]])
        let note = try XCTUnwrap(buttons.first { $0.tag == 1 })
        XCTAssertEqual(note.configuration?.subtitle, "Unnecessary explanation")
    }

    func testWrappedQueryStaysVisibleAboveAStationaryPanel() throws {
        let storage = try makeWriterStack()
        storage.settings.paletteTrigger = .atSign
        let document = try storage.library.createDocument(in: storage.library.inboxGroupID, title: nil)
        let session = try DocumentSession(document: document, textStore: storage.textStore,
                                          marksStore: storage.library, settings: storage.settings)
        let editor = EditorViewController(session: session, environment: EditorEnvironment(
            noteIndex: storage.noteIndex, noteStore: storage.library,
            marksStore: storage.library, settings: storage.settings))
        let window = hostWriterScreen(editor)
        defer { editor.close(); window.isHidden = true }
        let textView = editor.textView
        func type(_ text: String) {
            for character in text {
                let piece = String(character)
                let range = textView.selectedRange
                guard editor.textView(textView, shouldChangeTextIn: range, replacementText: piece) else { continue }
                textView.textStorage.replaceCharacters(in: range, with: piece)
                textView.selectedRange = NSRange(location: range.location + (piece as NSString).length, length: 0)
                editor.textViewDidChange(textView)
                editor.textViewDidChangeSelection(textView)
                editor.view.layoutIfNeeded()
            }
        }
        type("Check @")
        let overlay = try XCTUnwrap(descendants(editor.view).compactMap { $0 as? CommandPaletteOverlayView }.first)
        XCTAssertFalse(overlay.isHidden)
        XCTAssertTrue(overlay.isBelowAnchor)
        let origin = overlay.frame.origin
        type("arrow with a much longer description")
        let selection = try XCTUnwrap(textView.selectedTextRange)
        let caret = editor.view.convert(textView.caretRect(for: selection.end), from: textView)
        XCTAssertEqual(overlay.frame.origin, origin)
        XCTAssertLessThanOrEqual(caret.maxY, overlay.frame.minY)
        XCTAssertFalse(overlay.isHidden)
    }

    func testShortViewportKeepsResultsAboveKeyboard() {
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 852, height: 393))
        let overlay = CommandPaletteOverlayView()
        container.addSubview(overlay)
        overlay.update(rows: (0..<7).map {
            PaletteRow(title: "Result \($0)", symbolName: "note", action: .createNote)
        }, highlightedIndex: nil)
        overlay.place(anchoredTo: CGRect(x: 30, y: 120, width: 2, height: 24), in: container, keyboardTop: 180)
        XCTAssertGreaterThanOrEqual(overlay.frame.minY, 0)
        XCTAssertLessThanOrEqual(overlay.frame.maxY, 180)
    }
}

extension CommandPaletteOverlayTests {
    func testLongNoteWrapsAndReturnSelectionHasVisibleFillAndBorder() throws {
        let note = String(repeating: "A lighthouse keeper waits for the storm to pass. ", count: 5)
        let rows = [PaletteRow(title: note, detail: "Another chapter", symbolName: "note.text", action: .createNote),
                    PaletteRow(title: "Second result", symbolName: "note.text", action: .createNote)]
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 800, height: 1000))
        let overlay = CommandPaletteOverlayView()
        container.addSubview(overlay)
        overlay.update(rows: rows, highlightedIndex: 0)
        overlay.place(anchoredTo: CGRect(x: 20, y: 60, width: 2, height: 20), in: container, keyboardTop: 900)
        overlay.layoutIfNeeded()
        let buttons = descendants(overlay).compactMap { $0 as? UIButton }
        let first = try XCTUnwrap(buttons.first { $0.tag == 0 })
        let second = try XCTUnwrap(buttons.first { $0.tag == 1 })
        XCTAssertEqual(first.titleLabel?.numberOfLines, 0)
        XCTAssertGreaterThan(first.bounds.height, CommandPaletteOverlayView.rowHeight)
        XCTAssertTrue(first.isSelected)
        XCTAssertEqual(first.configuration?.background.strokeWidth, 2)
        XCTAssertNotEqual(first.configuration?.background.backgroundColor, second.configuration?.background.backgroundColor)
        overlay.highlight(1)
        XCTAssertFalse(first.isSelected)
        XCTAssertTrue(second.isSelected)
        XCTAssertEqual(second.configuration?.background.strokeWidth, 2)
        overlay.highlight(nil)
        XCTAssertFalse(second.isSelected)
        XCTAssertEqual(second.configuration?.background.strokeWidth, 0)
    }
}
