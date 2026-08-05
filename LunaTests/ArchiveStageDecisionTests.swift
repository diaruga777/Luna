//
//  ArchiveStageDecisionTests.swift
//  LunaTests
//

import LunaArchiveReader
import XCTest
@testable import Luna

/// Exercises `ArchiveWebReaderViewController.decideStage` — the pure stage→action
/// logic of the in-app archive.today reader. The regression of record: after the
/// homepage was submitted, a rendered snapshot whose chrome still carries the
/// `input[name=url]` box was mis-classified as the homepage and never extracted,
/// leaving the spinner up forever.
final class ArchiveStageDecisionTests: XCTestCase {

    private func decide(
        _ stage: String,
        didLeaveHomepage: Bool = false,
        isSubmittingHomepage: Bool = false,
        hasResolvedSnapshot: Bool = false,
        blockedCount: Int = 0,
        blockedLimit: Int = 3
    ) -> ArchiveWebReaderViewController.StageDecision {
        ArchiveWebReaderViewController.decideStage(
            stage,
            didLeaveHomepage: didLeaveHomepage,
            isSubmittingHomepage: isSubmittingHomepage,
            hasResolvedSnapshot: hasResolvedSnapshot,
            blockedCount: blockedCount,
            blockedLimit: blockedLimit)
    }

    private struct StageCase {
        let name: String
        let stage: String
        var didLeaveHomepage = false
        var isSubmittingHomepage = false
        var hasResolvedSnapshot = false
        var blockedCount = 0
        let expected: ArchiveWebReaderViewController.StageDecision
    }

    // MARK: - stage → action

    func testStageDecisions() {
        let cases: [StageCase] = [
            // The fixed regression: the snapshot's chrome still has the home form.
            // It is not itself a content signal; wait for the semantic content-root
            // probe instead of resubmitting or gating on text length.
            .init(name: "homepage chrome after submit does not resubmit",
                  stage: "homepage", didLeaveHomepage: true, expected: .wait),
            .init(name: "content-root after submit extracts",
                  stage: "content-root", didLeaveHomepage: true, expected: .attemptExtract),
            .init(name: "verbose request log never triggers extraction",
                  stage: "waiting", didLeaveHomepage: true, expected: .wait),

            // Homepage submit (before leaving).
            .init(name: "homepage before submit submits",
                  stage: "homepage", expected: .submitHomepage),
            .init(name: "homepage before submit with resolved snapshot loads it",
                  stage: "homepage", hasResolvedSnapshot: true, expected: .loadResolvedSnapshot),
            .init(name: "submitting homepage waits for navigation",
                  stage: "homepage", isSubmittingHomepage: true, expected: .wait),

            // Challenge.
            .init(name: "challenge waits for user", stage: "challenge", expected: .challenge),

            // "Enable JS / disable ad blocker" gate: tolerate a transient flash,
            // terminal once it persists.
            .init(name: "blocked once is a flash", stage: "blocked", blockedCount: 1, expected: .wait),
            .init(name: "blocked twice is a flash", stage: "blocked", blockedCount: 2, expected: .wait),
            .init(name: "blocked at the limit is terminal",
                  stage: "blocked", blockedCount: 3, expected: .cannotArchive),
            .init(name: "blocked past the limit is terminal",
                  stage: "blocked", blockedCount: 9, expected: .cannotArchive),

            // Errors. archive.today's "Error -32602: Invalid InterceptionId"
            // (probe → "error") is terminal — retrying/solving won't help.
            .init(name: "error is terminal", stage: "error", expected: .cannotArchive),
            .init(name: "error is terminal regardless of homepage state",
                  stage: "error", didLeaveHomepage: true, expected: .cannotArchive),
            .init(name: "malformed stage waits", stage: "unknown", expected: .wait),
        ]

        for testCase in cases {
            XCTAssertEqual(
                decide(
                    testCase.stage,
                    didLeaveHomepage: testCase.didLeaveHomepage,
                    isSubmittingHomepage: testCase.isSubmittingHomepage,
                    hasResolvedSnapshot: testCase.hasResolvedSnapshot,
                    blockedCount: testCase.blockedCount),
                testCase.expected,
                testCase.name)
        }
    }

    // MARK: - JS-required gate (pre-stage hardening)

    func testJavaScriptRequiredGate() {
        // A real, rendered article that merely mentions JavaScript must NOT be
        // treated as a gate — the gate is conditioned on a SHORT body.
        let longArticle = String(repeating: "This post is about JavaScript frameworks. ", count: 60)
        let cases: [(name: String, text: String, isGate: Bool)] = [
            ("please enable", "Please enable JavaScript to continue.", true),
            ("is required", "JavaScript is required to view this content.", true),
            ("enable JS and reload", "Enable JS and reload.", true),
            ("long article mentioning JavaScript", longArticle, false),
            ("unrelated short page", "Loading your article…", false),
        ]

        for testCase in cases {
            XCTAssertEqual(
                ArchiveWebReaderViewController.isJavaScriptRequiredGate(text: testCase.text),
                testCase.isGate,
                testCase.name)
        }
    }
}
