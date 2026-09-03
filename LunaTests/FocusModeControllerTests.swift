//
//  FocusModeControllerTests.swift
//  LunaTests
//

import XCTest
import UIKit
@testable import LunaWriterEditor
import LunaWriterStorage

final class FocusModeControllerTests: XCTestCase {

    private let text = "First sentence here. Second sentence here.\n\nA second paragraph." as NSString

    private func makeController(_ mode: FocusMode, idleTimeout: TimeInterval = 60) -> FocusModeController {
        let controller = FocusModeController(mode: mode, idleTimeout: idleTimeout)
        controller.isComposing = true
        return controller
    }

    func testSentenceModeLightsTheSentenceTheCaretIsIn() throws {
        let controller = makeController(.sentence)
        controller.selectionChanged(to: NSRange(location: 25, length: 0), in: text)
        let range = try XCTUnwrap(controller.focusRange)
        XCTAssertEqual(text.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines), "Second sentence here.")
    }

    func testTheLitSentenceFollowsTheCaretToAnother() throws {
        let controller = makeController(.sentence)
        controller.selectionChanged(to: NSRange(location: 25, length: 0), in: text)
        let second = controller.focusRange
        controller.selectionChanged(to: NSRange(location: 3, length: 0), in: text)
        let first = try XCTUnwrap(controller.focusRange)
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(text.substring(with: first).trimmingCharacters(in: .whitespacesAndNewlines), "First sentence here.")
    }

    func testParagraphModeLightsTheWholeParagraph() throws {
        let controller = makeController(.paragraph)
        controller.selectionChanged(to: NSRange(location: 25, length: 0), in: text)
        let range = try XCTUnwrap(controller.focusRange)
        XCTAssertTrue(text.substring(with: range).hasPrefix("First sentence here."))
        XCTAssertTrue(text.substring(with: range).contains("Second sentence here."))
        XCTAssertFalse(text.substring(with: range).contains("A second paragraph."))
    }

    func testOffModeDimsNothing() throws {
        let controller = makeController(.off)
        controller.selectionChanged(to: NSRange(location: 25, length: 0), in: text)
        XCTAssertNil(controller.focusRange)
    }

    func testTurningFocusOffClearsTheLitRange() throws {
        let controller = makeController(.sentence)
        controller.selectionChanged(to: NSRange(location: 25, length: 0), in: text)
        XCTAssertNotNil(controller.focusRange)
        controller.mode = .off
        XCTAssertNil(controller.focusRange)
    }

    func testTheIdleTimeoutClearsTheDimWhenTheKeyboardIsDown() throws {
        let controller = FocusModeController(mode: .sentence, idleTimeout: 0.05)
        controller.isComposing = false
        controller.selectionChanged(to: NSRange(location: 25, length: 0), in: text)
        XCTAssertNotNil(controller.focusRange)

        let deadline = Date().addingTimeInterval(3)
        while controller.focusRange != nil, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertNil(controller.focusRange, "an idle page stops dimming")
    }

    func testTheDimStandsWhileTheKeyboardIsUp() throws {
        let controller = FocusModeController(mode: .sentence, idleTimeout: 0.05)
        controller.isComposing = true
        controller.selectionChanged(to: NSRange(location: 25, length: 0), in: text)
        let deadline = Date().addingTimeInterval(0.3)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertNotNil(controller.focusRange, "the writer is still typing")
    }

    func testTypewriterScrollIsRequestedOnlyWhenItIsOn() throws {
        final class Recorder: FocusModeControllerDelegate {
            var scrolls = 0
            var ranges: [NSRange?] = []
            func focusModeController(_ controller: FocusModeController, didChangeFocusRange range: NSRange?) {
                ranges.append(range)
            }
            func focusModeControllerRequestsTypewriterScroll(_ controller: FocusModeController) {
                scrolls += 1
            }
        }
        let recorder = Recorder()
        let controller = makeController(.sentence)
        controller.delegate = recorder
        controller.selectionChanged(to: NSRange(location: 3, length: 0), in: text)
        XCTAssertEqual(recorder.scrolls, 0)
        controller.typewriterScrolling = true
        controller.selectionChanged(to: NSRange(location: 25, length: 0), in: text)
        XCTAssertEqual(recorder.scrolls, 1)
        XCTAssertEqual(recorder.ranges.count, 2)
    }

    func testTypewriterOffsetPutsTheCaretAtTheTypewriterLine() throws {
        let offset = TypewriterScroller.verticalOffset(
            caret: CGRect(x: 0, y: 1000, width: 2, height: 20),
            visibleHeight: 800, topInset: 0, contentHeight: 4000, bottomInset: 400)
        XCTAssertEqual(offset, 1010 - 800 * EditorMetrics.typewriterFraction, accuracy: 0.5)
    }

    func testTypewriterOffsetNeverScrollsAboveTheDocument() throws {
        let offset = TypewriterScroller.verticalOffset(
            caret: CGRect(x: 0, y: 10, width: 2, height: 20),
            visibleHeight: 800, topInset: 0, contentHeight: 4000, bottomInset: 400)
        XCTAssertEqual(offset, 0, accuracy: 0.001)
    }

    /// A caret at the very end of the document, right after a Return, sits
    /// in a new, empty final paragraph — not the last character of the one
    /// before it.
    func testFocusAtTheEndOfTheDocumentLightsTheNewEmptyParagraph() throws {
        let body = "First paragraph.\n" as NSString
        let controller = makeController(.paragraph)
        controller.selectionChanged(to: NSRange(location: body.length, length: 0), in: body)
        let range = try XCTUnwrap(controller.focusRange)
        XCTAssertEqual(range.location, body.length, "the caret is in a new empty paragraph, not the previous one")
    }
}
