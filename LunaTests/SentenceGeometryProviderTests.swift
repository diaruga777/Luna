//
//  SentenceGeometryProviderTests.swift
//  LunaTests
//

import XCTest
import UIKit
@testable import LunaWriterEditor

final class SentenceGeometryProviderTests: XCTestCase {

    private var textView: WriterTextView!
    private var storage: MarkdownTextStorage!
    private var provider: SentenceGeometryProvider!

    private let body = """
    The quick brown fox jumps over the lazy dog. A second sentence follows it here.

    A third sentence sits in its own paragraph and runs on long enough that the \
    layout must break it across more than one line of the column.
    """

    override func setUp() {
        super.setUp()
        storage = MarkdownTextStorage(text: body)
        textView = WriterTextView(metrics: EditorMetrics(), textStorage: storage)
        textView.frame = CGRect(x: 0, y: 0, width: 375, height: 800)
        textView.layoutIfNeeded()
        provider = SentenceGeometryProvider(
            layoutManager: textView.textLayoutManager, storage: storage)
    }

    override func tearDown() {
        provider = nil
        textView = nil
        storage = nil
        super.tearDown()
    }

    private func whole() -> NSRange { NSRange(location: 0, length: storage.length) }

    func testEverySentenceGetsAtLeastOneLineRectangle() throws {
        let layouts = provider.layout(for: whole())
        XCTAssertGreaterThanOrEqual(layouts.count, 3)
        for layout in layouts {
            XCTAssertFalse(layout.lineRects.isEmpty, "sentence \(layout.index) has no line")
            for rect in layout.lineRects {
                XCTAssertGreaterThan(rect.width, 0)
                XCTAssertGreaterThan(rect.height, 0)
            }
        }
    }

    func testSentencesComeBackInDocumentOrderAndGoDownThePage() throws {
        let layouts = provider.layout(for: whole())
        var previousStart = -1
        var previousTop = -CGFloat.greatestFiniteMagnitude
        for layout in layouts {
            XCTAssertGreaterThan(layout.textRange.location, previousStart)
            previousStart = layout.textRange.location
            let top = try XCTUnwrap(layout.lineRects.first?.minY)
            XCTAssertGreaterThanOrEqual(top, previousTop)
            previousTop = top
        }
    }

    func testWordRectanglesTileTheLineTheySitOn() throws {
        let layouts = provider.layout(for: whole())
        let first = try XCTUnwrap(layouts.first)
        XCTAssertGreaterThanOrEqual(first.words.count, 8)

        let line = try XCTUnwrap(first.lineRects.first)
        let onFirstLine = first.words.filter { abs($0.rect.minY - line.minY) < 1 }
        XCTAssertGreaterThanOrEqual(onFirstLine.count, 5)

        var previousMaxX = -CGFloat.greatestFiniteMagnitude
        for word in onFirstLine {
            XCTAssertGreaterThan(word.rect.width, 0)
            XCTAssertGreaterThanOrEqual(word.rect.minX + 0.5, previousMaxX, "words overlap")
            previousMaxX = word.rect.maxX
            XCTAssertGreaterThanOrEqual(word.rect.minX + 0.5, line.minX)
            XCTAssertLessThanOrEqual(word.rect.maxX, line.maxX + 0.5)
        }
    }

    func testALongSentenceWrapsOntoSeveralLines() throws {
        let layouts = provider.layout(for: whole())
        let last = try XCTUnwrap(layouts.last)
        XCTAssertGreaterThan(last.lineRects.count, 1)
        let heights = Set(last.lineRects.map { Int($0.minY) })
        XCTAssertEqual(heights.count, last.lineRects.count, "each line sits at its own height")
    }

    func testTheNearestSentenceToAHeightIsTheOneDrawnThere() throws {
        let layouts = provider.layout(for: whole())
        let last = try XCTUnwrap(layouts.last)
        let y = try XCTUnwrap(last.lineRects.last).midY
        XCTAssertEqual(provider.nearestSentence(toY: y)?.textRange, last.textRange)

        let firstLine = try XCTUnwrap(layouts.first?.lineRects.first)
        XCTAssertEqual(
            provider.nearestSentence(toY: firstLine.midY)?.textRange, layouts.first?.textRange)
    }

    func testAskingForOneRangeAnswersOnlyTheSentencesItTouches() throws {
        let layouts = provider.layout(for: whole())
        let second = try XCTUnwrap(layouts.dropFirst().first)
        let answered = provider.layout(for: second.textRange)
        XCTAssertEqual(answered.map { $0.textRange }, [second.textRange])
    }

    func testEditingTheTextMovesTheGeometryUnderIt() throws {
        let before = try XCTUnwrap(provider.layout(for: whole()).dropFirst().first)
        storage.replaceCharacters(
            in: NSRange(location: 0, length: 0), with: "A brand new opening sentence goes here. ")
        textView.layoutIfNeeded()
        let after = try XCTUnwrap(provider.layout(for: whole()).dropFirst().first)
        XCTAssertNotEqual(after.textRange, before.textRange)
    }

    /// An edit entirely inside the third paragraph must not disturb the
    /// first two sentences' ranges: the splice only replaces the touched
    /// paragraph and shifts what comes after it.
    func testAnEditFarBelowLeavesTheEarlierSentencesRangesAlone() throws {
        let before = try XCTUnwrap(provider.layout(for: whole()).first)
        let thirdParagraph = try XCTUnwrap(provider.layout(for: whole()).last)
        storage.replaceCharacters(in: NSRange(location: thirdParagraph.textRange.location, length: 0), with: "X")
        textView.layoutIfNeeded()
        let after = try XCTUnwrap(provider.layout(for: whole()).first)
        XCTAssertEqual(after.textRange, before.textRange)
    }

    /// A width change between two `layout(for:)` calls — what
    /// `EditorViewController.relayoutIfNeeded()` triggers on rotation or a
    /// Split View resize — must move the sentence's line rectangles.
    func testAWidthChangeBetweenTwoLayoutCallsMovesTheRects() throws {
        let before = try XCTUnwrap(provider.layout(for: whole()).last?.lineRects)
        XCTAssertGreaterThan(before.count, 1, "the long sentence must already wrap at the original width")

        textView.frame = CGRect(x: 0, y: 0, width: 900, height: 800)
        textView.layoutIfNeeded()
        provider.invalidate(nil)

        let after = try XCTUnwrap(provider.layout(for: whole()).last?.lineRects)
        XCTAssertNotEqual(after, before)
    }
}
