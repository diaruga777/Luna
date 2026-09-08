//
//  WriterPasteTests.swift
//  LunaWriterTests
//

import XCTest
@testable import LunaWriterEditor
import LunaWriterModels

private final class FakePasteboard: PasteboardReading {
    var pastedString: String?
    var hasStrings: Bool = false
}

private final class RecordingActionDelegate: WriterTextViewActionDelegate {
    var inserted: [(text: String, source: AuthorshipSpan.Source, range: NSRange)] = []
    var markedOwn: [NSRange] = []
    var notedAt: [NSRange] = []
    var writerTextViewAIAssistantIsAvailable = false
    var continuedWriting = 0
    var rewroteSelection = 0

    func writerTextView(_ textView: WriterTextView, didInsert text: String, as source: AuthorshipSpan.Source, in range: NSRange) {
        inserted.append((text, source, range))
    }
    func writerTextView(_ textView: WriterTextView, markAsOwn range: NSRange) { markedOwn.append(range) }
    func writerTextView(_ textView: WriterTextView, addNoteAt range: NSRange) { notedAt.append(range) }
    func writerTextViewContinueWriting(_ textView: WriterTextView) { continuedWriting += 1 }
    func writerTextViewRewriteSelection(_ textView: WriterTextView) { rewroteSelection += 1 }
}

private final class FakeAuthorshipDataSource: WriterTextViewDataSource {
    var documentLength: Int = 0
    var touchesForeign = false

    func writerTextView(_ textView: WriterTextView, selectionTouchesForeignAuthorship range: NSRange) -> Bool {
        touchesForeign
    }
}

/// `PasteInterceptor.hasText` and the menu it drives must never read the
/// pasteboard's content — only whether it has strings — and a paste that
/// resolves to nothing must never fall through to `super.paste`.
final class WriterPasteTests: XCTestCase {

    private func makeTextView(pasteboard: FakePasteboard) -> WriterTextView {
        let textView = WriterTextView()
        textView.pasteboard = pasteboard
        return textView
    }

    func testHasTextFollowsHasStringsNotTheContent() {
        let pasteboard = FakePasteboard()
        let interceptor = PasteInterceptor(pasteboard: pasteboard)

        pasteboard.hasStrings = true
        pasteboard.pastedString = nil
        XCTAssertTrue(interceptor.hasText)

        pasteboard.hasStrings = false
        pasteboard.pastedString = "still here, but hasStrings says no"
        XCTAssertFalse(interceptor.hasText)
    }

    func testPastedAsAITextCarriesTheAISource() {
        let pasteboard = FakePasteboard()
        pasteboard.pastedString = "borrowed words"
        let interceptor = PasteInterceptor(pasteboard: pasteboard)
        let pasted = interceptor.pastedAsAIText()
        XCTAssertEqual(pasted?.text, "borrowed words")
        if case .ai = pasted?.source {} else { XCTFail("expected .ai source") }
    }

    func testPlainPasteInsertsWithThePastedSource() {
        let pasteboard = FakePasteboard()
        pasteboard.pastedString = "hello"
        let textView = makeTextView(pasteboard: pasteboard)
        let delegate = RecordingActionDelegate()
        textView.actionDelegate = delegate

        textView.paste(nil)

        XCTAssertEqual(delegate.inserted.count, 1)
        XCTAssertEqual(delegate.inserted.first?.text, "hello")
        XCTAssertEqual(delegate.inserted.first?.source, .pasted)
    }

    func testPasteWithNothingUsableInsertsNothing() {
        let pasteboard = FakePasteboard()
        pasteboard.pastedString = nil
        pasteboard.hasStrings = false
        let textView = makeTextView(pasteboard: pasteboard)
        let delegate = RecordingActionDelegate()
        textView.actionDelegate = delegate

        textView.paste(nil)

        XCTAssertTrue(delegate.inserted.isEmpty)
        XCTAssertEqual(textView.text, "")
    }

    func testMenuBuildingNeverReadsThePasteboardsPastedStringGetter() {
        final class SpyingPasteboard: PasteboardReading {
            var readCount = 0
            var pastedString: String? {
                readCount += 1
                return "would trigger the system prompt"
            }
            var hasStrings: Bool = true
        }
        let spy = SpyingPasteboard()
        let textView = WriterTextView()
        textView.pasteboard = spy

        _ = textView.writerMenuElements(for: NSRange(location: 0, length: 0))
        _ = textView.canPerformAction(#selector(WriterTextView.pasteAsAIText(_:)), withSender: nil)

        XCTAssertEqual(spy.readCount, 0)
    }

    // MARK: - Authorship data source

    func testTextLayoutManagerSurvivesTheAuthorshipDataSourcePath() {
        let textView = WriterTextView()
        let dataSource = FakeAuthorshipDataSource()
        dataSource.documentLength = 40
        dataSource.touchesForeign = true
        textView.authorshipDataSource = dataSource

        let elements = textView.writerMenuElements(for: NSRange(location: 0, length: 5))

        XCTAssertFalse(elements.isEmpty)
        XCTAssertNotNil(textView.textLayoutManager, "the view must stay on TextKit 2")
    }
}
