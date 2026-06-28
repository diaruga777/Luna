//
//  ArchiveStageDecisionTests.swift
//  ClipTests
//

import ClipArchiveReader
import XCTest
@testable import Clip

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

    // MARK: - The fixed regression

    func testHomepageChromeAfterSubmitDoesNotResubmit() {
        // The snapshot's chrome still has the home form. It is not itself a content
        // signal; wait for the semantic content-root probe instead of text length.
        XCTAssertEqual(decide("homepage", didLeaveHomepage: true), .wait)
    }

    func testContentRootAfterSubmitExtracts() {
        XCTAssertEqual(decide("content-root", didLeaveHomepage: true), .attemptExtract)
    }

    func testVerboseRequestLogNeverTriggersExtraction() {
        XCTAssertEqual(decide("waiting", didLeaveHomepage: true), .wait)
    }

    // MARK: - Homepage submit (before leaving)

    func testHomepageBeforeSubmitSubmits() {
        XCTAssertEqual(decide("homepage"), .submitHomepage)
    }

    func testHomepageBeforeSubmitWithResolvedSnapshotLoadsIt() {
        XCTAssertEqual(
            decide("homepage", hasResolvedSnapshot: true),
            .loadResolvedSnapshot)
    }

    func testSubmittingHomepageWaitsForNavigation() {
        XCTAssertEqual(decide("homepage", isSubmittingHomepage: true), .wait)
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

    func testMalformedStageWaits() {
        XCTAssertEqual(decide("unknown"), .wait)
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
