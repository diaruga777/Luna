//
//  StreamingTextInserterTests.swift
//  LunaTests
//

import XCTest
@testable import LunaWriterEditor
import LunaWriterModels

private final class RecordingDelegate: StreamingTextInserterDelegate {
    var inserted: [(range: NSRange, source: AuthorshipSpan.Source)] = []
    var finishes = 0

    func streamingTextInserter(_ inserter: StreamingTextInserter, didInsert range: NSRange, as source: AuthorshipSpan.Source) {
        inserted.append((range, source))
    }
    func streamingTextInserterDidFinish(_ inserter: StreamingTextInserter) {
        finishes += 1
    }
}

final class StreamingTextInserterTests: XCTestCase {

    private func makeTextView() -> WriterTextView {
        let storage = MarkdownTextStorage(text: "")
        return WriterTextView(metrics: EditorMetrics(), textStorage: storage)
    }

    private func waitUntil(
        _ condition: () -> Bool, timeout: TimeInterval = 2,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(condition(), "condition never held", file: file, line: line)
    }

    func testAChunkLargerThanTheTextInsertsItAllAtOnce() {
        let textView = makeTextView()
        let inserter = StreamingTextInserter(textView: textView, chunk: 100, interval: 0.05)
        let delegate = RecordingDelegate()
        inserter.delegate = delegate

        inserter.insert("Hello there", as: .ai(model: "test"), at: 0)

        XCTAssertEqual(textView.text, "Hello there")
        waitUntil { delegate.finishes == 1 }
        XCTAssertEqual(delegate.inserted.count, 1)
        XCTAssertEqual(delegate.inserted.first?.range, NSRange(location: 0, length: 11))
        if case .ai(let model) = delegate.inserted.first?.source {
            XCTAssertEqual(model, "test")
        } else {
            XCTFail("expected .ai source")
        }
    }

    func testSeveralChunksReportOneInsertionCoveringAllOfThem() {
        let textView = makeTextView()
        let inserter = StreamingTextInserter(textView: textView, chunk: 1, interval: 0.01)
        let delegate = RecordingDelegate()
        inserter.delegate = delegate

        inserter.insert("abcd", as: .author, at: 0)
        waitUntil { delegate.finishes == 1 }

        XCTAssertEqual(textView.text, "abcd")
        XCTAssertEqual(delegate.inserted.count, 1, "one authorship span for the whole run, not one per chunk")
        XCTAssertEqual(delegate.inserted.first?.range, NSRange(location: 0, length: 4))
    }

    func testInsertingAtALocationTypesThereNotAtTheStartOfTheDocument() {
        let textView = makeTextView()
        textView.replaceText(in: NSRange(location: 0, length: 0), with: "before ")
        let inserter = StreamingTextInserter(textView: textView, chunk: 2, interval: 0.01)
        let delegate = RecordingDelegate()
        inserter.delegate = delegate

        inserter.insert("after", as: .author, at: 7)
        waitUntil { delegate.finishes == 1 }

        XCTAssertEqual(textView.text, "before after")
    }

    /// The stream used to insert every chunk at a hand-computed
    /// `start + inserted` offset. An edit landing between two chunks — the
    /// caret moving because of it — must not leave the next chunk pointed
    /// at a location that no longer means "right after what was typed so
    /// far".
    func testAnEditArrivingBetweenChunksIsFollowedNotOverwritten() {
        let textView = makeTextView()
        let inserter = StreamingTextInserter(textView: textView, chunk: 1, interval: 0.2)
        let delegate = RecordingDelegate()
        inserter.delegate = delegate

        inserter.insert("AB", as: .ai(model: "test"), at: 0)
        // The first chunk lands synchronously inside insert(); the second
        // is still 0.2s away on the timer.
        XCTAssertEqual(textView.text, "A")

        // Something else edits the text right where the caret now sits —
        // exactly what a fast typist or an external change would do.
        textView.replaceText(in: textView.selectedRange, with: "Z")
        XCTAssertEqual(textView.text, "AZ")

        waitUntil { delegate.finishes == 1 }

        XCTAssertEqual(textView.text, "AZB", "the second chunk followed the caret, landing after Z")
    }

    func testFinishReportsWhateverLandedSoFar() {
        let textView = makeTextView()
        let inserter = StreamingTextInserter(textView: textView, chunk: 1, interval: 10)
        let delegate = RecordingDelegate()
        inserter.delegate = delegate

        inserter.insert("abcdef", as: .author, at: 0)
        // Only the first chunk has landed; the timer will not fire again
        // inside this test's lifetime.
        XCTAssertEqual(textView.text, "a")
        inserter.finish()

        XCTAssertEqual(delegate.finishes, 1)
        XCTAssertEqual(delegate.inserted.first?.range, NSRange(location: 0, length: 1))
        XCTAssertFalse(inserter.isRunning)
    }

    func testStartingARunFinishesTheOneAlreadyGoing() {
        let textView = makeTextView()
        let inserter = StreamingTextInserter(textView: textView, chunk: 1, interval: 10)
        let delegate = RecordingDelegate()
        inserter.delegate = delegate

        inserter.insert("first", as: .author, at: 0)
        inserter.insert("second", as: .author, at: (textView.text as NSString).length)

        // The first run's single landed chunk was reported as finished
        // before the second run began.
        XCTAssertEqual(delegate.finishes, 1)
        XCTAssertEqual(delegate.inserted.first?.range, NSRange(location: 0, length: 1))
    }
}
