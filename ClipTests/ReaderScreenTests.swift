//
//  ReaderScreenTests.swift
//  ClipTests
//
//  Snapshot + navigation/layout coverage for the readers: the standard scroll
//  reader, the RSVP speed reader (Words + Phrases sub-modes), the mode switcher,
//  and the inline split-web overlay.
//

import ClipReaderUI
import ClipDesignSystem
import ClipModels
import UIKit
import XCTest
@testable import Clip

final class ReaderScreenTests: XCTestCase {

    private let content = UITestFixtures.sampleArticleContent(title: "Reader Fixture Article")
    private var item: ReadingListItem {
        ReadingListItem(seed: "reader-fixture", urlString: "https://example.com/reader",
                        title: "Reader Fixture Article", dateAdded: UITestFixtures.baseDate,
                        state: .ready, wordCount: 480)
    }

    private var priorPixelWipe = false

    override func setUp() {
        super.setUp()
        UIView.setAnimationsEnabled(false)
        // The RSVP sub-mode is persisted; pin it so snapshots are deterministic
        // regardless of any value left behind by other runs.
        ReaderSettings.rsvpMode = .words
        // These tests exercise the STANDARD reader. The experimental pixel-wipe /
        // RabbitHole toggle is App-Group-persisted and defaults to on, so pin it off
        // for hermeticity (a fresh container would otherwise route to RabbitHole).
        priorPixelWipe = ReaderSettings.pixelWipeTransitionsEnabled
        ReaderSettings.pixelWipeTransitionsEnabled = false
    }

    override func tearDown() {
        ReaderSettings.pixelWipeTransitionsEnabled = priorPixelWipe
        super.tearDown()
    }

    // MARK: - Snapshots per reader mode

    func testScrollReaderSnapshot() {
        let reader = makeReader(forceMode: .scroll)
        SnapshotTesting.assertSnapshot(of: UINavigationController(rootViewController: reader),
                                       named: "reader-scroll")
    }

    func testRSVPReaderSnapshot() {
        ReaderSettings.rsvpMode = .words
        let reader = makeReader(forceMode: .rsvp)
        SnapshotTesting.assertSnapshot(of: UINavigationController(rootViewController: reader),
                                       named: "reader-rsvp")
    }

    /// The former standalone "highlight" (chunking) view now lives as RSVP's
    /// Phrases sub-mode; `forceMode: .highlight` resolves there.
    func testPhraseReaderSnapshot() {
        let reader = makeReader(forceMode: .highlight)
        SnapshotTesting.assertSnapshot(of: UINavigationController(rootViewController: reader),
                                       named: "reader-rsvp-phrases")
    }

    func testInlineHeaderReaderSnapshot() {
        let reader = ReaderViewController(
            item: item, content: content, forceMode: .scroll,
            persistsModePreference: false, marksOpenedOnLoad: false,
            inlineControlsHeader: true, inlineHeaderSubtitle: "Today · from alex")
        SnapshotTesting.assertSnapshot(of: reader, named: "reader-inline-header")
    }

    // MARK: - Standalone scroll / RSVP children

    func testStandaloneScrollReaderSnapshot() {
        let scroll = ScrollReaderViewController(item: item, content: content)
        SnapshotTesting.assertSnapshot(of: scroll, named: "reader-scroll-standalone")
    }

    func testStandaloneRSVPSnapshot() {
        let rsvp = RSVPViewController(item: item, content: content)
        SnapshotTesting.assertSnapshot(of: rsvp, named: "reader-rsvp-standalone")
    }

    // Note: SplitWebOverlayViewController is a transition overlay that requires a
    // live cut position + rendered top/bottom halves snapshotted from the host scroll
    // reader, plus a WKWebView (no network in tests). It isn't meaningful in
    // isolation, so it stays covered by the scroll reader's simulator "Split
    // High/Low" hooks (see claudedocs/simulator-testing.md) rather than a unit
    // snapshot.

    // MARK: - Mode switcher navigation

    /// The mode switcher swaps the hosted child VC to the correct reader per segment.
    func testModeSwitcherChangesHostedChild() {
        // Inline-header config keeps the mode switcher inside the reader's own view
        // (the nav-bar config hosts it in the navigation bar instead).
        let reader = ReaderViewController(
            item: item, content: content, forceMode: .scroll,
            persistsModePreference: false, marksOpenedOnLoad: false,
            inlineControlsHeader: true)
        let window = UITestSupport.host(reader)

        guard let control = findSegmentedControl(in: reader.view) else {
            XCTFail("reader mode switcher not found"); return
        }
        XCTAssertEqual(control.numberOfSegments, 3,
                       "Scroll + RSVP + Original: a web-page save always offers the "
                       + "original archive (live page fallback when no webarchive yet); "
                       + "only email-sourced saves hide it")

        // Segment 0 = scroll, 1 = rsvp (per ReaderViewController.baseModes).
        XCTAssertTrue(reader.children.first is ScrollReaderViewController,
                      "scroll mode should host the scroll reader")

        control.selectedSegmentIndex = 1
        control.sendActions(for: .valueChanged)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertTrue(reader.children.contains { $0 is RSVPViewController },
                      "rsvp segment should host the RSVP reader")

        control.selectedSegmentIndex = 0
        control.sendActions(for: .valueChanged)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertTrue(reader.children.contains { $0 is ScrollReaderViewController },
                      "scroll segment should restore the scroll reader")
        _ = window
    }

    func testReaderLayoutHasOnScreenContent() {
        let reader = makeReader(forceMode: .scroll)
        let window = UITestSupport.host(reader)
        XCTAssertGreaterThan(reader.children.count, 0, "reader should host a child mode VC")
        if let child = reader.children.first {
            LayoutAssertions.assertVisibleAndInBounds(child.view, in: reader.view)
        }
        _ = window
    }

    // MARK: - Helpers

    private func makeReader(forceMode: ReadingListItem.ReaderMode) -> ReaderViewController {
        ReaderViewController(
            item: item, content: content, forceMode: forceMode,
            persistsModePreference: false, marksOpenedOnLoad: false)
    }

    // The mode switcher / filter are the project's custom `ClipSegmentedControl`
    // (a UIControl), not a UIKit `UISegmentedControl`.
    private func findSegmentedControl(in view: UIView) -> ClipSegmentedControl? {
        if let control = view as? ClipSegmentedControl { return control }
        for subview in view.subviews {
            if let found = findSegmentedControl(in: subview) { return found }
        }
        return nil
    }
}
