//
//  ReaderScreenTests.swift
//  LunaTests
//
//  Snapshot + navigation/layout coverage for the readers: the standard scroll
//  reader, the RSVP speed reader (Words + Phrases sub-modes), the mode switcher,
//  and the inline split-web overlay.
//

import LunaReaderUI
import LunaDesignSystem
import LunaModels
import LunaStorage
import UIKit
import XCTest
@testable import Luna

/// Records completion-delegate callbacks for tests that drive `RSVPViewController`/
/// `ScrollReaderViewController` directly (outside a host that already conforms).
private final class RecordingReaderCompletionDelegate: ReaderCompletionDelegate {
    var didFinish = false
    var didMoveAway = false
    func readerDidFinishReading(_ reader: UIViewController) { didFinish = true }
    func readerDidMoveAwayFromEnd(_ reader: UIViewController) { didMoveAway = true }
}

/// A share provider that only has to EXIST — the reader shows its floating share
/// button whenever one is installed, and the layout tests never tap it.
private final class StubReaderShareProvider: ReaderShareProviding {
    func presentShareSheet(
        urlString: String, title: String?, from presenter: UIViewController, sourceView: UIView) {}
    func saveLink(urlString: String) {}
}

final class ReaderScreenTests: XCTestCase {

    private let content = UITestFixtures.sampleArticleContent(title: "Reader Fixture Article")
    private var item: ReadingListItem {
        ReadingListItem(seed: "reader-fixture", urlString: "https://example.com/reader",
                        title: "Reader Fixture Article", dateAdded: UITestFixtures.baseDate,
                        state: .ready, wordCount: 480)
    }

    override func setUp() {
        super.setUp()
        UIView.setAnimationsEnabled(false)
        // The RSVP sub-mode is persisted; pin it so snapshots are deterministic
        // regardless of any value left behind by other runs.
        ReaderSettings.rsvpMode = .words
    }

    override func tearDown() {
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

    func testInlineHeaderReaderSnapshot() {
        let reader = ReaderViewController(
            item: item, content: content, forceMode: .scroll,
            persistsModePreference: false, marksOpenedOnLoad: false,
            inlineControlsHeader: true, inlineHeaderSubtitle: "Today · from alex")
        SnapshotTesting.assertSnapshot(of: reader, named: "reader-inline-header")
    }

    // The standalone `ScrollReaderViewController` / `RSVPViewController`
    // snapshots are gone: each was the same child the hosted scroll/rsvp
    // snapshots above already render, minus the host chrome — a second
    // reference image of the same pixels. Their non-snapshot behavior (finish
    // on scroll end, skip-to-end, scrubber persistence, restored offsets) is
    // asserted directly further down.
    //
    // The former standalone "highlight" (chunking) snapshot is gone too:
    // Phrases is an RSVP sub-mode, and the sub-mode switch itself is covered by
    // `testModeSwitcherChangesHostedChild`.
    //
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
                       + "original archive (local article snapshot when no webarchive exists); "
                       + "only email-sourced saves hide it")

        // Segment 0 = scroll, 1 = rsvp (per ReaderViewController.baseModes).
        XCTAssertTrue(reader.children.first is ScrollReaderViewController,
                      "scroll mode should host the scroll reader")

        control.selectedSegmentIndex = 1
        control.sendActions(for: .valueChanged)
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        XCTAssertTrue(reader.children.contains { $0 is RSVPViewController },
                      "rsvp segment should host the RSVP reader")

        control.selectedSegmentIndex = 0
        control.sendActions(for: .valueChanged)
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
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

    func testScrollReaderFinishesWhenScrolledToEnd() {
        let delegate = RecordingReaderCompletionDelegate()
        let reader = ScrollReaderViewController(item: item, content: longScrollArticleContent())
        reader.completionDelegate = delegate
        reader.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        reader.loadViewIfNeeded()
        reader.view.layoutIfNeeded()

        if !reader.didLoadFullContentForTesting {
            reader.prepareFullContent()
        }
        let deadline = Date().addingTimeInterval(5)
        while !reader.didLoadFullContentForTesting, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertTrue(reader.didLoadFullContentForTesting)

        guard let textView = findTextView(in: reader.view) else {
            XCTFail("Scroll reader should contain its text view")
            return
        }
        let maxOffset = max(
            -textView.adjustedContentInset.top,
            textView.contentSize.height + textView.adjustedContentInset.bottom - textView.bounds.height)
        textView.contentOffset.y = maxOffset
        reader.scrollViewDidScroll(textView)

        XCTAssertTrue(delegate.didFinish, "Scrolling to the full article end should mark the article read")
        let badge = findView(of: FinishedReadingBadgeView.self, in: reader.view)
        XCTAssertFalse(badge?.isHidden ?? true)
    }

    func testScrollReaderCompletionLaneKeepsBottomOffsetStable() {
        let reader = ScrollReaderViewController(item: item, content: longScrollArticleContent())
        reader.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        reader.loadViewIfNeeded()
        reader.view.layoutIfNeeded()
        if !reader.didLoadFullContentForTesting {
            reader.prepareFullContent()
        }
        let deadline = Date().addingTimeInterval(5)
        while !reader.didLoadFullContentForTesting, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }

        guard let textView = findTextView(in: reader.view) else {
            XCTFail("Scroll reader should contain its text view")
            return
        }
        func maximumOffset() -> CGFloat {
            max(
                -textView.adjustedContentInset.top,
                textView.contentSize.height + textView.adjustedContentInset.bottom
                    - textView.bounds.height)
        }

        textView.contentOffset.y = maximumOffset()
        reader.scrollViewDidScroll(textView)
        let settledMaximum = maximumOffset()
        for _ in 0..<5 {
            reader.view.setNeedsLayout()
            reader.view.layoutIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }

        XCTAssertEqual(maximumOffset(), settledMaximum, accuracy: 0.5)
        XCTAssertLessThanOrEqual(textView.contentOffset.y, maximumOffset() + 0.5)
    }

    func testRSVPControlsRemainVisibleBelowTallTitleInset() {
        let reader = RSVPViewController(item: item, content: shortArticleContent())
        reader.topContentInset = 150
        reader.view.frame = CGRect(x: 0, y: 0, width: 390, height: 650)
        reader.loadViewIfNeeded()
        reader.view.layoutIfNeeded()

        let controls = [
            "Skip back 25 words", "Slow down", "Play", "Speed up",
            "Skip forward 25 words",
        ].compactMap { findControl(in: reader.view, accessibilityLabel: $0) }

        XCTAssertEqual(controls.count, 5)
        for control in controls {
            let frame = control.convert(control.bounds, to: reader.view)
            XCTAssertGreaterThanOrEqual(frame.minY, reader.view.bounds.minY)
            XCTAssertLessThanOrEqual(frame.maxY, reader.view.bounds.maxY)
        }
    }

    func testRSVPPlayButtonUsesTrueCircularGeometry() throws {
        let reader = RSVPViewController(item: item, content: shortArticleContent())
        reader.view.frame = CGRect(x: 0, y: 0, width: 320, height: 650)
        reader.loadViewIfNeeded()
        reader.view.layoutIfNeeded()

        let play = try XCTUnwrap(
            findControl(in: reader.view, accessibilityLabel: "Play") as? UIButton)
        XCTAssertEqual(play.bounds.width, play.bounds.height, accuracy: 0.01)
        XCTAssertEqual(play.bounds.width, 60, accuracy: 0.01)
        XCTAssertEqual(play.layer.cornerRadius, 30, accuracy: 0.01)
        XCTAssertEqual(play.configuration?.background.cornerRadius, 30)
    }

    func testFinishedScrollReaderStartsAtTopInsteadOfPersistedEnd() {
        var finished = item
        finished.readState = .read
        finished.lastScrollOffset = 50_000
        finished.lastWordIndex = 400
        let reader = ScrollReaderViewController(item: finished, content: longScrollArticleContent())
        reader.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        reader.loadViewIfNeeded()
        reader.view.layoutIfNeeded()

        guard let textView = findTextView(in: reader.view) else {
            XCTFail("Scroll reader should contain its text view")
            return
        }
        XCTAssertLessThanOrEqual(
            textView.contentOffset.y, -textView.adjustedContentInset.top + 1,
            "A finished card should show the article opening, not its empty end tail")
        XCTAssertEqual(textView.alpha, 1)
    }

    func testInProgressScrollReaderStillRestoresPersistedOffset() {
        var inProgress = item
        inProgress.readState = .opened
        inProgress.lastScrollOffset = 600
        let reader = ScrollReaderViewController(item: inProgress, content: longScrollArticleContent())
        reader.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        reader.loadViewIfNeeded()
        reader.view.layoutIfNeeded()

        guard let textView = findTextView(in: reader.view) else {
            XCTFail("Scroll reader should contain its text view")
            return
        }
        XCTAssertEqual(textView.contentOffset.y, 600, accuracy: 1)
        XCTAssertEqual(textView.alpha, 1)
    }

    func testInProgressScrollReaderRestoresPersistedZeroToVisualTop() {
        var inProgress = item
        inProgress.readState = .opened
        inProgress.lastScrollOffset = 0
        let reader = ScrollReaderViewController(item: inProgress, content: longScrollArticleContent())
        reader.topChromeInset = 96
        reader.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        reader.loadViewIfNeeded()
        reader.view.layoutIfNeeded()

        guard let textView = findTextView(in: reader.view) else {
            XCTFail("Scroll reader should contain its text view")
            return
        }
        XCTAssertEqual(
            textView.contentOffset.y, -textView.adjustedContentInset.top, accuracy: 1,
            "Persisted zero must reveal the complete title-inset region")
        XCTAssertEqual(reader.currentReadingScrollOffsetY, 0, accuracy: 0.001)
    }

    func testRSVPSkipToEndFinishesReading() {
        let delegate = RecordingReaderCompletionDelegate()
        let reader = RSVPViewController(item: item, content: shortArticleContent())
        reader.completionDelegate = delegate
        reader.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        reader.loadViewIfNeeded()
        reader.view.layoutIfNeeded()

        let skipForward = findControl(in: reader.view, accessibilityLabel: "Skip forward 25 words")
        XCTAssertNotNil(skipForward)
        skipForward?.sendActions(for: .touchUpInside)
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))

        XCTAssertTrue(delegate.didFinish, "Skipping onto the final RSVP word should mark the article read")
        let badge = findView(of: FinishedReadingBadgeView.self, in: reader.view)
        XCTAssertFalse(badge?.isHidden ?? true)
        XCTAssertEqual(badge?.bounds.height, FinishedReadingBadgeView.pillHeight)
    }

    func testReaderHostMarksScrollCompletionReadAndPendingArchive() {
        let storeItem = ReadingListStore.shared.add(urlString: "https://example.com/scroll-finish-\(UUID().uuidString)")
        defer { ReadingListStore.shared.delete(storeItem) }
        let reader = ReaderViewController(
            item: storeItem, content: longScrollArticleContent(), forceMode: .scroll,
            persistsModePreference: false, marksOpenedOnLoad: false,
            inlineControlsHeader: true)
        reader.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        reader.loadViewIfNeeded()
        reader.view.layoutIfNeeded()
        guard let scroll = reader.children.compactMap({ $0 as? ScrollReaderViewController }).first,
              let textView = findTextView(in: scroll.view) else {
            XCTFail("Reader host should contain a scroll reader")
            return
        }
        scroll.prepareFullContent()
        let deadline = Date().addingTimeInterval(5)
        while !scroll.didLoadFullContentForTesting, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }

        textView.contentOffset.y = max(
            -textView.adjustedContentInset.top,
            textView.contentSize.height + textView.adjustedContentInset.bottom - textView.bounds.height)
        scroll.scrollViewDidScroll(textView)

        let fresh = ReadingListStore.shared.item(withID: storeItem.id)
        XCTAssertEqual(fresh?.readState, .read)
        XCTAssertEqual(fresh?.readingProgress, 1)
        XCTAssertNotNil(fresh?.pendingArchiveAt)
        XCTAssertNil(fresh?.archivedAt)
    }

    func testReaderHostKeepsScrollCompletionWhenUserScrollsBack() {
        let storeItem = ReadingListStore.shared.add(urlString: "https://example.com/scroll-unfinish-\(UUID().uuidString)")
        defer { ReadingListStore.shared.delete(storeItem) }
        let reader = ReaderViewController(
            item: storeItem, content: longScrollArticleContent(), forceMode: .scroll,
            persistsModePreference: false, marksOpenedOnLoad: true,
            inlineControlsHeader: true)
        reader.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        reader.loadViewIfNeeded()
        reader.view.layoutIfNeeded()
        guard let scroll = reader.children.compactMap({ $0 as? ScrollReaderViewController }).first,
              let textView = findTextView(in: scroll.view) else {
            XCTFail("Reader host should contain a scroll reader")
            return
        }
        scroll.prepareFullContent()
        let deadline = Date().addingTimeInterval(5)
        while !scroll.didLoadFullContentForTesting, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }

        textView.contentOffset.y = max(
            -textView.adjustedContentInset.top,
            textView.contentSize.height + textView.adjustedContentInset.bottom - textView.bounds.height)
        scroll.scrollViewDidScroll(textView)
        textView.contentOffset.y = 0
        scroll.scrollViewDidScroll(textView)

        let fresh = ReadingListStore.shared.item(withID: storeItem.id)
        XCTAssertEqual(fresh?.readState, .read)
        XCTAssertEqual(fresh?.readingProgress, 1)
        XCTAssertNotNil(fresh?.pendingArchiveAt)
        XCTAssertNil(fresh?.archivedAt)
    }

    func testReaderHostDoesNotUnmarkScrollArticleThatWasReadOnEntry() {
        let added = ReadingListStore.shared.add(urlString: "https://example.com/scroll-read-entry-\(UUID().uuidString)")
        ReadingListStore.shared.markFinishedReading(added.id)
        let storeItem = ReadingListStore.shared.item(withID: added.id)!
        defer { ReadingListStore.shared.delete(storeItem) }
        let reader = ReaderViewController(
            item: storeItem, content: longScrollArticleContent(), forceMode: .scroll,
            persistsModePreference: false, marksOpenedOnLoad: true,
            inlineControlsHeader: true)
        reader.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        reader.loadViewIfNeeded()
        reader.view.layoutIfNeeded()
        guard let scroll = reader.children.compactMap({ $0 as? ScrollReaderViewController }).first,
              let textView = findTextView(in: scroll.view) else {
            XCTFail("Reader host should contain a scroll reader")
            return
        }
        scroll.prepareFullContent()
        let deadline = Date().addingTimeInterval(5)
        while !scroll.didLoadFullContentForTesting, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }

        textView.contentOffset.y = max(
            -textView.adjustedContentInset.top,
            textView.contentSize.height + textView.adjustedContentInset.bottom - textView.bounds.height)
        scroll.scrollViewDidScroll(textView)
        textView.contentOffset.y = 0
        scroll.scrollViewDidScroll(textView)

        let fresh = ReadingListStore.shared.item(withID: storeItem.id)
        XCTAssertEqual(fresh?.readState, .read)
        XCTAssertEqual(fresh?.readingProgress, 1)
    }

    func testReaderHostMarksRSVPCompletionReadAndPendingArchive() {
        let storeItem = ReadingListStore.shared.add(urlString: "https://example.com/rsvp-finish-\(UUID().uuidString)")
        defer { ReadingListStore.shared.delete(storeItem) }
        let reader = ReaderViewController(
            item: storeItem, content: shortArticleContent(), forceMode: .rsvp,
            persistsModePreference: false, marksOpenedOnLoad: false,
            inlineControlsHeader: true)
        reader.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        reader.loadViewIfNeeded()
        reader.view.layoutIfNeeded()
        guard let rsvp = reader.children.compactMap({ $0 as? RSVPViewController }).first,
              let skipForward = findControl(in: rsvp.view, accessibilityLabel: "Skip forward 25 words") else {
            XCTFail("Reader host should contain an RSVP reader with skip controls")
            return
        }

        skipForward.sendActions(for: .touchUpInside)
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))

        let fresh = ReadingListStore.shared.item(withID: storeItem.id)
        XCTAssertEqual(fresh?.readState, .read)
        XCTAssertEqual(fresh?.readingProgress, 1)
        XCTAssertNotNil(fresh?.pendingArchiveAt)
        XCTAssertNil(fresh?.archivedAt)
    }

    func testReaderHostKeepsRSVPCompletionWhenUserPagesBack() {
        let storeItem = ReadingListStore.shared.add(urlString: "https://example.com/rsvp-unfinish-\(UUID().uuidString)")
        defer { ReadingListStore.shared.delete(storeItem) }
        let reader = ReaderViewController(
            item: storeItem, content: shortArticleContent(), forceMode: .rsvp,
            persistsModePreference: false, marksOpenedOnLoad: true,
            inlineControlsHeader: true)
        reader.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        reader.loadViewIfNeeded()
        reader.view.layoutIfNeeded()
        guard let rsvp = reader.children.compactMap({ $0 as? RSVPViewController }).first,
              let skipForward = findControl(in: rsvp.view, accessibilityLabel: "Skip forward 25 words"),
              let skipBack = findControl(in: rsvp.view, accessibilityLabel: "Skip back 25 words") else {
            XCTFail("Reader host should contain an RSVP reader with skip controls")
            return
        }

        skipForward.sendActions(for: .touchUpInside)
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        skipBack.sendActions(for: .touchUpInside)
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        // Skipping saves progress via the fire-and-forget saveReaderExitPosition
        // (WS-F1); flush before reading back so this isn't racing the store queue.
        ReadingListStore.shared.flushPendingUpdates()

        let fresh = ReadingListStore.shared.item(withID: storeItem.id)
        XCTAssertEqual(fresh?.readState, .read)
        XCTAssertEqual(fresh?.readingProgress, 1)
        XCTAssertNotNil(fresh?.pendingArchiveAt)
        XCTAssertNil(fresh?.archivedAt)
    }

    /// A continuous scrubber drag (`.valueChanged`, UISlider's default continuous
    /// mode) must not write to the store — only the gesture's end
    /// (touch up/cancel) persists, in one batched call.
    func testRSVPScrubOnlyPersistsOnTouchUp() {
        let content = shortArticleContent()
        // `add` inserts a real item into the shared store (needed so the reader's
        // save calls have a matching row to mutate) without disturbing any other
        // items already there; it's removed again below.
        let scrubItem = ReadingListStore.shared.add(urlString: "https://example.com/rsvp-scrub-\(UUID().uuidString)")
        defer { ReadingListStore.shared.delete(scrubItem) }

        let reader = RSVPViewController(item: scrubItem, content: content)
        reader.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        reader.loadViewIfNeeded()
        reader.view.layoutIfNeeded()

        guard let slider = findSlider(in: reader.view) else {
            XCTFail("RSVP reader should contain its scrubber")
            return
        }
        let initialWordIndex = ReadingListStore.shared.item(withID: scrubItem.id)?.lastWordIndex

        slider.value = 5
        slider.sendActions(for: .valueChanged)
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        XCTAssertEqual(ReadingListStore.shared.item(withID: scrubItem.id)?.lastWordIndex, initialWordIndex,
                       "A continuous scrub tick must not persist to the store")

        slider.sendActions(for: .touchUpInside)
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        // saveReaderExitPosition is a fire-and-forget async write (WS-F1); flush
        // it before reading back so this assertion isn't racing the store queue.
        ReadingListStore.shared.flushPendingUpdates()
        XCTAssertEqual(ReadingListStore.shared.item(withID: scrubItem.id)?.lastWordIndex, 5,
                       "Ending the scrub gesture should persist the new word index")
    }

    // MARK: - Speed-reader vertical layout

    /// The action extension hands the speed reader a view that already starts
    /// below the navigation bar, so its own chrome inset is zero while the bottom
    /// ~200pt go to the playback controls and the home-indicator inset. The focal
    /// word rests at the midpoint of what is left. It used to rest at the
    /// midpoint of the VIEW — which is only the same point when the chrome above
    /// and the controls below are equally tall — and sat ~110pt low, with a void
    /// between the extension's chrome and the preceding prose.
    func testRSVPFocalWordRestsAtTheMidpointOfItsReadingBand() {
        let reader = RSVPViewController(
            item: item, content: longContextContent(), resumeWordIndex: 60)
        reader.view.frame = CGRect(x: 0, y: 0, width: 402, height: 732)
        reader.loadViewIfNeeded()
        reader.view.layoutIfNeeded()

        let geometry = reader.layoutGeometryForTesting
        XCTAssertEqual(
            geometry.focalCenterY,
            geometry.bandCenterY + RSVPViewController.focalCenterBiasForTesting,
            accuracy: 0.5,
            "The focal word rests on the midpoint of the band between the host "
            + "chrome and the playback controls")
        XCTAssertLessThan(
            geometry.focalCenterY, reader.view.bounds.midY,
            "The band's midpoint is above the view's whenever the controls take "
            + "more room below than the chrome takes above")
    }

    /// Each context lane is sized to the prose it holds and pinned to the focal
    /// band. Given the whole lane, a short passage centers inside it — which is
    /// the hole that used to open between the chrome and the preceding text.
    func testRSVPContextLanesAreSizedToTheirProseAndHugTheFocalBand() {
        let reader = RSVPViewController(
            item: item, content: longContextContent(), resumeWordIndex: 6)
        reader.view.frame = CGRect(x: 0, y: 0, width: 402, height: 732)
        reader.loadViewIfNeeded()
        reader.view.layoutIfNeeded()

        let geometry = reader.layoutGeometryForTesting
        XCTAssertEqual(
            geometry.gapAboveProse, 20, accuracy: 0.5,
            "The preceding lane keeps its bottom a third of the old 60pt off the "
            + "word's own edge")
        XCTAssertLessThan(
            geometry.precedingContext.height, 100,
            "Six words of preceding prose take two lines, not the 220pt lane they "
            + "may grow into")
        XCTAssertEqual(
            geometry.gapBelowProse, 31, accuracy: 0.5,
            "…and the trailing lane a third of the old 92pt — the empty pill row "
            + "is no longer held open under every word")
        XCTAssertGreaterThan(geometry.trailingContext.height, 0)
    }

    /// The pill row is reserved only while something is in it. A link pill (or
    /// the completion badge) pushes the trailing prose down by its own height
    /// instead of every other word paying for an empty row.
    func testRSVPTrailingProseYieldsTheRowOnlyWhileAPillOccupiesIt() {
        let prose = "one two three four five six seven eight nine ten eleven "
            + "twelve thirteen fourteen fifteen sixteen seventeen"
        let seven = (prose as NSString).range(of: "seven")
        let linked = ArticleContent(title: "Linked RSVP Fixture", blocks: [
            .init(kind: .paragraph, text: prose,
                  links: [.init(start: seven.location, length: seven.length,
                                urlString: "https://example.com/link")]),
        ])
        let reader = RSVPViewController(item: item, content: linked, resumeWordIndex: 3)
        reader.view.frame = CGRect(x: 0, y: 0, width: 402, height: 732)
        reader.loadViewIfNeeded()
        reader.view.layoutIfNeeded()

        let quiet = reader.layoutGeometryForTesting
        XCTAssertEqual(quiet.trailingContext.minY, quiet.pillRow.minY, accuracy: 0.5,
                       "With no pill showing, the prose starts on the pill's row")

        guard let slider = findSlider(in: reader.view) else {
            XCTFail("RSVP reader should contain its scrubber"); return
        }
        slider.value = 6                                    // the linkified word
        slider.sendActions(for: .valueChanged)
        reader.view.layoutIfNeeded()

        let withPill = reader.layoutGeometryForTesting
        XCTAssertGreaterThan(
            withPill.trailingContext.minY, withPill.pillRow.maxY,
            "A visible pill pushes the prose clear of the whole row")
        XCTAssertEqual(withPill.pillRow.minY, quiet.pillRow.minY, accuracy: 0.5,
                       "The row itself doesn't move — only the prose below it")
    }

    /// A roomy container lets the controls unglue from the bottom safe area (the
    /// reading group is centered on the band, so it rises with them); a container
    /// with no height to spare keeps them where they were.
    func testRSVPControlsLiftOffTheBottomOnlyWhenTheBandCanSpareIt() {
        let roomy = RSVPViewController(item: item, content: longContextContent())
        roomy.view.frame = CGRect(x: 0, y: 0, width: 402, height: 732)
        roomy.loadViewIfNeeded()
        roomy.view.layoutIfNeeded()
        XCTAssertEqual(
            roomy.layoutGeometryForTesting.controls.maxY, 732 - 64, accuracy: 0.5,
            "24pt base gap plus the 40pt lift")

        let tight = RSVPViewController(item: item, content: longContextContent())
        tight.topContentInset = 150
        tight.view.frame = CGRect(x: 0, y: 0, width: 390, height: 650)
        tight.loadViewIfNeeded()
        tight.view.layoutIfNeeded()
        XCTAssertEqual(
            tight.layoutGeometryForTesting.controls.maxY, 650 - 24, accuracy: 0.5,
            "A band this short owes the reading group every point it has")
    }

    /// The host's floating share circle hovers over the speed reader. It has to
    /// clear the playback controls (whose top now moves with the lift) and the
    /// trailing-context prose has to clear IT — in the extension the circle sat
    /// on top of the trailing line.
    func testReaderShareButtonClearsRSVPControlsAndTrailingContext() {
        let share = StubReaderShareProvider()
        let reader = ReaderViewController(
            item: item, content: longContextContent(), forceMode: .rsvp,
            shareProvider: share, persistsModePreference: false,
            marksOpenedOnLoad: false, inlineControlsHeader: true)
        reader.view.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        reader.loadViewIfNeeded()
        reader.view.layoutIfNeeded()

        guard let rsvp = reader.children.compactMap({ $0 as? RSVPViewController }).first,
              let shareButton = reader.view.subviews.compactMap({ $0 as? UIButton }).first
        else {
            XCTFail("The RSVP host should float a share button over the speed reader")
            return
        }
        // Mid-article, so both context lanes carry their full 55 words.
        if let slider = findSlider(in: rsvp.view) {
            slider.value = 60
            slider.sendActions(for: .valueChanged)
        }
        reader.view.layoutIfNeeded()

        let geometry = rsvp.layoutGeometryForTesting
        let shareInReader = reader.view.convert(shareButton.frame, to: rsvp.view)
        XCTAssertLessThanOrEqual(
            shareInReader.maxY, geometry.controls.minY,
            "The share circle hangs above the playback controls")
        XCTAssertFalse(
            shareInReader.intersects(geometry.trailingContext),
            "The trailing-context lane gives up the width the share circle covers")
        XCTAssertGreaterThan(
            geometry.trailingContext.width, 140,
            "…without narrowing into a column of fragments")
    }

    // MARK: - Helpers

    private func findSlider(in view: UIView) -> UISlider? {
        if let slider = view as? UISlider { return slider }
        for subview in view.subviews {
            if let found = findSlider(in: subview) { return found }
        }
        return nil
    }

    private func makeReader(forceMode: ReadingListItem.ReaderMode) -> ReaderViewController {
        ReaderViewController(
            item: item, content: content, forceMode: forceMode,
            persistsModePreference: false, marksOpenedOnLoad: false)
    }

    // The mode switcher / filter are the project's custom `LunaSegmentedControl`
    // (a UIControl), not a UIKit `UISegmentedControl`.
    private func findSegmentedControl(in view: UIView) -> LunaSegmentedControl? {
        if let control = view as? LunaSegmentedControl { return control }
        for subview in view.subviews {
            if let found = findSegmentedControl(in: subview) { return found }
        }
        return nil
    }

    private func findControl(in view: UIView, accessibilityLabel: String) -> UIControl? {
        if let control = view as? UIControl, control.accessibilityLabel == accessibilityLabel {
            return control
        }
        for subview in view.subviews {
            if let found = findControl(in: subview, accessibilityLabel: accessibilityLabel) {
                return found
            }
        }
        return nil
    }

    /// Enough prose for both context lanes to fill at any position.
    private func longContextContent() -> ArticleContent {
        let sentence = "There has been a weird debate over the last few months about "
            + "whether the United States is better off than Western Europe and the "
            + "participants of this debate tend to operate under a shared premise "
            + "that people know what they mean by better off in the first place. "
        return ArticleContent(title: "Long RSVP Fixture", blocks: [
            .init(kind: .paragraph, text: String(repeating: sentence, count: 6), links: []),
        ])
    }

    private func shortArticleContent() -> ArticleContent {
        ArticleContent(title: "Short RSVP Fixture", blocks: [
            .init(kind: .paragraph, text: "one two three four five six seven eight nine ten", links: []),
        ])
    }

    private func findTextView(in view: UIView) -> UITextView? {
        if let textView = view as? UITextView { return textView }
        for subview in view.subviews {
            if let found = findTextView(in: subview) { return found }
        }
        return nil
    }

    private func findView<T: UIView>(of type: T.Type, in view: UIView) -> T? {
        if let match = view as? T { return match }
        for subview in view.subviews {
            if let match = findView(of: type, in: subview) { return match }
        }
        return nil
    }

    private func longScrollArticleContent() -> ArticleContent {
        let sentence = "This paragraph is long enough to exceed the progressive prefix and make the scroll reader genuinely scroll. "
        return ArticleContent(title: "Medium Scroll Fixture", blocks: [
            .init(kind: .paragraph, text: String(repeating: sentence, count: 20), links: []),
            .init(kind: .paragraph, text: String(repeating: sentence, count: 20), links: []),
            .init(kind: .paragraph, text: String(repeating: sentence, count: 20), links: []),
        ])
    }
}
