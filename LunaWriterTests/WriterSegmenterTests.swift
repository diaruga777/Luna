//
//  WriterSegmenterTests.swift
//  LunaWriterTests
//

import XCTest
@testable import LunaWriterText

/// Pins the sentence and word units the writing surface counts, focuses and
/// colours. The abbreviation guard is the part that is ours: `NLTokenizer`
/// breaks a sentence at "Fig." or at an initial, and read-along would then
/// light half a sentence.
final class WriterSegmenterTests: XCTestCase {

    private let segmenter = SentenceSegmenter()
    private let words = WordSegmenter()

    private func sentences(_ source: String) -> [String] {
        let text = source as NSString
        return segmenter.sentences(in: NSRange(location: 0, length: text.length), of: text)
            .map { text.substring(with: $0).trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    // MARK: - Sentences

    func testSentencesSplitAtRealBoundaries() {
        XCTAssertEqual(sentences("One. Two! Three? Four"), ["One.", "Two!", "Three?", "Four"])
    }

    func testAbbreviationDoesNotEndASentence() {
        XCTAssertEqual(sentences("See Fig. Two for the detail."), ["See Fig. Two for the detail."])
        XCTAssertEqual(sentences("Read ch. Four now."), ["Read ch. Four now."])
        XCTAssertEqual(sentences("Meet at St. Mary and leave."), ["Meet at St. Mary and leave."])
        XCTAssertEqual(sentences("The report from Acme Inc. Shows a loss."),
                       ["The report from Acme Inc. Shows a loss."])
    }

    func testInitialDoesNotEndASentence() {
        XCTAssertEqual(sentences("Send it to J. Random Hacker today. Then rest."),
                       ["Send it to J. Random Hacker today.", "Then rest."])
    }

    func testSentenceRangesAreOrderedAndInsideTheParagraph() {
        let source = "First one. Second one. Third one."
        let text = source as NSString
        let ranges = segmenter.sentences(in: NSRange(location: 0, length: text.length), of: text)
        XCTAssertEqual(ranges.count, 3)
        var previousEnd = 0
        for range in ranges {
            XCTAssertGreaterThanOrEqual(range.location, previousEnd)
            XCTAssertLessThanOrEqual(NSMaxRange(range), text.length)
            previousEnd = NSMaxRange(range)
        }
    }

    func testSentenceRangesAreDocumentOffsetsNotParagraphOffsets() {
        let source = "Alpha here. Beta here.\n\nAlpha here. Beta here.\n"
        let text = source as NSString
        let second = NSRange(location: 24, length: 22)
        let ranges = segmenter.sentences(in: second, of: text)
        XCTAssertEqual(ranges.map { text.substring(with: $0).trimmingCharacters(in: .whitespaces) },
                       ["Alpha here.", "Beta here."])
        XCTAssertGreaterThanOrEqual(ranges[0].location, second.location)
    }

    func testSentenceContainingAnOffsetIsTheOneTheCaretIsIn() {
        let source = "First one. Second one. Third one."
        let text = source as NSString
        let whole = NSRange(location: 0, length: text.length)
        let middle = segmenter.sentenceRange(containing: 14, in: whole, of: text)
        XCTAssertEqual(middle.map { text.substring(with: $0).trimmingCharacters(in: .whitespaces) }, "Second one.")
        let past = segmenter.sentenceRange(containing: text.length, in: whole, of: text)
        XCTAssertEqual(past.map { text.substring(with: $0).trimmingCharacters(in: .whitespaces) }, "Third one.")
        XCTAssertNil(segmenter.sentenceRange(containing: 0, in: NSRange(location: 0, length: 0), of: text))
    }

    func testASecondReadOfTheSameParagraphSkipsTheRealTokenizer() {
        let source = "First one. Second one."
        let text = source as NSString
        let whole = NSRange(location: 0, length: text.length)
        let fresh = SentenceSegmenter()
        let before = SentenceSegmenter.tokenizeCallCountForTesting
        _ = fresh.sentences(in: whole, of: text)
        XCTAssertEqual(SentenceSegmenter.tokenizeCallCountForTesting, before + 1)
        _ = fresh.sentences(in: whole, of: text)
        XCTAssertEqual(SentenceSegmenter.tokenizeCallCountForTesting, before + 1, "a cache hit must not re-tokenize")
    }

    func testARevisionKeyedReadHitsWithoutBridgingTheParagraphToAString() {
        let source = "First one. Second one."
        let text = source as NSString
        let whole = NSRange(location: 0, length: text.length)
        let fresh = SentenceSegmenter()
        let before = SentenceSegmenter.tokenizeCallCountForTesting
        _ = fresh.sentences(in: whole, of: text, revision: 1)
        XCTAssertEqual(SentenceSegmenter.tokenizeCallCountForTesting, before + 1)
        _ = fresh.sentences(in: whole, of: text, revision: 1)
        XCTAssertEqual(SentenceSegmenter.tokenizeCallCountForTesting, before + 1)
        // A new revision at the same range is a real miss.
        _ = fresh.sentences(in: whole, of: text, revision: 2)
        XCTAssertEqual(SentenceSegmenter.tokenizeCallCountForTesting, before + 2)
    }

    // MARK: - Words

    func testWordsSkipPunctuationAndKeepContractions() {
        let source = "Don't stop, really!"
        let text = source as NSString
        let found = words.words(in: NSRange(location: 0, length: text.length), of: text)
            .map { text.substring(with: $0) }
        XCTAssertEqual(found, ["Don't", "stop", "really"])
    }

    func testWordContainingAnOffsetIsNilOnWhitespace() {
        let source = "alpha beta"
        let text = source as NSString
        let whole = NSRange(location: 0, length: text.length)
        XCTAssertEqual(words.wordRange(containing: 2, in: whole, of: text), NSRange(location: 0, length: 5))
        XCTAssertNil(words.wordRange(containing: 5, in: whole, of: text))
    }

    // MARK: - Part of speech

    func testTaggerNamesWordClassesWhereTheLanguageModelExists() {
        let source = "The quick fox jumps over lazy dogs and she waits"
        let spans = PartOfSpeechTagger().tags(ofParagraph: source)
        guard PartOfSpeechTagger.supportsTagging(source) else {
            // No lexical classes here, so colouring stays off rather than
            // painting every word "other". The simulator is such a device.
            XCTAssertTrue(spans.isEmpty)
            return
        }
        let text = source as NSString
        var byWord: [String: POSClass] = [:]
        for span in spans { byWord[text.substring(with: span.range)] = span.pos }
        XCTAssertEqual(byWord["The"], .determiner)
        XCTAssertEqual(byWord["quick"], .adjective)
        XCTAssertEqual(byWord["fox"], .noun)
        XCTAssertEqual(byWord["jumps"], .verb)
        XCTAssertEqual(byWord["over"], .preposition)
        XCTAssertEqual(byWord["and"], .conjunction)
        XCTAssertEqual(byWord["she"], .pronoun)
    }

    func testTaggerRangesStartAtZeroForTheParagraphItWasGiven() {
        let source = "The quick fox jumps"
        let spans = PartOfSpeechTagger().tags(ofParagraph: source)
        guard PartOfSpeechTagger.supportsTagging(source) else {
            XCTAssertTrue(spans.isEmpty)
            return
        }
        let text = source as NSString
        XCTAssertEqual(spans.first.map { text.substring(with: $0.range) }, "The")
        for span in spans {
            XCTAssertGreaterThanOrEqual(span.range.location, 0)
            XCTAssertLessThanOrEqual(NSMaxRange(span.range), text.length)
        }
    }

    // MARK: - Tagging service

    private final class TaggingSpy: POSTaggingObserving {
        var spans: [POSSpan] = []
        var ranges: [NSRange] = []
        var revisions: [Int] = []
        func posTagging(_ service: POSTaggingService, didTag spans: [POSSpan], forParagraphIn range: NSRange, revision: Int) {
            self.spans = spans
            ranges.append(range)
            revisions.append(revision)
        }
    }

    /// Tags the first two words of any paragraph, and counts its calls, so a
    /// test can tell a real second pass from a cache hit.
    private final class CountingTagger: ParagraphTagging {
        private(set) var calls = 0
        func tags(ofParagraph body: String) -> [POSSpan] {
            calls += 1
            let text = body as NSString
            var out: [POSSpan] = []
            var location = 0
            while out.count < 2, location < text.length {
                let word = text.rangeOfCharacter(from: .whitespaces, options: [], range: NSRange(location: location, length: text.length - location))
                let end = word.location == NSNotFound ? text.length : word.location
                if end > location { out.append(POSSpan(range: NSRange(location: location, length: end - location), pos: .noun)) }
                location = end + 1
            }
            return out
        }
    }

    /// Lets the work queue run, then waits for anything it sent to main.
    private func drain(_ queue: DispatchQueue) {
        queue.resume()
        queue.sync {}
        let settled = expectation(description: "delivery settled")
        DispatchQueue.main.async { settled.fulfill() }
        wait(for: [settled], timeout: 5)
    }

    func testServiceDeliversTagsWithDocumentOffsetsAndTheCallersRevision() {
        let text = "skip. alpha beta gamma" as NSString
        let paragraph = NSRange(location: 6, length: text.length - 6)
        let queue = DispatchQueue(label: "writer.pos.test.deliver")
        queue.suspend()
        let tagger = CountingTagger()
        let service = POSTaggingService(tagger: tagger, workQueue: queue)
        let spy = TaggingSpy()
        service.observer = spy

        XCTAssertNil(service.cachedTags(forParagraphIn: paragraph, of: text))
        service.requestTags(forParagraphIn: paragraph, of: text, revision: 7)
        drain(queue)

        XCTAssertEqual(spy.revisions, [7])
        XCTAssertEqual(spy.ranges, [paragraph])
        XCTAssertEqual(spy.spans.map { text.substring(with: $0.range) }, ["alpha", "beta"])
        XCTAssertEqual(service.cachedTags(forParagraphIn: paragraph, of: text)?.map { $0.range }, spy.spans.map { $0.range })
        XCTAssertEqual(tagger.calls, 1)
    }

    func testCachedParagraphIsNotTaggedAgain() {
        let text = "alpha beta gamma" as NSString
        let first = NSRange(location: 0, length: text.length)
        let queue = DispatchQueue(label: "writer.pos.test.cache")
        queue.suspend()
        let tagger = CountingTagger()
        let service = POSTaggingService(tagger: tagger, workQueue: queue)
        let spy = TaggingSpy()
        service.observer = spy

        service.requestTags(forParagraphIn: first, of: text, revision: 1)
        drain(queue)
        queue.suspend()
        service.requestTags(forParagraphIn: first, of: text, revision: 2)
        drain(queue)

        XCTAssertEqual(tagger.calls, 1)
        XCTAssertEqual(spy.revisions, [1, 2])
    }

    func testTheSameParagraphAtAnotherOffsetReusesTheAnswerAndMovesIt() {
        let text = "alpha beta\n\nalpha beta" as NSString
        let first = NSRange(location: 0, length: 10)
        let second = NSRange(location: 12, length: 10)
        let queue = DispatchQueue(label: "writer.pos.test.shift")
        queue.suspend()
        let tagger = CountingTagger()
        let service = POSTaggingService(tagger: tagger, workQueue: queue)

        service.requestTags(forParagraphIn: first, of: text, revision: 1)
        drain(queue)

        XCTAssertEqual(tagger.calls, 1)
        XCTAssertEqual(service.cachedTags(forParagraphIn: second, of: text)?.map { $0.range },
                       [NSRange(location: 12, length: 5), NSRange(location: 18, length: 4)])
    }

    func testCancelledParagraphIsNeverAnswered() {
        let text = "alpha beta gamma" as NSString
        let paragraph = NSRange(location: 0, length: text.length)
        let queue = DispatchQueue(label: "writer.pos.test.cancel")
        queue.suspend()
        let tagger = CountingTagger()
        let service = POSTaggingService(tagger: tagger, workQueue: queue)
        let spy = TaggingSpy()
        service.observer = spy

        service.requestTags(forParagraphIn: paragraph, of: text, revision: 1)
        service.cancelParagraph(at: paragraph.location)
        drain(queue)

        XCTAssertTrue(spy.revisions.isEmpty)
        XCTAssertEqual(tagger.calls, 0)
    }

    func testSecondRequestForOneParagraphReplacesTheFirst() {
        let text = "alpha beta gamma" as NSString
        let paragraph = NSRange(location: 0, length: text.length)
        let longer = NSRange(location: 0, length: text.length - 6)
        let queue = DispatchQueue(label: "writer.pos.test.replace")
        queue.suspend()
        let service = POSTaggingService(tagger: CountingTagger(), workQueue: queue)
        let spy = TaggingSpy()
        service.observer = spy

        service.requestTags(forParagraphIn: paragraph, of: text, revision: 1)
        service.requestTags(forParagraphIn: longer, of: text, revision: 2)
        drain(queue)

        XCTAssertEqual(spy.revisions, [2])
    }
}
