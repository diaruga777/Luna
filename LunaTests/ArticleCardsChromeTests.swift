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

        controller.carousel(
            controller.carousel, didTapCenteredCardAt: controller.carousel.currentIndex)

        XCTAssertTrue(controller.carousel.isImmersed)
        XCTAssertEqual(modeSwitcher.alpha, 1, accuracy: 0.001)
        XCTAssertTrue(modeSwitcher.isUserInteractionEnabled)
        XCTAssertEqual(modeSwitcher.transform, .identity)
        XCTAssertEqual(miniCarousel.alpha, 0, accuracy: 0.001)
        XCTAssertEqual(miniCarousel.transform.ty, 8, accuracy: 0.001)

        controller.carousel(
            controller.carousel, didTapCenteredCardAt: controller.carousel.currentIndex)

        XCTAssertFalse(controller.carousel.isImmersed)
        XCTAssertEqual(modeSwitcher.alpha, 0, accuracy: 0.001)
        XCTAssertFalse(modeSwitcher.isUserInteractionEnabled)
        XCTAssertEqual(modeSwitcher.transform.ty, 8, accuracy: 0.001)
        XCTAssertEqual(miniCarousel.alpha, 1, accuracy: 0.001)
        XCTAssertEqual(miniCarousel.transform, .identity)
    }

    /// The read-aloud and back circles belong to the CARD's top corners, not the
    /// screen's: the card sits `peek + edgeGap` inside the screen edges, so
    /// screen-relative insets left them straddling its rim (half the circle
    /// outside the card on both axes).
    func testTopChromeCirclesSitInsideTheCenteredCardsTopCorners() throws {
        let controller = makeArticleController(seed: "top-chrome", title: "Top Chrome")
        let card = try XCTUnwrap(
            controller.carousel.restingCenteredCardFrame(in: controller.view))
        let audio = try chromeButton(labelled: "Read Aloud", in: controller)
        let back = try chromeButton(labelled: "Back", in: controller)
        let audioFrame = audio.convert(audio.bounds, to: controller.view)
        let backFrame = back.convert(back.bounds, to: controller.view)

        XCTAssertEqual(audioFrame.maxX, card.maxX - 12, accuracy: 0.5)
        XCTAssertEqual(audioFrame.minY, card.minY + 12, accuracy: 0.5)
        XCTAssertEqual(backFrame.minX, card.minX + 12, accuracy: 0.5)
        XCTAssertEqual(backFrame.minY, card.minY + 12, accuracy: 0.5)
        XCTAssertTrue(
            card.insetBy(dx: -0.5, dy: -0.5).contains(audioFrame),
            "the circle must be wholly inside the card, not over its edge")
        XCTAssertTrue(card.insetBy(dx: -0.5, dy: -0.5).contains(backFrame))
    }

    /// The glass configuration is a capsule, so the circles are only round while
    /// they stay square — a width free to follow the glyph turned read-aloud
    /// into an oval the moment the wider `speaker.wave.2` was swapped in.
    func testTopChromeCirclesStaySquareThroughTheWidestGlyph() throws {
        let controller = makeArticleController(seed: "chrome-circle", title: "Chrome Circle")
        let audio = try chromeButton(labelled: "Read Aloud", in: controller)

        XCTAssertEqual(audio.frame.width, audio.frame.height, accuracy: 0.5)
        XCTAssertEqual(audio.frame.width, 38, accuracy: 0.5)

        audio.setImage(UIImage(systemName: "speaker.wave.2"), for: .normal)
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()

        XCTAssertEqual(audio.frame.width, audio.frame.height, accuracy: 0.5)
        XCTAssertEqual(audio.frame.width, 38, accuracy: 0.5)
    }

    /// The footer veil is the one screen-level view that covers the scrub strip
    /// and nothing above it, and it is raised only from the immersion callbacks
    /// — so a card torn down while immersed strands it opaque and the strip
    /// reads as blacked out. An un-immersed deck must never carry it.
    func testFooterVeilCannotOutliveImmersionOverTheScrubStrip() throws {
        let controller = makeArticleController(seed: "footer-veil", title: "Footer Veil")
        let strip = try XCTUnwrap(
            firstSubview(of: CarouselScrubberView.self, in: controller.carousel.view))
        let veil = try XCTUnwrap(
            controller.view.subviews.first {
                type(of: $0).description().contains("ReaderFooterContentFade")
            },
            "the footer veil should be mounted above the carousel")
        let stripFrame = strip.convert(strip.bounds, to: controller.view)
        let veilFrame = veil.convert(veil.bounds, to: controller.view)

        XCTAssertTrue(
            veilFrame.intersects(stripFrame),
            "this test is only meaningful while the veil spans the strip's band")
        XCTAssertFalse(controller.carousel.isImmersed)
        XCTAssertEqual(veil.alpha, 0, accuracy: 0.001)

        // Strand it the way a teardown mid-immersion does, then hand the deck
        // either of the two beats that cannot coincide with an immersion
        // animation.
        veil.alpha = 1
        controller.beginAppearanceTransition(true, animated: false)
        controller.endAppearanceTransition()
        XCTAssertEqual(veil.alpha, 0, accuracy: 0.001)

        veil.alpha = 1
        NotificationCenter.default.post(name: .readingListChanged, object: nil)
        XCTAssertEqual(veil.alpha, 0, accuracy: 0.001)
    }

    /// Scoped to the deck's own chrome row: the card's nested reader carries
    /// buttons with the same labels (hidden while the row drives them).
    private func chromeButton(
        labelled label: String, in controller: ArticleCardsViewController
    ) throws -> UIButton {
        let row = try XCTUnwrap(
            allSubviews(in: controller.view)
                .first { $0.accessibilityIdentifier == "cards.readerChromeRow" },
            "the deck's screen-level chrome row should be mounted")
        return try XCTUnwrap(
            row.subviews.compactMap { $0 as? UIButton }
                .first { $0.accessibilityLabel == label },
            "the \(label) chrome circle should be mounted")
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
        XCTAssertEqual(pinned.alpha, 0, accuracy: 0.001)
        textView.setContentOffset(
            CGPoint(
                x: 0,
                y: -textView.adjustedContentInset.top + scrolling.bounds.height + 2),
            animated: false)
        XCTAssertEqual(pinned.alpha, 1, accuracy: 0.001)
        controller.carousel(
            controller.carousel, didTapCenteredCardAt: controller.carousel.currentIndex)

        XCTAssertTrue(controller.carousel.isImmersed)
        XCTAssertEqual(pinned.alpha, 0, accuracy: 0.001)
        XCTAssertEqual(textView.contentInset.top, stableInset, accuracy: 0.5)
    }

    func testScrollableTitleUsesCardWidthWhileReaderBoundsAreStillProvisional() throws {
        let title = "A deliberately long title whose line breaks expose provisional reader width"
        let controller = makeArticleController(seed: "provisional-title-width", title: title)
        let content = try XCTUnwrap(
            controller.carousel.contentController(at: controller.carousel.currentIndex))
        let textView = try XCTUnwrap(firstSubview(of: UITextView.self, in: content.view))
        let headers = headerViews(labelled: title, in: content.view)
        let pinned = try XCTUnwrap(headers.first { !hasScrollViewAncestor($0) })
        let scrolling = try XCTUnwrap(headers.first { hasScrollViewAncestor($0) })

        // The nested reader can still report its old, screen-wide bounds during
        // the card's parent layout pass. The title must already use the card's
        // final width rather than visibly re-wrap on the following pass.
        textView.bounds.size.width = content.view.bounds.width + 80
        content.view.setNeedsLayout()
        content.view.layoutIfNeeded()

        XCTAssertEqual(scrolling.bounds.width, pinned.bounds.width, accuracy: 0.5)
        let pinnedLabel = try XCTUnwrap(firstSubview(of: UILabel.self, in: pinned))
        let scrollingLabel = try XCTUnwrap(firstSubview(of: UILabel.self, in: scrolling))
        XCTAssertEqual(scrollingLabel.bounds.width, pinnedLabel.bounds.width, accuracy: 0.5)
        XCTAssertEqual(scrollingLabel.bounds.height, pinnedLabel.bounds.height, accuracy: 0.5)
    }

    func testIncomingSenderAppearsBelowTitleWithoutOverlappingIt() throws {
        let title = "An emailed article"
        let controller = makeArticleController(
            seed: "sender-title", title: title, senderName: "Ada Lovelace")
        let pinned = try XCTUnwrap(
            headerViews(labelled: title, in: controller.view).first { !hasScrollViewAncestor($0) })
        let labels = allSubviews(in: pinned).compactMap { $0 as? UILabel }
        let titleLabel = try XCTUnwrap(labels.first { $0.text == title })
        let senderLabel = try XCTUnwrap(labels.first { $0.text == "From Ada Lovelace" })

        XCTAssertGreaterThanOrEqual(senderLabel.frame.minY, titleLabel.frame.maxY)
        XCTAssertLessThanOrEqual(senderLabel.frame.maxY, pinned.bounds.maxY)
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

        controller.carousel(
            controller.carousel, didTapCenteredCardAt: controller.carousel.currentIndex)

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
        XCTAssertEqual(pinned.alpha, 0, accuracy: 0.001)
        scroll.setContentOffset(
            CGPoint(
                x: 0,
                y: -scroll.adjustedContentInset.top + scrolling.bounds.height + 2),
            animated: false)
        XCTAssertEqual(pinned.alpha, 1, accuracy: 0.001)

        controller.carousel(
            controller.carousel, didTapCenteredCardAt: controller.carousel.currentIndex)

        XCTAssertTrue(controller.carousel.isImmersed)
        XCTAssertEqual(pinned.alpha, 0, accuracy: 0.001)
        XCTAssertEqual(scroll.contentInset.top, stableInset, accuracy: 0.5)
    }

    func testNonAdjacentScrubberTapStagesTitleWithItsFinalInset() throws {
        let items = (0..<4).map { index in
            ReadingListItem(
                seed: "staged-title-\(index)",
                urlString: "https://example.com/staged-title-\(index)",
                title: "Staged Article \(index)",
                dateAdded: Date().addingTimeInterval(TimeInterval(index)),
                state: .ready,
                wordCount: 480)
        }
        let contents = Dictionary(uniqueKeysWithValues: items.map { item in
            (item.id, UITestFixtures.sampleArticleContent(title: item.title ?? "Staged Article"))
        })
        ReadingListStore.shared.seedForTesting(items: items, contents: contents)

        let controller = ArticleCardsViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = controller
        window.isHidden = false
        defer { window.isHidden = true }
        controller.view.layoutIfNeeded()

        let currentContent = try XCTUnwrap(controller.carousel.contentController(at: 0))
        let currentScroll = try XCTUnwrap(firstSubview(of: UITextView.self, in: currentContent.view))
        let stableInset = currentScroll.contentInset.top
        XCTAssertGreaterThan(stableInset, 0)

        let scrubber = try XCTUnwrap(
            firstSubview(of: CarouselScrubberView.self, in: controller.carousel.view))
        scrubber.delegate?.scrubber(scrubber, didTap: 2)

        XCTAssertEqual(controller.carousel.currentIndex, 0)
        let stagedContent = try XCTUnwrap(controller.carousel.contentController(at: 2))
        stagedContent.view.layoutIfNeeded()
        let stagedScroll = try XCTUnwrap(firstSubview(of: UITextView.self, in: stagedContent.view))
        XCTAssertEqual(stagedScroll.contentInset.top, stableInset, accuracy: 0.5)
        let stagedHeader = try XCTUnwrap(
            ([stagedContent.view] + allSubviews(in: stagedContent.view)).first {
                $0.accessibilityTraits.contains(.header)
            })
        XCTAssertGreaterThan(stagedHeader.bounds.height, 0)

        RunLoop.current.run(
            until: Date().addingTimeInterval(
                CardEclipseTransition.scrubberTapDuration + 0.2))

        let hostedIndicator = try XCTUnwrap(
            controller.view.subviews.compactMap { $0 as? HorizonScrollIndicator }.first)
        XCTAssertEqual(hostedIndicator.alpha, 0, accuracy: 0.001)
    }

    func testProgrammaticScrollDoesNotFlashHorizonIndicator() {
        let scrollView = UIScrollView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        scrollView.contentSize = CGSize(width: 320, height: 1_200)
        let indicator = HorizonScrollIndicator.makeHosted()
        indicator.frame = scrollView.bounds
        indicator.track(scrollView)
        indicator.layoutIfNeeded()

        scrollView.setContentOffset(CGPoint(x: 0, y: 240), animated: false)
        indicator.layoutIfNeeded()

        XCTAssertEqual(indicator.alpha, 0, accuracy: 0.001)
    }

    func testArchiveArcFadesWithCardChromeDuringImmersion() throws {
        let controller = makeArticleController(seed: "archive-arc-chrome", title: "Arc Chrome")
        let tray = try XCTUnwrap(controller.archiveTray)
        XCTAssertEqual(tray.trayAlphaForTesting, 1, accuracy: 0.001)

        let animationsWereEnabled = UIView.areAnimationsEnabled
        UIView.setAnimationsEnabled(false)
        defer { UIView.setAnimationsEnabled(animationsWereEnabled) }

        controller.carousel(
            controller.carousel, didTapCenteredCardAt: controller.carousel.currentIndex)
        XCTAssertTrue(controller.carousel.isImmersed)
        XCTAssertEqual(tray.trayAlphaForTesting, 0, accuracy: 0.001)

        controller.carousel(
            controller.carousel, didTapCenteredCardAt: controller.carousel.currentIndex)
        XCTAssertFalse(controller.carousel.isImmersed)
        XCTAssertEqual(tray.trayAlphaForTesting, 1, accuracy: 0.001)
    }

    func testReaderCardContextMenuOffersArchiveAndDestructiveDelete() throws {
        let controller = makeArticleController(seed: "reader-card-menu", title: "Reader menu")
        let item = try XCTUnwrap(ReadingListStore.shared.items().first)
        let menu = try XCTUnwrap(
            controller.cardContextMenuForTesting(at: controller.carousel.currentIndex))
        let actions = menu.children.compactMap { $0 as? UIAction }

        XCTAssertEqual(actions.map(\.title), ["Archive", "Delete"])
        let delete = try XCTUnwrap(actions.last)
        XCTAssertTrue(delete.attributes.contains(.destructive))

        delete.performWithSender(nil, target: nil)

        XCTAssertNil(ReadingListStore.shared.item(withID: item.id))
        XCTAssertNil(ReadingListStore.shared.content(for: item))
    }

    func testReaderArchiveTrayOffersDeleteAndDeletesCompleteSave() throws {
        var item = ReadingListItem(
            seed: "reader-archive-delete",
            urlString: "https://example.com/reader-archive-delete",
            title: "Archived Reader Save", dateAdded: Date(), state: .ready,
            wordCount: 480)
        item.archivedAt = Date()
        let content = UITestFixtures.sampleArticleContent(title: "Archived Reader Save")
        ReadingListStore.shared.seedForTesting(
            items: [item], contents: [item.id: content])
        let controller = ArticleCardsViewController()
        controller.loadViewIfNeeded()

        let menu = try XCTUnwrap(controller.archiveTray?.contextMenuForTesting(itemAt: 0))
        let actions = menu.children.compactMap { $0 as? UIAction }
        XCTAssertEqual(actions.map(\.title), ["Unarchive", "Share", "Delete"])
        let delete = try XCTUnwrap(actions.last)
        XCTAssertTrue(delete.attributes.contains(.destructive))

        delete.performWithSender(nil, target: nil)

        XCTAssertNil(ReadingListStore.shared.item(withID: item.id))
        XCTAssertNil(ReadingListStore.shared.content(for: item))
    }

    private func makeArticleController(
        seed: String, title: String, senderName: String? = nil
    ) -> ArticleCardsViewController {
        var item = ReadingListItem(
            seed: seed, urlString: "https://example.com/\(seed)", title: title,
            dateAdded: Date(), state: .ready, wordCount: 480)
        if let senderName {
            item.captureSource = .email
            item.channelName = senderName
            item.incomingSenderEmail = "sender@example.com"
        }
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
