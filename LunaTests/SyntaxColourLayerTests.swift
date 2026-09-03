//
//  SyntaxColourLayerTests.swift
//  LunaTests
//

import XCTest
@testable import LunaWriterEditor
import LunaWriterText

/// Tags every paragraph as one noun, and counts how often it was asked.
private final class CountingTagger: ParagraphTagging {
    private(set) var callCount = 0
    func tags(ofParagraph body: String) -> [POSSpan] {
        callCount += 1
        guard !body.isEmpty else { return [] }
        return [POSSpan(range: NSRange(location: 0, length: body.count), pos: .noun)]
    }
}

/// Fulfills an expectation the moment a tagging answer actually lands,
/// rather than guessing how long the async round trip takes.
private final class RecordingInvalidator: LayerInvalidating {
    var expectation: XCTestExpectation?
    func invalidate(_ range: NSRange?) {
        expectation?.fulfill()
    }
}

/// The syntax layer's cache is keyed by a paragraph's own text, and its
/// requests never repeat for content already known or already asked for —
/// the fix for colours that "never land" under continuous typing.
final class SyntaxColourLayerTests: XCTestCase {

    private func makeService(tagger: CountingTagger) -> POSTaggingService {
        POSTaggingService(tagger: tagger, workQueue: .main, deliveryQueue: .main)
    }

    private func waitForAnswer(_ invalidator: RecordingInvalidator) {
        let expectation = expectation(description: "tags landed")
        invalidator.expectation = expectation
        wait(for: [expectation], timeout: 2)
        // Every later invalidate() call (a plain repaint, unrelated to what
        // this wait was for) must not re-fulfill an expectation already met.
        invalidator.expectation = nil
    }

    func testContributionsAreEmptyUntilTheAnswerArrives() {
        let tagger = CountingTagger()
        let storage = MarkdownTextStorage(text: "alpha bravo\n")
        let layer = SyntaxColourLayer(service: makeService(tagger: tagger), storage: storage)

        // No request issued yet, so nothing to contribute.
        let before = layer.contributions(in: NSRange(location: 0, length: storage.length), text: storage.nsText)
        XCTAssertTrue(before.isEmpty)
    }

    func testInvalidateTagsIssuesARequestAndContributionsSeeTheAnswer() {
        let tagger = CountingTagger()
        let storage = MarkdownTextStorage(text: "alpha bravo\n")
        let layer = SyntaxColourLayer(service: makeService(tagger: tagger), storage: storage)
        let invalidator = RecordingInvalidator()
        layer.invalidator = invalidator

        layer.invalidateTags(in: NSRange(location: 0, length: storage.length))
        waitForAnswer(invalidator)

        let after = layer.contributions(in: NSRange(location: 0, length: storage.length), text: storage.nsText)
        XCTAssertFalse(after.isEmpty)
        XCTAssertEqual(tagger.callCount, 1)
    }

    func testTheSameParagraphIsNeverRequestedTwiceWhileItsAnswerIsPending() {
        let tagger = CountingTagger()
        let storage = MarkdownTextStorage(text: "alpha bravo\n")
        let layer = SyntaxColourLayer(service: makeService(tagger: tagger), storage: storage)
        let invalidator = RecordingInvalidator()
        layer.invalidator = invalidator

        // Simulates several render passes over the same, still-untagged
        // paragraph before its one in-flight request has answered.
        layer.invalidateTags(in: NSRange(location: 0, length: storage.length))
        layer.invalidateTags(in: NSRange(location: 0, length: storage.length))
        layer.invalidateTags(in: NSRange(location: 0, length: storage.length))
        waitForAnswer(invalidator)

        XCTAssertEqual(tagger.callCount, 1)
    }

    func testTagsSurviveAnEarlierEditShiftingThisParagraphsOffset() {
        let tagger = CountingTagger()
        let storage = MarkdownTextStorage(text: "plain\nsecond paragraph\n")
        let layer = SyntaxColourLayer(service: makeService(tagger: tagger), storage: storage)
        let invalidator = RecordingInvalidator()
        layer.invalidator = invalidator

        let secondParagraph = storage.nsText.range(of: "second paragraph\n")
        layer.invalidateTags(in: secondParagraph)
        waitForAnswer(invalidator)
        XCTAssertEqual(tagger.callCount, 1)

        // An edit earlier in the document shifts the second paragraph's
        // offset without touching its own text.
        storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "PREFIX ")
        let shiftedParagraph = storage.nsText.range(of: "second paragraph\n")
        XCTAssertEqual(shiftedParagraph.location, secondParagraph.location + 7)
        layer.invalidateTags(in: shiftedParagraph)

        // The content is unchanged, so this must resolve from the layer's
        // own content-keyed cache without a second tagger call.
        XCTAssertEqual(tagger.callCount, 1)
        let contributions = layer.contributions(
            in: NSRange(location: 0, length: storage.length), text: storage.nsText)
        XCTAssertFalse(contributions.isEmpty)
    }

    func testDisablingCancelsAndReenablingAsksAgain() {
        let tagger = CountingTagger()
        let storage = MarkdownTextStorage(text: "alpha bravo\n")
        let layer = SyntaxColourLayer(service: makeService(tagger: tagger), storage: storage)
        let invalidator = RecordingInvalidator()
        layer.invalidator = invalidator

        layer.invalidateTags(in: NSRange(location: 0, length: storage.length))
        waitForAnswer(invalidator)
        XCTAssertEqual(tagger.callCount, 1)

        layer.isEnabled = false
        XCTAssertTrue(layer.contributions(
            in: NSRange(location: 0, length: storage.length), text: storage.nsText).isEmpty)

        // Re-enabling resolves synchronously: the service's own cache still
        // knows this exact paragraph body from before, so no second tagger
        // call — and no second async round trip — is needed.
        layer.isEnabled = true
        XCTAssertFalse(layer.contributions(
            in: NSRange(location: 0, length: storage.length), text: storage.nsText).isEmpty)
        XCTAssertEqual(tagger.callCount, 1)
    }
}
