//
//  ArticleCardsChromeTests.swift
//  LunaTests
//


import LunaArchiveReader
import LunaDesignSystem
import LunaModels
import LunaReaderUI
import LunaStorage
import UIKit
import XCTest
@testable import Luna

final class ArticleCardsChromeTests: XCTestCase {

    override func tearDown() {
        ReadingListStore.shared.seedForTesting(items: [], contents: [:])
        super.tearDown()
    }

    func testModeSwitcherReplacesMiniCarouselOnlyDuringImmersion() throws {
        let item = ReadingListItem(
            seed: "bottom-mode-switcher",
            urlString: "https://example.com/bottom-mode-switcher",
            title: "Bottom Mode Switcher",
            dateAdded: Date(),
            state: .ready,
            wordCount: 480)
        let content = UITestFixtures.sampleArticleContent(title: "Bottom Mode Switcher")
        ReadingListStore.shared.seedForTesting(
            items: [item], contents: [item.id: content])

        let controller = ArticleCardsViewController()
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        controller.beginAppearanceTransition(true, animated: false)
        controller.endAppearanceTransition()
        controller.view.layoutIfNeeded()

        let modeSwitcher = try XCTUnwrap(
            controller.view.subviews.compactMap { $0 as? LunaSegmentedControl }.first)
        let miniCarousel = try XCTUnwrap(
            firstSubview(of: CarouselScrubberView.self, in: controller.carousel.view))
        let settings = try XCTUnwrap(controller.view.subviews.compactMap { $0 as? UIButton }
            .first { $0.accessibilityLabel == "Settings" })
        let share = try XCTUnwrap(controller.view.subviews.compactMap { $0 as? UIButton }
            .first { $0.accessibilityLabel == "Share" })

        XCTAssertEqual(modeSwitcher.center.y, settings.center.y, accuracy: 0.5)
        XCTAssertEqual(miniCarousel.frame.minX, settings.frame.maxX, accuracy: 0.5)
        XCTAssertEqual(miniCarousel.frame.maxX, share.frame.minX, accuracy: 0.5)
        XCTAssertTrue(allSubviews(in: miniCarousel).allSatisfy { !($0 is UIVisualEffectView) })
        XCTAssertGreaterThan(modeSwitcher.frame.minY, controller.view.bounds.midY)
        XCTAssertEqual(modeSwitcher.alpha, 0, accuracy: 0.001)
        XCTAssertFalse(modeSwitcher.isUserInteractionEnabled)
        XCTAssertEqual(miniCarousel.alpha, 1, accuracy: 0.001)
        XCTAssertEqual(miniCarousel.transform, .identity)

        let animationsWereEnabled = UIView.areAnimationsEnabled
        UIView.setAnimationsEnabled(false)
        defer { UIView.setAnimationsEnabled(animationsWereEnabled) }

        controller.carousel(controller.carousel, didTapCenteredCardAt: 0)

        XCTAssertTrue(controller.carousel.isImmersed)
        XCTAssertEqual(modeSwitcher.alpha, 1, accuracy: 0.001)
        XCTAssertTrue(modeSwitcher.isUserInteractionEnabled)
        XCTAssertEqual(modeSwitcher.transform, .identity)
        XCTAssertEqual(miniCarousel.alpha, 0, accuracy: 0.001)
        XCTAssertEqual(miniCarousel.transform.ty, 8, accuracy: 0.001)

        controller.carousel(controller.carousel, didTapCenteredCardAt: 0)

        XCTAssertFalse(controller.carousel.isImmersed)
        XCTAssertEqual(modeSwitcher.alpha, 0, accuracy: 0.001)
        XCTAssertFalse(modeSwitcher.isUserInteractionEnabled)
        XCTAssertEqual(modeSwitcher.transform.ty, 8, accuracy: 0.001)
        XCTAssertEqual(miniCarousel.alpha, 1, accuracy: 0.001)
        XCTAssertEqual(miniCarousel.transform, .identity)
    }

    func testScrollableTitleCopyKeepsInsetStableAndCentersFaviconBesideMultilineTitle() throws {
        let title = "A deliberately long article title that wraps across multiple header lines"
        let controller = makeArticleController(seed: "stable-title", title: title)
        let textView = try XCTUnwrap(firstSubview(of: UITextView.self, in: controller.view))
        let headers = headerViews(labelled: title, in: controller.view)
        let pinned = try XCTUnwrap(headers.first { !hasScrollViewAncestor($0) })
        let scrolling = try XCTUnwrap(headers.first { hasScrollViewAncestor($0) })
        let icon = try XCTUnwrap(firstSubview(of: UIImageView.self, in: pinned))
        let label = try XCTUnwrap(firstSubview(of: UILabel.self, in: pinned))

        XCTAssertGreaterThan(label.frame.height, label.font.lineHeight)
        XCTAssertEqual(icon.frame.midY, label.frame.midY, accuracy: 0.5)
        XCTAssertEqual(pinned.frame.minY, 0, accuracy: 0.5)
        XCTAssertEqual(pinned.alpha, 0, accuracy: 0.001)
        let pinnedFrame = pinned.convert(pinned.bounds, to: controller.view)
        let scrollingFrame = scrolling.convert(scrolling.bounds, to: controller.view)
        XCTAssertEqual(pinnedFrame.minX, scrollingFrame.minX, accuracy: 0.5)
        XCTAssertEqual(pinnedFrame.minY, scrollingFrame.minY, accuracy: 0.5)
        XCTAssertEqual(pinnedFrame.width, scrollingFrame.width, accuracy: 0.5)
        XCTAssertEqual(pinnedFrame.height, scrollingFrame.height, accuracy: 0.5)

        let stableInset = textView.contentInset.top
        let animationsWereEnabled = UIView.areAnimationsEnabled
        UIView.setAnimationsEnabled(false)
        defer { UIView.setAnimationsEnabled(animationsWereEnabled) }

        textView.setContentOffset(
            CGPoint(x: 0, y: -textView.adjustedContentInset.top + 40), animated: false)
        XCTAssertEqual(pinned.alpha, 1, accuracy: 0.001)
        controller.carousel(controller.carousel, didTapCenteredCardAt: 0)

        XCTAssertTrue(controller.carousel.isImmersed)
        XCTAssertEqual(pinned.alpha, 0, accuracy: 0.001)
        XCTAssertEqual(textView.contentInset.top, stableInset, accuracy: 0.5)
    }

    func testRSVPTitleRemainsFixedWhenCardChromeIsDismissed() throws {
        let title = "RSVP Stable Title"
        let controller = makeArticleController(seed: "rsvp-title", title: title)
        let modeSwitcher = try XCTUnwrap(
            controller.view.subviews.compactMap { $0 as? LunaSegmentedControl }.first)
        modeSwitcher.selectedSegmentIndex = 1
        modeSwitcher.sendActions(for: .valueChanged)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        controller.view.layoutIfNeeded()

        let rsvp = try XCTUnwrap(firstController(of: RSVPViewController.self, under: controller))
        let pinned = try XCTUnwrap(
            headerViews(labelled: title, in: controller.view).first { !hasScrollViewAncestor($0) })
        let headerFrame = pinned.frame
        let readerFrame = rsvp.view.frame
        let topInset = rsvp.topContentInset
        let animationsWereEnabled = UIView.areAnimationsEnabled
        UIView.setAnimationsEnabled(false)
        defer { UIView.setAnimationsEnabled(animationsWereEnabled) }

        controller.carousel(controller.carousel, didTapCenteredCardAt: 0)

        XCTAssertTrue(controller.carousel.isImmersed)
        XCTAssertEqual(pinned.alpha, 1, accuracy: 0.001)
        XCTAssertEqual(pinned.frame, headerFrame)
        XCTAssertEqual(rsvp.view.frame, readerFrame)
        XCTAssertEqual(rsvp.topContentInset, topInset, accuracy: 0.5)
    }

    func testWebArchiveTitleLivesInItsScrollContentAndUsesStableInset() throws {
        let title = "Archived Page Title"
        let controller = makeArticleController(seed: "archive-title", title: title)
        let modeSwitcher = try XCTUnwrap(
            controller.view.subviews.compactMap { $0 as? LunaSegmentedControl }.first)
        modeSwitcher.selectedSegmentIndex = 2
        modeSwitcher.sendActions(for: .valueChanged)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        controller.view.layoutIfNeeded()

        let original = try XCTUnwrap(
            firstController(of: OriginalPageViewController.self, under: controller))
        let scroll = original.contentScrollView
        let headers = headerViews(labelled: title, in: controller.view)
        let pinned = try XCTUnwrap(headers.first { !hasScrollViewAncestor($0) })
        let scrolling = try XCTUnwrap(headers.first { hasScrollViewAncestor($0) })
        XCTAssertTrue(scrolling.superview === scroll)
        let stableInset = scroll.contentInset.top
        XCTAssertGreaterThan(stableInset, 0)

        let animationsWereEnabled = UIView.areAnimationsEnabled
        UIView.setAnimationsEnabled(false)
        defer { UIView.setAnimationsEnabled(animationsWereEnabled) }
        scroll.setContentOffset(
            CGPoint(x: 0, y: -scroll.adjustedContentInset.top + 40), animated: false)
        XCTAssertEqual(pinned.alpha, 1, accuracy: 0.001)

        controller.carousel(controller.carousel, didTapCenteredCardAt: 0)

        XCTAssertTrue(controller.carousel.isImmersed)
        XCTAssertEqual(pinned.alpha, 0, accuracy: 0.001)
        XCTAssertEqual(scroll.contentInset.top, stableInset, accuracy: 0.5)
    }

    private func makeArticleController(seed: String, title: String) -> ArticleCardsViewController {
        let item = ReadingListItem(
            seed: seed, urlString: "https://example.com/\(seed)", title: title,
            dateAdded: Date(), state: .ready, wordCount: 480)
        let content = UITestFixtures.sampleArticleContent(title: title)
        ReadingListStore.shared.seedForTesting(items: [item], contents: [item.id: content])
        let controller = ArticleCardsViewController()
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        controller.beginAppearanceTransition(true, animated: false)
        controller.endAppearanceTransition()
        controller.view.layoutIfNeeded()
        return controller
    }

    private func headerViews(labelled title: String, in root: UIView) -> [UIView] {
        ([root] + allSubviews(in: root)).filter {
            $0.accessibilityLabel == title && $0.accessibilityTraits.contains(.header)
        }
    }

    private func hasScrollViewAncestor(_ view: UIView) -> Bool {
        var ancestor = view.superview
        while let current = ancestor {
            if current is UIScrollView { return true }
            ancestor = current.superview
        }
        return false
    }

    private func firstController<T: UIViewController>(
        of type: T.Type, under root: UIViewController
    ) -> T? {
        if let match = root as? T { return match }
        return root.children.lazy.compactMap { self.firstController(of: type, under: $0) }.first
    }

    private func firstSubview<T: UIView>(of type: T.Type, in root: UIView) -> T? {
        if let match = root as? T { return match }
        for subview in root.subviews {
            if let match = firstSubview(of: type, in: subview) { return match }
        }
        return nil
    }

    private func allSubviews(in root: UIView) -> [UIView] {
        root.subviews + root.subviews.flatMap { allSubviews(in: $0) }
    }
}
