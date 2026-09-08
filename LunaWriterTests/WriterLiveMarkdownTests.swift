//
//  WriterLiveMarkdownTests.swift
//  LunaWriterTests
//

import XCTest
import UIKit
@testable import LunaWriterEditor
import LunaWriterText

/// The painted half of live Markdown: which paragraphs get a decorated
/// layout fragment, where a task item's checkbox is, and that the caret
/// still has somewhere to sit beside a collapsed marker.
final class WriterLiveMarkdownTests: XCTestCase {

    private func makeTextView(_ text: String) -> (WriterTextView, MarkdownTextStorage) {
        let storage = MarkdownTextStorage(text: text)
        let view = WriterTextView(metrics: EditorMetrics(), textStorage: storage)
        view.frame = CGRect(x: 0, y: 0, width: 375, height: 600)
        view.layoutIfNeeded()
        return (view, storage)
    }

    private func fragmentIsDecorated(_ view: WriterTextView) -> [Bool] {
        guard let manager = view.textLayoutManager else { return [] }
        var out: [Bool] = []
        manager.enumerateTextLayoutFragments(
            from: manager.documentRange.location, options: [.ensuresLayout]
        ) { fragment in
            out.append(fragment is WriterTextLayoutFragment)
            return true
        }
        return out
    }

    func testABulletLineGetsADecoratedFragmentAndAParagraphDoesNot() {
        let (view, _) = makeTextView("plain line\n- item\n")
        XCTAssertEqual(fragmentIsDecorated(view), [false, true])
    }

    func testQuotesRulesAndTasksAllGetDecoratedFragments() {
        let (view, _) = makeTextView("> quote\n- [ ] task\n---\nplain\n")
        XCTAssertEqual(fragmentIsDecorated(view), [true, true, true, false])
    }

    /// An ordered item keeps its own number, so nothing is painted for it.
    func testAnOrderedListItemGetsNoDecoratedFragment() {
        let (view, _) = makeTextView("1. one\n")
        XCTAssertEqual(fragmentIsDecorated(view), [false])
    }

    // MARK: - Decoration

    func testTheDecorationFollowsTheBlockUnderTheOffset() throws {
        let storage = MarkdownTextStorage(text: "- item\n- [ ] open\n- [x] done\n> quote\n---\nplain\n")
        let provider = WriterLayoutFragmentProvider(storage: storage, metrics: EditorMetrics())
        let text = storage.nsText
        func decoration(_ needle: String) -> WriterBlockDecoration? {
            provider.decoration(at: text.range(of: needle).location)
        }
        XCTAssertEqual(decoration("item"), .bullet)
        XCTAssertEqual(decoration("open"), .task(.unchecked))
        XCTAssertEqual(decoration("done"), .task(.checked))
        XCTAssertEqual(decoration("quote"), .quote(depth: 1))
        XCTAssertEqual(decoration("---"), .rule)
        XCTAssertNil(decoration("plain"))
    }

    /// The raw source is what the writer edits on the revealed paragraph, so
    /// the decoration comes down while the caret is there.
    func testARevealedParagraphPaintsNoDecoration() {
        let storage = MarkdownTextStorage(text: "- item\n- other\n")
        let provider = WriterLayoutFragmentProvider(storage: storage, metrics: EditorMetrics())
        XCTAssertFalse(provider.isRevealed(at: 2))
        storage.setRevealRange(NSRange(location: 2, length: 0))
        XCTAssertTrue(provider.isRevealed(at: 2))
        XCTAssertFalse(provider.isRevealed(at: 9))
    }

    // MARK: - Checkbox tap

    func testATapInTheTaskGutterHitsTheCheckboxAndOneOnTheTextDoesNot() {
        let metrics = EditorMetrics()
        let storage = MarkdownTextStorage(text: "- [ ] task\n")
        let provider = WriterLayoutFragmentProvider(storage: storage, metrics: metrics)
        let textX = metrics.listIndent
        XCTAssertTrue(provider.hitsTaskMarker(at: 3, containerX: textX - metrics.markerSlot / 2))
        XCTAssertFalse(provider.hitsTaskMarker(at: 3, containerX: textX + 40))
        XCTAssertFalse(provider.hitsTaskMarker(at: 3, containerX: 0))
    }

    func testAPlainListItemsGutterIsNotACheckbox() {
        let metrics = EditorMetrics()
        let storage = MarkdownTextStorage(text: "- item\n")
        let provider = WriterLayoutFragmentProvider(storage: storage, metrics: metrics)
        XCTAssertFalse(provider.hitsTaskMarker(
            at: 3, containerX: metrics.listIndent - metrics.markerSlot / 2))
    }

    /// While the caret is on the line the box is raw `[ ]` text, which the
    /// writer edits by typing rather than by tapping.
    func testARevealedTaskLineTakesNoCheckboxTap() {
        let metrics = EditorMetrics()
        let storage = MarkdownTextStorage(text: "- [ ] task\n")
        let provider = WriterLayoutFragmentProvider(storage: storage, metrics: metrics)
        storage.setRevealRange(NSRange(location: 3, length: 0))
        XCTAssertFalse(provider.hitsTaskMarker(
            at: 3, containerX: metrics.listIndent - metrics.markerSlot / 2))
    }

    /// The text view reports the offset to toggle, so the editor's command
    /// can run on it.
    func testTheTextViewReportsATaskGutterTap() throws {
        let (view, storage) = makeTextView("- [ ] task\n")
        let metrics = EditorMetrics()
        let gutter = CGPoint(
            x: view.textContainerInset.left + metrics.listIndent - metrics.markerSlot / 2,
            y: view.textContainerInset.top + 4)
        XCTAssertNotNil(view.taskMarkerOffset(at: gutter))
        XCTAssertNil(view.taskMarkerOffset(at: CGPoint(x: gutter.x + 120, y: gutter.y)))
        XCTAssertEqual(storage.model.blockKind(at: 0), .listItem(ordered: false, indent: 0, task: .unchecked))
    }

    // MARK: - Caret

    /// A caret at a collapsed run's boundary must still have a rectangle to
    /// draw in, inside the text column.
    func testTheCaretBesideACollapsedMarkerStaysOnScreen() throws {
        let (view, _) = makeTextView("# Title\nBody\n")
        let caret = view.caretRect(for: view.beginningOfDocument)
        XCTAssertFalse(caret.isNull)
        XCTAssertFalse(caret.origin.x.isNaN)
        XCTAssertGreaterThan(caret.height, 1)
        XCTAssertGreaterThanOrEqual(caret.origin.x, 0)
        XCTAssertLessThan(caret.maxX, view.bounds.width)
    }
}
