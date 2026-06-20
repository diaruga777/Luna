//
//  ArchiveStageDecisionTests.swift
//  ClipTests
//

import XCTest
@testable import Clip

/// Exercises `ArchiveWebReaderViewController.decideStage` — the pure stage→action
/// logic of the in-app archive.today reader. The regression of record: after the
/// homepage was submitted, a rendered snapshot whose chrome still carries the
/// `input[name=url]` box (reported as `homepage:<len>`) was mis-classified as the
/// homepage and never extracted, leaving the spinner up forever.
final class ArchiveStageDecisionTests: XCTestCase {

    private func decide(
        _ stage: String,
        didLeaveHomepage: Bool = false,
        hasResolvedSnapshot: Bool = false,
        blockedCount: Int = 0,
        blockedLimit: Int = 3
    ) -> ArchiveWebReaderViewController.StageDecision {
        ArchiveWebReaderViewController.decideStage(
            stage,
            didLeaveHomepage: didLeaveHomepage,
            hasResolvedSnapshot: hasResolvedSnapshot,
            blockedCount: blockedCount,
            blockedLimit: blockedLimit)
    }

    // MARK: - The fixed regression

    func testHomepageBoxAfterSubmitWithRealTextExtracts() {
        // The /wip/ shell has rendered the article, but archive.today's chrome still
        // includes the submit box → "homepage:<big>". Since we already submitted,
        // this must NOT loop back to the homepage; it must attempt extraction.
        XCTAssertEqual(
            decide("homepage:42000", didLeaveHomepage: true),
            .attemptExtract)
    }

    func testHomepageBoxAfterSubmitWhileShortKeepsPolling() {
        // The /wip/ progress shell (short request log) before the article renders:
        // not yet long enough to extract — keep polling (don't re-submit).
        XCTAssertEqual(
            decide("homepage:300", didLeaveHomepage: true),
            .wait)
    }

    func testPageAfterSubmitWithRealTextExtracts() {
        XCTAssertEqual(
            decide("page:42000", didLeaveHomepage: true),
            .attemptExtract)
    }

    // MARK: - Homepage submit (before leaving)

    func testHomepageBeforeSubmitSubmits() {
        XCTAssertEqual(decide("homepage:1200"), .submitHomepage)
    }

    func testHomepageBeforeSubmitWithResolvedSnapshotLoadsIt() {
        XCTAssertEqual(
            decide("homepage:1200", hasResolvedSnapshot: true),
            .loadResolvedSnapshot)
    }

    func testHomepageWithLongTextBeforeSubmitStillSubmits() {
        // A long homepage must not be mistaken for an article before we've submitted.
        XCTAssertEqual(decide("homepage:90000"), .submitHomepage)
    }

    // MARK: - Challenge

    func testChallengeWaitsForUser() {
        XCTAssertEqual(decide("challenge"), .challenge)
    }

    // MARK: - "Enable JS / disable ad blocker" gate

    func testBlockedGateToleratesATransientFlash() {
        XCTAssertEqual(decide("blocked", blockedCount: 1), .wait)
        XCTAssertEqual(decide("blocked", blockedCount: 2), .wait)
    }

    func testBlockedGateBecomesTerminalWhenItPersists() {
        XCTAssertEqual(decide("blocked", blockedCount: 3), .cannotArchive)
        XCTAssertEqual(decide("blocked", blockedCount: 9), .cannotArchive)
    }

    // MARK: - Errors

    func testErrorIsTerminal() {
        // archive.today's "Error -32602: Invalid InterceptionId" (probe → "error")
        // is terminal — retrying/solving won't help, so show the error.
        XCTAssertEqual(decide("error"), .cannotArchive)
    }

    func testErrorIsTerminalRegardlessOfHomepageState() {
        XCTAssertEqual(decide("error", didLeaveHomepage: true), .cannotArchive)
    }

    // MARK: - Plain page length gate

    func testShortPageWaits() {
        XCTAssertEqual(decide("page:100"), .wait)
    }

    func testPageAtThresholdWaits() {
        // Strictly greater-than: exactly 1500 is not enough.
        XCTAssertEqual(decide("page:1500"), .wait)
    }

    func testPageJustOverThresholdExtracts() {
        XCTAssertEqual(decide("page:1501"), .attemptExtract)
    }

    func testMalformedStageWaits() {
        XCTAssertEqual(decide("page:"), .wait)
        XCTAssertEqual(decide("page"), .wait)
    }

    // MARK: - JS-required gate (pre-stage hardening)

    func testJavaScriptRequiredGateDetectedOnShortBody() {
        XCTAssertTrue(ArchiveWebReaderViewController.isJavaScriptRequiredGate(
            text: "Please enable JavaScript to continue."))
        XCTAssertTrue(ArchiveWebReaderViewController.isJavaScriptRequiredGate(
            text: "JavaScript is required to view this content."))
        XCTAssertTrue(ArchiveWebReaderViewController.isJavaScriptRequiredGate(
            text: "Enable JS and reload."))
    }

    func testJavaScriptRequiredGateNotTrippedByLongArticle() {
        // A real, rendered article that merely mentions JavaScript must NOT be
        // treated as a gate (gated on a short body).
        let article = String(repeating: "This post is about JavaScript frameworks. ", count: 60)
        XCTAssertFalse(ArchiveWebReaderViewController.isJavaScriptRequiredGate(text: article))
    }

    func testJavaScriptRequiredGateNotTrippedByUnrelatedShortPage() {
        XCTAssertFalse(ArchiveWebReaderViewController.isJavaScriptRequiredGate(
            text: "Loading your article…"))
    }
}
