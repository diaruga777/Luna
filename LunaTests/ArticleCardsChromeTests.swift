//
//  ArticleCardsChromeTests.swift
//  LunaTests
//


import LunaArchiveReader
import LunaModels
import LunaStorage
import UIKit
import XCTest
@testable import Luna
@testable import LunaDesignSystem
@testable import LunaGaze
@testable import LunaReaderUI

final class ArticleCardsChromeTests: XCTestCase {

    override func tearDown() {
        SavesStore.shared.seedForTesting(items: [], contents: [:])
        super.tearDown()
    }

    func testModeSwitcherReplacesMiniCarouselOnlyDuringImmersion() throws {
        let item = SavedItem(
            seed: "bottom-mode-switcher",
            urlString: "https://example.com/bottom-mode-switcher",
            title: "Bottom Mode Switcher",
            dateAdded: Date(),
            state: .ready,
            wordCount: 480)
        let content = UITestFixtures.sampleArticleContent(title: "Bottom Mode Switcher")
        SavesStore.shared.seedForTesting(
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

    func testWideScrollCardTapExpandsToSmallScreenInsetsAndSecondTapRestores() throws {
        let controller = makeArticleController(
            seed: "wide-tap-immersion",
            title: "Wide Tap Immersion",
            size: CGSize(width: 1_024, height: 768))
        let resting = try XCTUnwrap(
            controller.carousel.restingCenteredCardFrame(in: controller.view))
        let liveCard = try XCTUnwrap(
            controller.carousel.cardView(at: controller.carousel.currentIndex))
        let animationsWereEnabled = UIView.areAnimationsEnabled
        UIView.setAnimationsEnabled(false)
        defer { UIView.setAnimationsEnabled(animationsWereEnabled) }

        controller.carousel(
            controller.carousel, didTapCenteredCardAt: controller.carousel.currentIndex)

        let expanded = liveCard.convert(liveCard.bounds, to: controller.view)
        XCTAssertTrue(controller.carousel.isImmersed)
        XCTAssertEqual(expanded.minX, 16, accuracy: 0.5)
        XCTAssertEqual(expanded.maxX, controller.view.bounds.maxX - 16, accuracy: 0.5)
        XCTAssertGreaterThan(expanded.width, resting.width)

        controller.carousel(
            controller.carousel, didTapCenteredCardAt: controller.carousel.currentIndex)

        let restored = liveCard.convert(liveCard.bounds, to: controller.view)
        XCTAssertFalse(controller.carousel.isImmersed)
        XCTAssertEqual(restored.minX, resting.minX, accuracy: 0.5)
        XCTAssertEqual(restored.width, resting.width, accuracy: 0.5)
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

    /// Dismissing the card chrome widens the card, which would run its text
    /// under the read-aloud circle's card-corner seat. Immersion parks the
    /// circle at the safe screen top-right with its usual 12pt corner inset,
    /// keeps it tappable beyond the chrome row's bounds, and returns it to the
    /// card corner with the chrome.
    func testImmersionParksReadAloudCircleAtSafeScreenCornerAndRestoresIt() throws {
        let controller = makeArticleController(seed: "audio-corner", title: "Audio Corner")
        let card = try XCTUnwrap(
            controller.carousel.restingCenteredCardFrame(in: controller.view))
        let audio = try chromeButton(labelled: "Read Aloud", in: controller)

        let animationsWereEnabled = UIView.areAnimationsEnabled
        UIView.setAnimationsEnabled(false)
        defer { UIView.setAnimationsEnabled(animationsWereEnabled) }

        controller.carousel(
            controller.carousel, didTapCenteredCardAt: controller.carousel.currentIndex)

        XCTAssertTrue(controller.carousel.isImmersed)
        let parked = audio.convert(audio.bounds, to: controller.view)
        XCTAssertEqual(parked.maxX, controller.view.bounds.maxX - 12, accuracy: 0.5)
        XCTAssertEqual(
            parked.minY, controller.view.safeAreaInsets.top + 12, accuracy: 0.5)
        let hit = controller.view.hitTest(
            CGPoint(x: parked.midX, y: parked.midY), with: nil)
        XCTAssertTrue(
            hit === audio || hit?.isDescendant(of: audio) == true,
            "the parked circle must stay tappable beyond the chrome row's bounds")

        controller.carousel(
            controller.carousel, didTapCenteredCardAt: controller.carousel.currentIndex)

        XCTAssertFalse(controller.carousel.isImmersed)
        let restored = audio.convert(audio.bounds, to: controller.view)
        XCTAssertEqual(restored.maxX, card.maxX - 12, accuracy: 0.5)
        XCTAssertEqual(restored.minY, card.minY + 12, accuracy: 0.5)
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
        NotificationCenter.default.post(name: .savesChanged, object: nil)
        XCTAssertEqual(veil.alpha, 0, accuracy: 0.001)
    }

    /// A card paged away keeps reading activity for the whole turn: the pan
    /// deliberately leaves an earlier flick's momentum alone, and the card only
    /// stops reporting when the transition settles. The deck refuses immersion
    /// for as long as the turn owns it, and this screen's own chrome — above
    /// all the footer veil, which is opaque — must refuse with it. Applied to
    /// half the state, the swipe ended on a black band over the scrub strip of
    /// a deck that was never immersed.
    @MainActor
    func testDeckPagingIgnoresImmersionReportedByTheCardItIsPagingAway() throws {
        let controller = try makePagedArticleController(seed: "page-decel")
        let carousel = controller.carousel
        let outgoing = try XCTUnwrap(
            carousel.contentController(at: carousel.currentIndex)
                as? ReaderCardContentViewController)
        let veil = try footerVeil(in: controller)
        let strip = try XCTUnwrap(
            firstSubview(of: CarouselScrubberView.self, in: carousel.view))
        let start = carousel.currentIndex

        carousel.page(by: 1)
        XCTAssertEqual(
            carousel.currentIndex, start,
            "the eclipse must be in flight — it swaps cards at its zenith, so an "
                + "index that already moved means this ran the plain jump instead")

        controller.readerCard(outgoing, didChangeImmersion: true, extendsCard: true)

        XCTAssertFalse(carousel.isImmersed)
        XCTAssertEqual(veil.alpha, 0, accuracy: 0.001)

        RunLoop.current.run(until: Date().addingTimeInterval(CardEclipseTransition.duration + 0.4))

        XCTAssertEqual(carousel.currentIndex, start + 1)
        XCTAssertFalse(carousel.isImmersed)
        XCTAssertEqual(veil.alpha, 0, accuracy: 0.001)
        XCTAssertEqual(strip.alpha, 1, accuracy: 0.001)
    }

    /// The transition exists only from the pan's first touch-move; the deck is
    /// already committed to paging one frame earlier. A reader decelerating hard
    /// reports every ~100pt of travel, so it lands in that frame often enough to
    /// be the reproduction: it faded the INCOMING card as a peek, and the card
    /// then arrived at centre invisible.
    @MainActor
    func testAcceptedPageSwipeRefusesImmersionBeforeItsTransitionExists() throws {
        let controller = try makePagedArticleController(seed: "page-gesture")
        let carousel = controller.carousel
        let card = try XCTUnwrap(
            carousel.contentController(at: carousel.currentIndex)
                as? ReaderCardContentViewController)
        let veil = try footerVeil(in: controller)
        let peek = try XCTUnwrap(carousel.cardView(at: carousel.currentIndex + 1))

        carousel.setPagingGestureForTesting(true)
        defer { carousel.setPagingGestureForTesting(false) }
        controller.readerCard(card, didChangeImmersion: true, extendsCard: true)

        XCTAssertFalse(carousel.isImmersed)
        XCTAssertEqual(veil.alpha, 0, accuracy: 0.001)
        XCTAssertEqual(peek.alpha, 1, accuracy: 0.001)
    }

    /// Immersion retires the deck's PEEKS. The card at centre is not one of
    /// them, whatever it was a moment ago — a card that faded as a peek and then
    /// became the centered card under an immersed deck used to keep its alpha of
    /// zero, leaving a black hole where the card should be.
    @MainActor
    func testCenteredCardIsVisibleUnderAnImmersedDeck() throws {
        let controller = try makePagedArticleController(seed: "immersed-centre")
        let carousel = controller.carousel
        let animationsWereEnabled = UIView.areAnimationsEnabled
        UIView.setAnimationsEnabled(false)
        defer { UIView.setAnimationsEnabled(animationsWereEnabled) }

        controller.carousel(carousel, didTapCenteredCardAt: carousel.currentIndex)
        XCTAssertTrue(carousel.isImmersed)

        let centered = try XCTUnwrap(carousel.cardView(at: carousel.currentIndex))
        // Stand in for the card's own history as a faded peek.
        centered.alpha = 0
        carousel.view.setNeedsLayout()
        carousel.view.layoutIfNeeded()

        XCTAssertEqual(centered.alpha, 1, accuracy: 0.001)
    }

    private func footerVeil(in controller: ArticleCardsViewController) throws -> UIView {
        try XCTUnwrap(
            controller.view.subviews.first {
                type(of: $0).description().contains("ReaderFooterContentFade")
            },
            "the footer veil should be mounted above the carousel")
    }

    /// A deck with room to page, in a window — the eclipse runs only on screen.
    @MainActor
    private func makePagedArticleController(
        seed: String, size: CGSize = CGSize(width: 402, height: 874)
    ) throws -> ArticleCardsViewController {
        let items = (0..<3).map { index in
            SavedItem(
                seed: "\(seed)-\(index)",
                urlString: "https://example.com/\(seed)-\(index)",
                title: "Paged Article \(index)",
                dateAdded: Date().addingTimeInterval(TimeInterval(index)),
                state: .ready,
                wordCount: 480)
        }
        var contents: [UUID: ArticleContent] = [:]
        for item in items {
            contents[item.id] = UITestFixtures.sampleArticleContent(title: item.title ?? "")
        }
        SavesStore.shared.seedForTesting(items: items, contents: contents)

        let controller = ArticleCardsViewController()
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.rootViewController = controller
        window.isHidden = false
        addTeardownBlock { window.isHidden = true }
        controller.view.layoutIfNeeded()
        controller.beginAppearanceTransition(true, animated: false)
        controller.endAppearanceTransition()
        controller.view.layoutIfNeeded()
        XCTAssertNotNil(
            controller.carousel.cardView(at: controller.carousel.currentIndex + 1),
            "these tests need a card to page to")
        return controller
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

    /// The bottom mode switcher exists only while the card chrome is dismissed,
    /// so a switch INTO RSVP always starts from an immersed deck — and RSVP's
    /// chrome state is its playback state, which on arrival is paused. Landing
    /// in a card still stretched over the footer lane, with its chrome faded
    /// out, laid the fixed speed-reader column out against a frame it does not
    /// keep. Arriving surfaces the whole deck again.
    func testSwitchingToRSVPSurfacesTheWholeCardChrome() throws {
        let controller = makeArticleController(seed: "rsvp-surfaces", title: "RSVP Surfaces")
        let modeSwitcher = try XCTUnwrap(
            controller.view.subviews.compactMap { $0 as? LunaSegmentedControl }.first)
        let animationsWereEnabled = UIView.areAnimationsEnabled
        UIView.setAnimationsEnabled(false)
        defer { UIView.setAnimationsEnabled(animationsWereEnabled) }

        controller.carousel(
            controller.carousel, didTapCenteredCardAt: controller.carousel.currentIndex)
        XCTAssertTrue(controller.carousel.isImmersed)

        modeSwitcher.selectedSegmentIndex = 1
        modeSwitcher.sendActions(for: .valueChanged)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        controller.view.layoutIfNeeded()

        let rsvp = try XCTUnwrap(firstController(of: RSVPViewController.self, under: controller))
        XCTAssertFalse(
            controller.carousel.isImmersed,
            "a paused speed reader is a surfaced card")
        XCTAssertEqual(
            modeSwitcher.alpha, 0, accuracy: 0.001,
            "the bottom lane goes back to the mini carousel with the rest of the chrome")
        let resting = try XCTUnwrap(
            controller.carousel.restingCenteredCardFrame(in: controller.view))
        let readerFrame = rsvp.view.convert(rsvp.view.bounds, to: controller.view)
        XCTAssertEqual(
            readerFrame.maxY, resting.maxY, accuracy: 0.5,
            "the speed reader lays out against the card's resting footprint")
    }

    /// The RSVP eye-tracking toggle's seat is the deck's chrome row — the
    /// card's top-left, level with the read-aloud circle on the right — and it
    /// is there exactly while the focused card renders the speed reader.
    func testEyeTrackingToggleJoinsTheChromeRowOnlyInRSVP() throws {
        GazeTrackingAvailability.supportOverride = true
        defer { GazeTrackingAvailability.supportOverride = nil }
        let controller = makeArticleController(seed: "rsvp-eye-chrome", title: "RSVP Eye Chrome")
        let modeSwitcher = try XCTUnwrap(
            controller.view.subviews.compactMap { $0 as? LunaSegmentedControl }.first)
        let row = try XCTUnwrap(
            allSubviews(in: controller.view)
                .first { $0.accessibilityIdentifier == "cards.readerChromeRow" })
        func eyeToggle() -> EyeTrackingToggleButton? {
            row.subviews.compactMap { $0 as? EyeTrackingToggleButton }.first
        }
        XCTAssertNil(eyeToggle(), "the scroll reader has no gaze to watch")

        modeSwitcher.selectedSegmentIndex = 1
        modeSwitcher.sendActions(for: .valueChanged)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        controller.view.layoutIfNeeded()

        let toggle = try XCTUnwrap(eyeToggle(), "RSVP seats its toggle in the deck's row")
        let audio = try XCTUnwrap(
            row.subviews.compactMap { $0 as? UIButton }
                .first { $0.accessibilityLabel == L10n.string("Reader_readAloudChromeAccessibilityLabel") })
        XCTAssertEqual(toggle.frame.minX, 0, accuracy: 0.5,
                       "top-left of the card: the row's leading edge (back is hidden at the root)")
        XCTAssertEqual(toggle.center.y, audio.center.y, accuracy: 0.5,
                       "level with the read-aloud circle — one row across the card's top")
        XCTAssertEqual(toggle.frame.width, audio.frame.width, accuracy: 0.5)

        modeSwitcher.selectedSegmentIndex = 0
        modeSwitcher.sendActions(for: .valueChanged)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        controller.view.layoutIfNeeded()
        XCTAssertNil(eyeToggle(), "leaving RSVP releases the toggle from the row")
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

    @MainActor
    func testCrossKindEclipseIntoReaderRevealsATitleCopy() throws {
        let installed = (
            CardKindPresenters.article,
            CardKindPresenters.media,
            CardKindPresenters.product)
        defer {
            (CardKindPresenters.article, CardKindPresenters.media,
             CardKindPresenters.product) = installed
        }
        CardKindPresenters.article = ArticleCardPresenter()
        CardKindPresenters.media = MediaCardPresenter()
        CardKindPresenters.product = ProductCardPresenter()

        let fixture = UITestState.mixed.fixture
        SavesStore.shared.seedForTesting(items: fixture.items, contents: fixture.contents)
        let items = fixture.items
        let ordered = KindDeckProvider.ordered(items)
        let readerItem = try XCTUnwrap(ordered.first {
            $0.title == "A Ready Article To Read"
        })
        let productItem = try XCTUnwrap(ordered.first { $0.priceTracker != nil })
        let readerIndex = try XCTUnwrap(ordered.firstIndex { $0.id == readerItem.id }) + 1
        let productIndex = try XCTUnwrap(ordered.firstIndex { $0.id == productItem.id }) + 1

        let controller = ArticleCardsViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = controller
        window.isHidden = false
        defer { window.isHidden = true }
        controller.view.layoutIfNeeded()
        controller.carousel.reloadData(centeringAt: productIndex)
        controller.view.layoutIfNeeded()
        XCTAssertTrue(
            controller.carousel.contentController(at: productIndex)
                is ProductCardContentViewController)

        let scrubber = try XCTUnwrap(
            firstSubview(of: CarouselScrubberView.self, in: controller.carousel.view))
        scrubber.delegate?.scrubber(scrubber, didTap: readerIndex)
        XCTAssertEqual(controller.carousel.currentIndex, productIndex)
        RunLoop.current.run(
            until: Date().addingTimeInterval(
                CardEclipseTransition.scrubberTapDuration + 0.2))

        let reader = try XCTUnwrap(
            controller.carousel.contentController(at: readerIndex)
                as? ReaderCardContentViewController)
        let title = try XCTUnwrap(readerItem.title)
        let headers = headerViews(labelled: title, in: reader.view)
        XCTAssertTrue(headers.contains { header in
            !header.isHidden && header.alpha > 0.01
                && header.convert(header.bounds, to: reader.view).intersects(reader.view.bounds)
        }, "cross-kind reveal must show one laid-out Reader title copy")
    }

    func testNonAdjacentScrubberTapStagesTitleWithItsFinalInset() throws {
        let items = (0..<4).map { index in
            SavedItem(
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
        SavesStore.shared.seedForTesting(items: items, contents: contents)

        let controller = ArticleCardsViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = controller
        window.isHidden = false
        defer { window.isHidden = true }
        controller.view.layoutIfNeeded()

        let currentContent = try XCTUnwrap(controller.carousel.contentController(at: 1))
        let currentScroll = try XCTUnwrap(firstSubview(of: UITextView.self, in: currentContent.view))
        let stableInset = currentScroll.contentInset.top
        XCTAssertGreaterThan(stableInset, 0)

        let scrubber = try XCTUnwrap(
            firstSubview(of: CarouselScrubberView.self, in: controller.carousel.view))
        scrubber.delegate?.scrubber(scrubber, didTap: 3)

        XCTAssertEqual(controller.carousel.currentIndex, 1)
        let stagedContent = try XCTUnwrap(controller.carousel.contentController(at: 3))
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

        XCTAssertEqual(controller.carousel.currentIndex, 3)
        let revealedHeaders = headerViews(labelled: "Staged Article 1", in: stagedContent.view)
        XCTAssertTrue(revealedHeaders.contains { header in
            !header.isHidden && header.alpha > 0.01
                && header.convert(header.bounds, to: stagedContent.view)
                    .intersects(stagedContent.view.bounds)
        }, "the revealed Reader must have one visible, fully laid-out title copy")

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

    @MainActor
    func testReaderCardContextMenuOffersArchiveAndDestructiveDelete() throws {
        let controller = makeArticleController(seed: "reader-card-menu", title: "Reader menu")
        let item = try XCTUnwrap(SavesStore.shared.items().first)
        // The menu comes from the one shared provider — the same code path
        // the Downloader and Price Tracker roots use for their own cards.
        let slot = try XCTUnwrap(
            controller.slotIndex(forCarouselIndex: controller.carousel.currentIndex))
        let menu = try XCTUnwrap(controller.deckProvider?.deckMenu(forSlot: slot))
        let actions = menu.children.compactMap { $0 as? UIAction }

        // A device without the curator's key gets the propose verb, above the
        // deck's own tail.
        XCTAssertEqual(
            actions.map(\.title), ["Propose Save of the Week", "Archive", "Delete"])
        let delete = try XCTUnwrap(actions.last)
        XCTAssertTrue(delete.attributes.contains(.destructive))

        delete.performWithSender(nil, target: nil)

        XCTAssertNil(SavesStore.shared.item(withID: item.id))
        XCTAssertNil(SavesStore.shared.content(for: item))
    }

    /// A save can land ready with the wrong content, so every ready card's menu
    /// carries the same chat hand-off the failed card offers
    /// (`claudedocs/llm-handoff.md`) — above Archive, because it is about the
    /// save rather than about filing it away.
    @MainActor
    func testReadyCardMenuOffersRecoverWithAIAboveArchive() throws {
        let controller = makeArticleController(seed: "reader-recover-menu", title: "Recover menu")
        let slot = try XCTUnwrap(
            controller.slotIndex(forCarouselIndex: controller.carousel.currentIndex))
        let menu = try XCTUnwrap(controller.deckProvider?.deckMenu(forSlot: slot))

        let titles = menu.children.map(\.title)
        let recoverIndex = try XCTUnwrap(titles.firstIndex(of: "Recover with AI"))
        let archiveIndex = try XCTUnwrap(titles.firstIndex(of: "Archive"))
        XCTAssertLessThan(recoverIndex, archiveIndex)

        let recover = try XCTUnwrap(menu.children[recoverIndex] as? UIMenu)
        XCTAssertEqual(
            recover.children.map(\.title), ["ChatGPT", "Claude", "Use Claude Code"])
    }

    /// An imported document has no page for a model to read again, so it is not
    /// offered the hand-off at all.
    @MainActor
    func testAnImportedDocumentCardIsNotOfferedTheHandoff() throws {
        let item = SavedItem(
            seed: "reader-recover-doc", urlString: "lunadoc://imported/notes.pdf",
            title: "Notes", dateAdded: Date(), state: .ready, wordCount: 200,
            documentType: "pdf")
        SavesStore.shared.seedForTesting(
            items: [item],
            contents: [item.id: UITestFixtures.sampleArticleContent(title: "Notes")])
        let controller = ArticleCardsViewController()
        controller.loadViewIfNeeded()

        let slot = try XCTUnwrap(
            controller.slotIndex(forCarouselIndex: controller.carousel.currentIndex))
        let menu = try XCTUnwrap(controller.deckProvider?.deckMenu(forSlot: slot))
        XCTAssertFalse(menu.children.map(\.title).contains("Recover with AI"))
    }

    func testReaderArchiveTrayOffersDeleteAndDeletesCompleteSave() throws {
        var item = SavedItem(
            seed: "reader-archive-delete",
            urlString: "https://example.com/reader-archive-delete",
            title: "Archived Reader Save", dateAdded: Date(), state: .ready,
            wordCount: 480)
        item.archivedAt = Date()
        let content = UITestFixtures.sampleArticleContent(title: "Archived Reader Save")
        SavesStore.shared.seedForTesting(
            items: [item], contents: [item.id: content])
        let controller = ArticleCardsViewController()
        controller.loadViewIfNeeded()

        let menu = try XCTUnwrap(controller.archiveTray?.contextMenuForTesting(itemAt: 0))
        let actions = menu.children.compactMap { $0 as? UIAction }
        XCTAssertEqual(actions.map(\.title), ["Unarchive", "Share", "Delete"])
        let delete = try XCTUnwrap(actions.last)
        XCTAssertTrue(delete.attributes.contains(.destructive))

        delete.performWithSender(nil, target: nil)

        XCTAssertNil(SavesStore.shared.item(withID: item.id))
        XCTAssertNil(SavesStore.shared.content(for: item))
    }

    private func makeArticleController(
        seed: String,
        title: String,
        senderName: String? = nil,
        size: CGSize = CGSize(width: 402, height: 874)
    ) -> ArticleCardsViewController {
        var item = SavedItem(
            seed: seed, urlString: "https://example.com/\(seed)", title: title,
            dateAdded: Date(), state: .ready, wordCount: 480)
        if let senderName {
            item.captureSource = .email
            item.senderName = senderName
            item.incomingSenderEmail = "sender@example.com"
        }
        let content = UITestFixtures.sampleArticleContent(title: title)
        SavesStore.shared.seedForTesting(items: [item], contents: [item.id: content])
        let controller = ArticleCardsViewController()
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(origin: .zero, size: size)
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
