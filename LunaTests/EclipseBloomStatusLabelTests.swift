//
//  EclipseBloomStatusLabelTests.swift
//  LunaTests
//

import LunaDesignSystem
import UIKit
import XCTest

/// The status label every loading surface uses — the action extension's "Opening in
/// Luna…", the archive reader's "Unlocking article…", and the rotating reassurance
/// underneath both. None of it was tested, which is how the reveal-before-layout
/// deadlock shipped: a reveal asked for in view setup returned before applying the
/// text, the view takes its width FROM that text, so bounds stayed zero and the
/// retry could never satisfy its own guard. No surface ever showed a word.
final class EclipseBloomStatusLabelTests: XCTestCase {

    /// A reveal requested before any layout must still put the words on screen, and
    /// must give the view a real size once laid out. This is the regression.
    func testRevealBeforeLayoutStillShowsTextAndSizesItself() {
        let label = EclipseBloomStatusLabel()
        label.numberOfLines = 0
        XCTAssertEqual(label.bounds.width, 0, "precondition: no bounds yet")

        label.reveal("Unlocking article…")
        XCTAssertEqual(label.text, "Unlocking article…",
                       "the text must be applied even with no bounds to sweep")

        // What Auto Layout would ask for: a view that reports a real size is a view
        // whose bounds can become non-zero. Zero here was the deadlock.
        let fitting = label.systemLayoutSizeFitting(
            CGSize(width: 320, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .fittingSizeLevel,
            verticalFittingPriority: .fittingSizeLevel)
        XCTAssertGreaterThan(fitting.width, 0)
        XCTAssertGreaterThan(fitting.height, 0)
    }

    /// Once bounds exist, the parked sweep runs and the text survives it.
    func testParkedRevealRunsAfterLayout() {
        let label = EclipseBloomStatusLabel()
        label.reveal("Still going…")
        label.frame = CGRect(x: 0, y: 0, width: 300, height: 24)
        label.layoutIfNeeded()
        XCTAssertEqual(label.text, "Still going…")
    }

    /// The ordinary path — bounds first, then reveal — is unchanged.
    func testRevealAfterLayoutShowsText() {
        let label = EclipseBloomStatusLabel()
        label.frame = CGRect(x: 0, y: 0, width: 300, height: 24)
        label.layoutIfNeeded()
        label.reveal("Nearly there…")
        XCTAssertEqual(label.text, "Nearly there…")
        XCTAssertTrue(label.usesOnboardingGlyphBloom)
        XCTAssertEqual(
            label.subviews.compactMap { $0 as? UILabel }.count, 1,
            "the bloom must not stack a second full-text label over the final ink")
    }

    /// Rotating loading copy is a whole-phrase replacement. Unlike the intro
    /// headline's second beat, it must never look for a shared run between two
    /// unrelated status messages before it can bloom the new one.
    func testRevealReplacesCompletelyUnrelatedTextWithTheSameGlyphBloom() {
        let label = EclipseBloomStatusLabel()
        label.frame = CGRect(x: 0, y: 0, width: 300, height: 24)
        label.layoutIfNeeded()

        label.reveal("Opening in Luna…")
        label.reveal("Finding the good part…")

        XCTAssertEqual(label.text, "Finding the good part…")
        XCTAssertTrue(label.usesOnboardingGlyphBloom)
    }

    /// A terminal message must not be overwritten by a reveal that was still owed
    /// from before layout — the rate-limited / un-archivable copy is the last word.
    func testTerminalMessageSurvivesAParkedReveal() {
        let label = EclipseBloomStatusLabel()
        label.reveal("Unlocking article…")     // parked: no bounds yet
        label.setTextImmediately("This site can't be archived right now.")
        label.frame = CGRect(x: 0, y: 0, width: 300, height: 48)
        label.layoutIfNeeded()
        XCTAssertEqual(label.text, "This site can't be archived right now.")
    }

    /// The cycler's rotation is what the user reported missing. It replaces the
    /// initial phrase with one of the alternatives, and never gets stuck empty.
    func testStatusCyclerRotatesThroughItsPhrases() {
        let label = EclipseBloomStatusLabel()
        label.frame = CGRect(x: 0, y: 0, width: 300, height: 24)
        label.layoutIfNeeded()
        // The rotation is what's under test, not the shipped three seconds; the
        // interval is a parameter so this can watch one tick go by in 60ms.
        let cycler = ArticleLoadingStatusCycler(
            label: label, initialText: "Opening in Luna…", interval: 0.05,
            alternatives: ["Still going…", "Nearly there…"])
        cycler.start()
        XCTAssertEqual(label.text, "Opening in Luna…")

        let rotated = expectation(description: "phrase rotated")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            XCTAssertNotEqual(label.text, "Opening in Luna…")
            XCTAssertTrue(["Still going…", "Nearly there…"].contains(label.text ?? ""),
                          "got \(label.text ?? "nil")")
            rotated.fulfill()
        }
        wait(for: [rotated], timeout: 6)
        cycler.stop()
    }

    /// The FIRST phrase a spinner shows has nothing to hold continuity with
    /// yet, so its bloom is near-instant; every phrase AFTER it is a real
    /// transition and keeps the full sweep, unchanged.
    func testCyclerBloomsTheFirstPhraseInFastButRotatesAtTheUnchangedSpeed() {
        let label = EclipseBloomStatusLabel()
        label.frame = CGRect(x: 0, y: 0, width: 300, height: 24)
        label.layoutIfNeeded()
        let cycler = ArticleLoadingStatusCycler(
            label: label, initialText: "Opening in Luna…", interval: 0.05,
            alternatives: ["Still going…"])
        cycler.start()

        XCTAssertEqual(
            label.lastResolvedRevealDurationForTesting,
            ArticleLoadingStatusCycler.instantRevealDuration,
            "the spinner's first word must bloom in barely perceptibly")

        let rotated = expectation(description: "phrase rotated")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            XCTAssertEqual(label.text, "Still going…")
            XCTAssertEqual(
                label.lastResolvedRevealDurationForTesting, 1.55,
                "the transition between two loading phrases must be untouched")
            rotated.fulfill()
        }
        wait(for: [rotated], timeout: 6)
        cycler.stop()
    }
}
