//
//  VoiceCommandClassifierTests.swift
//  LunaWriterTests
//
//  The acceptance table from gazeread's test/classify.mjs, carried verbatim,
//  plus the empty/punctuation cases classify.mjs checks separately.
//

import XCTest
@testable import LunaWriterVoice

final class VoiceCommandClassifierTests: XCTestCase {

    private let cases: [(String, VoiceCommand)] = [
        ("expand", .expand),
        ("Elaborate.", .expand),
        ("more detail here", .expand),
        ("flesh this out", .expand),
        ("needs work", .needsWork),
        ("needs a bit of work", .needsWork),
        ("this is awkward", .needsWork),
        ("rephrase that", .needsWork),
        ("remove", .cut),
        ("cut this bit", .cut),
        ("just delete this", .cut),
        ("get rid of this", .cut),
        ("like this", .keep),
        ("good", .keep),
        ("love it", .keep),
        ("keep this", .keep),
        ("that works well", .keep),
        // ASR typos
        ("ellaborate", .expand),
        ("rephase this", .needsWork),
        ("kind of clunky", .needsWork),
        // free comments
        ("I wonder whether the banker is meant to be sympathetic here",
         .comment("I wonder whether the banker is meant to be sympathetic here")),
        ("this is a good example of what I mean about the pacing in the middle chapters",
         .comment("this is a good example of what I mean about the pacing in the middle chapters")),
        ("the lawyer's motivation is never really explained",
         .comment("the lawyer's motivation is never really explained")),
        ("check the date of the bet against chapter two",
         .comment("check the date of the bet against chapter two")),
    ]

    func testAcceptanceTable() {
        for (transcript, expected) in cases {
            XCTAssertEqual(VoiceCommandClassifier.classify(transcript), expected,
                            "classify(\(transcript.debugDescription)) should be \(expected)")
        }
    }

    func testEmptyTranscriptIsNil() {
        XCTAssertNil(VoiceCommandClassifier.classify(""))
    }

    func testPunctuationOnlyTranscriptIsNil() {
        XCTAssertNil(VoiceCommandClassifier.classify("..."))
    }

    func testWhitespaceOnlyTranscriptIsNil() {
        XCTAssertNil(VoiceCommandClassifier.classify("   "))
    }

    func testLongUtteranceContainingACommandWordIsStillAComment() {
        // "good" alone is .keep, but at this length neither the single-word
        // nor the phrase rule fires, so it falls through to a free comment —
        // gazeread's own worked example for the length gate.
        let transcript = "this is a good example of what I mean about the pacing in the middle chapters"
        XCTAssertEqual(VoiceCommandClassifier.classify(transcript), .comment(transcript))
    }
}
