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
        let cycler = ArticleLoadingStatusCycler(
            label: label, initialText: "Opening in Luna…",
            alternatives: ["Still going…", "Nearly there…"])
        cycler.start()
        XCTAssertEqual(label.text, "Opening in Luna…")

        let rotated = expectation(description: "phrase rotated")
        // The cycler's own interval is 3s; wait past one tick rather than reaching
        // into it, so this asserts the shipped pacing.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.6) {
            XCTAssertNotEqual(label.text, "Opening in Luna…")
            XCTAssertTrue(["Still going…", "Nearly there…"].contains(label.text ?? ""),
                          "got \(label.text ?? "nil")")
            rotated.fulfill()
        }
        wait(for: [rotated], timeout: 6)
        cycler.stop()
    }
}
