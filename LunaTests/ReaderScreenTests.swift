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

final class ReaderScreenTests: XCTestCase {

    private let content = UITestFixtures.sampleArticleContent(title: "Reader Fixture Article")
    private var item: ReadingListItem {
        ReadingListItem(seed: "reader-fixture", urlString: "https://example.com/reader",
                        title: "Reader Fixture Article", dateAdded: UITestFixtures.baseDate,
                        state: .ready, wordCount: 480)
    }

    private var priorAnimatedTransitions = true

    override func setUp() {
        super.setUp()
        UIView.setAnimationsEnabled(false)
        // The RSVP sub-mode is persisted; pin it so snapshots are deterministic
        // regardless of any value left behind by other runs.
        ReaderSettings.rsvpMode = .words
        // Animated transitions are App-Group-persisted and default to on; pin them off
        // so these snapshots aren't perturbed by an in-flight pixel wipe.
        priorAnimatedTransitions = AppearanceSettings.animatedTransitionsEnabled
        AppearanceSettings.animatedTransitionsEnabled = false
    }

    override func tearDown() {
        AppearanceSettings.animatedTransitionsEnabled = priorAnimatedTransitions
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

    func testScrollReaderFinishesWhenScrolledToEnd() {
        var didFinish = false
        let reader = ScrollReaderViewController(item: item, content: longScrollArticleContent())
        reader.onFinishedReading = { didFinish = true }
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

        XCTAssertTrue(didFinish, "Scrolling to the full article end should mark the article read")
    }

    func testRSVPSkipToEndFinishesReading() {
        var didFinish = false
        let reader = RSVPViewController(item: item, content: shortArticleContent())
        reader.onFinishedReading = { didFinish = true }
        reader.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        reader.loadViewIfNeeded()
        reader.view.layoutIfNeeded()

        let skipForward = findControl(in: reader.view, accessibilityLabel: "Skip forward 25 words")
        XCTAssertNotNil(skipForward)
        skipForward?.sendActions(for: .touchUpInside)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        XCTAssertTrue(didFinish, "Skipping onto the final RSVP word should mark the article read")
    }

    func testReaderHostMarksScrollCompletionReadAndArchived() {
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
    }

    func testReaderHostUnmarksScrollCompletionWhenUserScrollsBack() {
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
        XCTAssertEqual(fresh?.readState, .opened)
        XCTAssertNil(fresh?.readingProgress)
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

    func testReaderHostMarksRSVPCompletionReadAndArchived() {
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
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        let fresh = ReadingListStore.shared.item(withID: storeItem.id)
        XCTAssertEqual(fresh?.readState, .read)
        XCTAssertEqual(fresh?.readingProgress, 1)
    }

    func testReaderHostUnmarksRSVPCompletionWhenUserPagesBack() {
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
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        skipBack.sendActions(for: .touchUpInside)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        let fresh = ReadingListStore.shared.item(withID: storeItem.id)
        XCTAssertEqual(fresh?.readState, .opened)
        XCTAssertNil(fresh?.readingProgress)
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
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(ReadingListStore.shared.item(withID: scrubItem.id)?.lastWordIndex, initialWordIndex,
                       "A continuous scrub tick must not persist to the store")

        slider.sendActions(for: .touchUpInside)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(ReadingListStore.shared.item(withID: scrubItem.id)?.lastWordIndex, 5,
                       "Ending the scrub gesture should persist the new word index")
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

    private func longScrollArticleContent() -> ArticleContent {
        let sentence = "This paragraph is long enough to exceed the progressive prefix and make the scroll reader genuinely scroll. "
        return ArticleContent(title: "Medium Scroll Fixture", blocks: [
            .init(kind: .paragraph, text: String(repeating: sentence, count: 20), links: []),
            .init(kind: .paragraph, text: String(repeating: sentence, count: 20), links: []),
            .init(kind: .paragraph, text: String(repeating: sentence, count: 20), links: []),
        ])
    }
}
