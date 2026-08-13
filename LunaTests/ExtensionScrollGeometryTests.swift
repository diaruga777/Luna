//
//  ExtensionScrollGeometryTests.swift
//  LunaTests
//
//  The extension surfaces put their screens under a navigation bar that draws
//  OVER them, in someone else's window. These cover the two things that go wrong
//  when that header's height is left to the automatic content-inset adjustment:
//  content that opens already scrolled up under the bar, and a scroll indicator
//  whose track doesn't span what the screen shows.
//

import LunaDesignSystem
import LunaModels
import LunaReaderUI
import LunaShareSurface
import UIKit
import XCTest

@MainActor
final class ExtensionScrollGeometryTests: XCTestCase {

    // MARK: - The header's height

    /// The whole arithmetic: a screen needs only the part of the bar that its own
    /// safe area doesn't already cover.
    func testAdditionalTopInsetIsWhatTheBarStillCovers() {
        XCTAssertEqual(
            ExtensionNavigationController.additionalTopInset(
                barBottom: 44, grantedSafeAreaTop: 0),
            44, accuracy: 0.001,
            "A bar over a screen with no safe area of its own must be added whole")
        XCTAssertEqual(
            ExtensionNavigationController.additionalTopInset(
                barBottom: 103, grantedSafeAreaTop: 59),
            44, accuracy: 0.001,
            "Only the part the granted safe area doesn't reach is missing")
    }

    /// A runtime that already inset the screen past its bar needs no help, and a
    /// screen sitting BELOW the bar must never be cropped for it.
    func testAdditionalTopInsetIsZeroWhenTheScreenIsAlreadyClear() {
        XCTAssertEqual(
            ExtensionNavigationController.additionalTopInset(
                barBottom: 103, grantedSafeAreaTop: 103),
            0, accuracy: 0.001)
        XCTAssertEqual(
            ExtensionNavigationController.additionalTopInset(
                barBottom: 103, grantedSafeAreaTop: 140),
            0, accuracy: 0.001, "Never negative")
    }

    // MARK: - Sheet-wide exit swipe

    func testDownwardExitSwipeNeedsBothDistanceAndVelocity() {
        XCTAssertTrue(ExtensionNavigationController.shouldDismissOnSwipe(
            translationY: ExtensionNavigationController.swipeDismissDistance,
            peakDownwardVelocity: ExtensionNavigationController.swipeDismissVelocity,
            peakLateralVelocity: 0))
        XCTAssertFalse(ExtensionNavigationController.shouldDismissOnSwipe(
            translationY: ExtensionNavigationController.swipeDismissDistance - 1,
            peakDownwardVelocity: ExtensionNavigationController.swipeDismissVelocity,
            peakLateralVelocity: 0))
        XCTAssertFalse(ExtensionNavigationController.shouldDismissOnSwipe(
            translationY: ExtensionNavigationController.swipeDismissDistance,
            peakDownwardVelocity: ExtensionNavigationController.swipeDismissVelocity - 1,
            peakLateralVelocity: 0))
    }

    func testExitSwipeRejectsAHorizontalOrDiagonalFlick() {
        XCTAssertFalse(ExtensionNavigationController.shouldDismissOnSwipe(
            translationY: ExtensionNavigationController.swipeDismissDistance,
            peakDownwardVelocity: 1_000,
            peakLateralVelocity: 900))
    }

    func testExitSwipeIgnoresTouchesInsideAnyScrollView() {
        let scrollView = UIScrollView()
        let descendant = UIView()
        scrollView.addSubview(descendant)

        XCTAssertTrue(ExtensionNavigationController.isInsideScrollView(descendant))
        XCTAssertTrue(ExtensionNavigationController.isInsideScrollView(scrollView))
        XCTAssertFalse(ExtensionNavigationController.isInsideScrollView(UIView()))
    }

    /// The invariant the container exists for, measured through a real layout: the
    /// screen it shows is never underneath its own header bar.
    func testVisibleScreenClearsTheHeaderBar() {
        let screen = UIViewController()
        screen.title = "Header"
        let container = ExtensionNavigationController(rootViewController: screen)
        let host = hostContaining(container)
        defer { host.window.isHidden = true }

        let barBottom = container.view.convert(
            container.navigationBar.frame, to: screen.view).maxY
        XCTAssertGreaterThan(barBottom, 0, "The bar should be on screen")
        XCTAssertGreaterThanOrEqual(
            screen.view.safeAreaInsets.top, barBottom - 0.5,
            "The screen under the extension header must start below it")
    }

    /// With no bar on screen there is nothing to clear, so the container must not
    /// leave a phantom inset behind — the extension reader's own loading / saved /
    /// failure states hide the bar for exactly that reason.
    func testHiddenHeaderBarLeavesNoInset() {
        let screen = UIViewController()
        let container = ExtensionNavigationController(rootViewController: screen)
        container.setNavigationBarHidden(true, animated: false)
        let host = hostContaining(container)
        defer { host.window.isHidden = true }

        XCTAssertEqual(screen.additionalSafeAreaInsets.top, 0, accuracy: 0.001)
    }

    /// Installs `container` the way `ShareViewController` does — a child view
    /// controller pinned to the host's own view, not to its safe area.
    private func hostContaining(
        _ container: ExtensionNavigationController
    ) -> (host: UIViewController, window: UIWindow) {
        let host = UIViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.addChild(container)
        container.view.translatesAutoresizingMaskIntoConstraints = false
        host.view.addSubview(container.view)
        NSLayoutConstraint.activate([
            container.view.topAnchor.constraint(equalTo: host.view.topAnchor),
            container.view.bottomAnchor.constraint(equalTo: host.view.bottomAnchor),
            container.view.leadingAnchor.constraint(equalTo: host.view.leadingAnchor),
            container.view.trailingAnchor.constraint(equalTo: host.view.trailingAnchor),
        ])
        container.didMove(toParent: host)
        host.view.layoutIfNeeded()
        // The bar is a grandchild, so its frame lands in a later pass than the
        // host's own; the correction is applied from the container's layout.
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        return (host, window)
    }

    // MARK: - The reader under that header

    /// A freshly saved article — which is every article the action extension
    /// opens — has no position to restore. Resting at UIKit's zero would show it
    /// already scrolled by the whole top inset, with its title under the chrome.
    func testFreshOpenRestsAtTheVisualTopUnderTopChrome() throws {
        let reader = ScrollReaderViewController(item: freshItem, content: longArticle)
        reader.topChromeInset = 96
        reader.view.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        reader.loadViewIfNeeded()
        reader.view.layoutIfNeeded()

        let textView = try XCTUnwrap(findTextView(in: reader.view))
        XCTAssertEqual(textView.adjustedContentInset.top, 96, accuracy: 0.5)
        XCTAssertEqual(
            textView.contentOffset.y, -textView.adjustedContentInset.top, accuracy: 0.5,
            "A fresh article opens showing its title, not scrolled under the chrome")
    }

    /// The indicator's track must span what the reader SHOWS: from just below the
    /// top chrome to the top of the bottom safe area. Its own default mirrors the
    /// scroll view's insets, and this reader reserves a completion lane at the
    /// bottom — over a hundred points of track it would otherwise lose.
    func testScrollIndicatorTrackSpansTheVisibleReader() throws {
        let reader = ScrollReaderViewController(item: freshItem, content: longArticle)
        reader.topChromeInset = 96
        reader.view.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        reader.loadViewIfNeeded()
        reader.view.layoutIfNeeded()

        let textView = try XCTUnwrap(findTextView(in: reader.view))
        let indicator = try XCTUnwrap(findIndicator(in: reader.view))
        let insets = try XCTUnwrap(indicator.trackInsets)
        XCTAssertEqual(insets.top, 96, accuracy: 0.5, "Starts just below the top chrome")
        XCTAssertEqual(
            insets.bottom, reader.view.safeAreaInsets.bottom, accuracy: 0.5,
            "Runs down to the top of the bottom safe area")
        XCTAssertGreaterThan(
            textView.adjustedContentInset.bottom, insets.bottom + 50,
            "The reserved completion lane is exactly what must NOT shorten the track")
    }

    private var freshItem: SavedItem {
        SavedItem(
            seed: "extension-geometry", urlString: "https://example.com/extension-reader",
            title: "Extension Reader Fixture", dateAdded: Date(timeIntervalSince1970: 1_700_000_000),
            state: .ready, wordCount: 600)
    }

    private var longArticle: ArticleContent {
        let sentence = "This paragraph is long enough to exceed the progressive prefix "
            + "and make the scroll reader genuinely scroll. "
        return ArticleContent(title: "Extension Reader Fixture", blocks: [
            .init(kind: .paragraph, text: String(repeating: sentence, count: 20), links: []),
            .init(kind: .paragraph, text: String(repeating: sentence, count: 20), links: []),
            .init(kind: .paragraph, text: String(repeating: sentence, count: 20), links: []),
        ])
    }

    private func findTextView(in view: UIView) -> UITextView? {
        if let textView = view as? UITextView { return textView }
        for subview in view.subviews {
            if let found = findTextView(in: subview) { return found }
        }
        return nil
    }

    private func findIndicator(in view: UIView) -> HorizonScrollIndicator? {
        if let indicator = view as? HorizonScrollIndicator { return indicator }
        for subview in view.subviews {
            if let found = findIndicator(in: subview) { return found }
        }
        return nil
    }
}
