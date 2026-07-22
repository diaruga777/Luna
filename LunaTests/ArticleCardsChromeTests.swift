//
//  ArticleCardsChromeTests.swift
//  LunaTests
//


import LunaDesignSystem
import LunaModels
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

        XCTAssertEqual(modeSwitcher.center.y, settings.center.y, accuracy: 0.5)
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

    private func firstSubview<T: UIView>(of type: T.Type, in root: UIView) -> T? {
        if let match = root as? T { return match }
        for subview in root.subviews {
            if let match = firstSubview(of: type, in: subview) { return match }
        }
        return nil
    }
}
