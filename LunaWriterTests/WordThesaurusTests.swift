//
//  WordThesaurusTests.swift
//  LunaWriterTests
//

import XCTest
@testable import LunaWriterText

final class WordThesaurusTests: XCTestCase {

    func testAnInflectionOfTheWordIsNotAnotherWord() {
        XCTAssertTrue(EmbeddingThesaurus.isInflection("happier", of: "happy"))
        XCTAssertTrue(EmbeddingThesaurus.isInflection("happiest", of: "happy"))
        XCTAssertTrue(EmbeddingThesaurus.isInflection("walked", of: "walking"))
        XCTAssertTrue(EmbeddingThesaurus.isInflection("cats", of: "cat"))
        XCTAssertFalse(EmbeddingThesaurus.isInflection("glad", of: "happy"))
        XCTAssertFalse(EmbeddingThesaurus.isInflection("catalog", of: "cat"))
    }

    func testAnswersTakeTheCaseOfTheWordAsked() {
        XCTAssertEqual(EmbeddingThesaurus.matchCase(of: "Happy", to: "glad"), "Glad")
        XCTAssertEqual(EmbeddingThesaurus.matchCase(of: "HAPPY", to: "glad"), "GLAD")
        XCTAssertEqual(EmbeddingThesaurus.matchCase(of: "happy", to: "glad"), "glad")
    }

    /// The word embedding is an OS asset; where it is absent the command
    /// reports itself unavailable and there is nothing to look up.
    func testTheEmbeddingAnswersOtherWordsForACommonOne() throws {
        let thesaurus = EmbeddingThesaurus()
        try XCTSkipUnless(thesaurus.isAvailable, "no English word embedding on this device")
        let words = thesaurus.synonyms(for: "happy", limit: 5)
        XCTAssertEqual(words.count, 5, "\(words)")
        XCTAssertFalse(words.contains { $0.lowercased().hasPrefix("happ") }, "\(words)")
        XCTAssertTrue(thesaurus.synonyms(for: "two words", limit: 5).isEmpty)
        XCTAssertTrue(thesaurus.synonyms(for: "", limit: 5).isEmpty)
    }
}
