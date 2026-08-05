//
//  PriceTrackingScreenTests.swift
//  LunaTests
//
//  Navigation/layout coverage for the price-tracking editor.
//

import LunaReadingListUI
import LunaPriceUI
import LunaStorage
import LunaModels
import UIKit
import XCTest
@testable import Luna

final class PriceTrackingScreenTests: XCTestCase {

    override func setUp() {
        super.setUp()
        UIView.setAnimationsEnabled(false)
    }

    override func tearDown() {
        UITestSupport.wipeSharedStore()
        super.tearDown()
    }

    // MARK: - The same product card in the central app

    /// The central Luna app draws a tracked product with the REAL editor, not a
    /// link card.
    ///
    /// This is the divergence the card-presenter refactor exists to close. The
    /// all-kinds deck used to render a tracker as a generic title-and-link card
    /// ("Tap to see price history") with a globe badge and no picture, and push a
    /// fullscreen editor on tap — while `ProductCardContentViewController` was
    /// compiled into this very binary, reachable only from the Price Tracker
    /// app's own deck subclass. One presenter per kind is what makes the two
    /// apps' answers the same answer.
    @MainActor
    func testCentralDeckBuildsTheRealProductCardNotALinkCard() {
        XCTAssertEqual(LunaApp.current, .luna, "the test host is the central app")
        UITestSupport.seedSharedStore(.priceTracking)
        let installed = CardKindPresenters.product
        defer { CardKindPresenters.product = installed }
        CardKindPresenters.product = ProductCardPresenter()

        let deck = ArticleCardsViewController()
        let window = UITestSupport.host(UINavigationController(rootViewController: deck))
        deck.view.layoutIfNeeded()

        let cards = (0..<deck.carousel.dataSource!.numberOfCards(in: deck.carousel))
            .compactMap { deck.carousel.contentController(at: $0) }
        XCTAssertTrue(
            cards.contains { $0 is ProductCardContentViewController },
            """
            the central deck built \(cards.map { type(of: $0) }) for a seeded \
            tracker — a product must get its own card here, not the reader \
            deck's link stand-in
            """)
        _ = window
    }

    // MARK: - Price Tracker card root

    /// One hosted deck answers both questions about the Price Tracker's root: it
    /// is the shared carousel (util card at zero, mini-card scrubber, archive
    /// tray), and its newest card — a tracker with no history points — still owns
    /// the graph and its editable absolute threshold.
    @MainActor
    func testPriceTrackerRootIsTheSharedCarouselAndKeepsThresholdOnZeroPointGraph() {
        UITestSupport.seedSharedStore(.priceTracking)
        let deck = ProductCardDeck.makeRoot()
        let window = UITestSupport.host(UINavigationController(rootViewController: deck))
        deck.view.layoutIfNeeded()

        XCTAssertEqual(deck.carousel.dataSource?.numberOfCards(in: deck.carousel), 4)
        if case .miniCards = deck.carousel.style.scrubberStyle {
            // expected
        } else {
            XCTFail("Price Tracker should use the same mini-card scrubber as Reader")
        }
        XCTAssertTrue(deck.carousel.contentController(at: 0) is UtilCardContentViewController)
        XCTAssertNotNil(deck.archiveTray)

        // Pending Keyboard is newest: it has no history points but still owns
        // the graph and its editable absolute threshold.
        guard let content = deck.carousel.contentController(at: 1),
              let graph = findSubview(of: PriceGraphView.self, in: content.view),
              let threshold = findButton(accessibilityLabel: "Alert threshold", in: graph)
        else {
            XCTFail("zero-point price card should expose its graph threshold")
            return
        }
        XCTAssertEqual(threshold.accessibilityValue, "$108.00")
        XCTAssertNotNil(graph.thresholdDragGestureRecognizer.view)
        _ = window
    }

    // MARK: - Price tracking editor

    func testPriceTrackingEditorLayoutHasStoreList() {
        UITestSupport.seedSharedStore(.priceTracking)
        guard let tracker = ReadingListStore.shared.items().first(where: { $0.isPriceTracker }) else {
            XCTFail("no price tracker seeded"); return
        }
        let editor = PriceTrackingViewController(itemID: tracker.id)
        let window = UITestSupport.host(editor)
        guard let table = findTableView(in: editor.view) else {
            XCTFail("price tracking editor has no table"); return
        }
        LayoutAssertions.assertVisibleAndInBounds(table, in: editor.view)
        XCTAssertGreaterThan(table.numberOfSections, 0)
        _ = window
    }

    // MARK: - Exit (Back / Read instead)

    /// Existing mode shows a Back chevron that pops back to the pushing root, and NO
    /// "Read instead" button (just viewing a saved tracker).
    func testExistingModeBackPopsAndNoReadInstead() {
        UITestSupport.seedSharedStore(.priceTracking)
        guard let tracker = ReadingListStore.shared.items().first(where: { $0.isPriceTracker }) else {
            XCTFail("no price tracker seeded"); return
        }
        let root = UIViewController()   // stands in for whatever pushed the editor
        let nav = UINavigationController(rootViewController: root)
        let window = UITestSupport.host(nav)
        let editor = PriceTrackingViewController(itemID: tracker.id)
        nav.pushViewController(editor, animated: false)
        editor.loadViewIfNeeded()
        XCTAssertTrue(nav.topViewController is PriceTrackingViewController)
        // The header controls now live in the in-content NavHeaderBar (not the nav bar);
        // exercise the same back action seam by its selector.
        editor.perform(#selector(PriceTrackingViewController.leftButtonTapped))
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertTrue(nav.topViewController === root, "Back should pop back to the pushing root")
        XCTAssertNotNil(ReadingListStore.shared.item(withID: tracker.id),
                        "Back must not delete the tracker")
        _ = window
    }

    /// The price editor uses a custom Back item, which otherwise disables UIKit's
    /// stock interactive-pop recognizer. A left-edge swipe must still return a
    /// tracker opened from a root screen back to that root controller.
    func testExistingModeEnablesInteractivePopBackToReadingList() {
        UITestSupport.seedSharedStore(.priceTracking)
        guard let tracker = ReadingListStore.shared.items().first(where: { $0.isPriceTracker }) else {
            XCTFail("no price tracker seeded"); return
        }
        let root = UIViewController()   // stands in for whatever pushed the editor
        let nav = UINavigationController(rootViewController: root)
        let window = UITestSupport.host(nav)
        let editor = PriceTrackingViewController(itemID: tracker.id)
        nav.pushViewController(editor, animated: false)
        editor.loadViewIfNeeded()
        editor.viewDidAppear(false)

        guard let popGesture = nav.interactivePopGestureRecognizer else {
            XCTFail("navigation controller should provide an interactive-pop gesture"); return
        }
        XCTAssertTrue(popGesture.delegate === editor)
        XCTAssertTrue(popGesture.isEnabled)
        XCTAssertTrue(editor.gestureRecognizerShouldBegin(popGesture))
        _ = window
    }

    /// Creation-mode "Read instead" discards the whole new tracker: the item is
    /// removed (re-saved as an article) and the screen pops.
    func testCreationModeReadInsteadDiscardsTrackerAndPops() {
        UITestSupport.seedSharedStore(.priceTracking)
        guard let tracker = ReadingListStore.shared.items().first(where: { $0.isPriceTracker }) else {
            XCTFail("no price tracker seeded"); return
        }
        let root = UIViewController()   // stands in for whatever pushed the editor
        let nav = UINavigationController(rootViewController: root)
        let window = UITestSupport.host(nav)
        let editor = PriceTrackingViewController(mode: .creation(itemID: tracker.id, host: .inApp))
        nav.pushViewController(editor, animated: false)
        editor.loadViewIfNeeded()

        // "Read instead" now lives in the in-content NavHeaderBar; drive its action seam.
        editor.perform(#selector(PriceTrackingViewController.readInsteadTapped))
        // The pop is an animated `popViewController`; under full-suite load it can need
        // more than one run-loop turn to settle, so poll (bounded) instead of a fixed wait.
        let popDeadline = Date().addingTimeInterval(2.0)
        while nav.topViewController !== root && Date() < popDeadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertTrue(nav.topViewController === root, "Read instead should pop back to the pushing root")
        XCTAssertNil(ReadingListStore.shared.item(withID: tracker.id),
                     "Read instead (creation) should drop the whole tracker save")
        _ = window
    }

    /// Merge-mode "Read instead" reverts ONLY the just-added seller, leaving the rest
    /// of the existing tracker intact, and pops.
    func testMergeModeReadInsteadRevertsOnlyAddedSeller() {
        UITestSupport.seedSharedStore(.priceTracking)
        guard let item = ReadingListStore.shared.items().first(where: { $0.isPriceTracker }),
              var tracker = item.priceTracker else {
            XCTFail("no price tracker seeded"); return
        }
        let originalURL = tracker.stores[0].urlString
        let addedURL = "https://merge-revert.example.com/product/abc"
        tracker.upsertStore(PriceTrackerStore(
            urlString: addedURL, lastPrice: 10, currency: tracker.initialCurrency, lastRefreshed: Date()))
        ReadingListStore.shared.updatePriceTracker(tracker, for: item.id)

        let root = UIViewController()   // stands in for whatever pushed the editor
        let nav = UINavigationController(rootViewController: root)
        let window = UITestSupport.host(nav)
        let editor = PriceTrackingViewController(
            mode: .merge(itemID: item.id, addedStoreURLString: addedURL, host: .inApp))
        nav.pushViewController(editor, animated: false)
        editor.loadViewIfNeeded()

        // "Read instead" now lives in the in-content NavHeaderBar; drive its action seam.
        editor.perform(#selector(PriceTrackingViewController.readInsteadTapped))
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        let after = ReadingListStore.shared.item(withID: item.id)?.priceTracker
        XCTAssertNotNil(after, "merge revert must keep the existing tracker")
        XCTAssertEqual(after?.hasStore(urlString: addedURL), false,
                       "the just-added seller should be reverted")
        XCTAssertEqual(after?.hasStore(urlString: originalURL), true,
                       "the existing seller must remain intact")
        _ = window
    }

    /// The action/share extension host exits via Done (its `onDone` completion), while
    /// in-app exits via Back (pops the nav stack). The chrome now lives in the
    /// in-content NavHeaderBar, so this verifies the exit BEHAVIOR rather than the bar
    /// item kind.
    func testExtensionHostShowsDoneInAppShowsBack() {
        UITestSupport.seedSharedStore(.priceTracking)
        guard let tracker = ReadingListStore.shared.items().first(where: { $0.isPriceTracker }) else {
            XCTFail("no price tracker seeded"); return
        }
        // In-app: left control pops the nav stack.
        let root = UIViewController()   // stands in for whatever pushed the editor
        let nav = UINavigationController(rootViewController: root)
        let window = UITestSupport.host(nav)
        let inAppEditor = PriceTrackingViewController(mode: .creation(itemID: tracker.id, host: .inApp))
        nav.pushViewController(inAppEditor, animated: false)
        inAppEditor.loadViewIfNeeded()
        inAppEditor.perform(#selector(PriceTrackingViewController.leftButtonTapped))
        let popDeadline = Date().addingTimeInterval(2.0)
        while nav.topViewController !== root && Date() < popDeadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertTrue(nav.topViewController === root, "in-app Back pops to the pushing root")

        // Extension host: left control hands off to the `onDone` completion.
        let extEditor = PriceTrackingViewController(mode: .creation(itemID: tracker.id, host: .extension))
        var didCallOnDone = false
        extEditor.onDone = { didCallOnDone = true }
        extEditor.loadViewIfNeeded()
        extEditor.perform(#selector(PriceTrackingViewController.leftButtonTapped))
        XCTAssertTrue(didCallOnDone, "extension host Done invokes the onDone completion")
        _ = window
    }

    /// Opening an alerting tracker marks its alert viewed, so it stops floating.
    @MainActor
    func testOpeningAlertingTrackerMarksAlertViewed() {
        UITestSupport.seedSharedStore(.mixed)
        guard let alerting = ReadingListStore.shared.items().first(where: {
            $0.priceTracker?.hasUnviewedAlert == true
        }) else {
            XCTFail("no unviewed-alerting tracker seeded"); return
        }
        // Acknowledging the alert is the product KIND's answer to "your card took
        // the center", so it is the same code in both apps now — there is no
        // per-deck tap seam left to drive.
        let deck = ProductCardDeck.makeRoot()
        let window = UITestSupport.host(UINavigationController(rootViewController: deck))
        deck.view.layoutIfNeeded()
        ProductCardPresenter().itemDidCenter(alerting, host: deck)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        let refreshed = ReadingListStore.shared.item(withID: alerting.id)?.priceTracker
        XCTAssertEqual(refreshed?.isAlerting, true, "still alerting after viewing")
        XCTAssertEqual(refreshed?.hasUnviewedAlert, false, "alert acknowledged on open")
        _ = window
    }

    // MARK: - No alert set yet

    /// A product tracked before the notification prompt was ever answered has no
    /// threshold, so the card's graph has no line to drag: it offers to set one, and
    /// that tap is what creates the default alert (and raises the prompt).
    @MainActor
    func testPriceTrackerCardOffersToSetAnAlertWhenNoneIsSet() {
        UITestSupport.seedSharedStore(.priceTracking)
        clearEverySeededThreshold()
        let deck = ProductCardDeck.makeRoot()
        let window = UITestSupport.host(UINavigationController(rootViewController: deck))
        deck.view.layoutIfNeeded()

        guard let content = deck.carousel.contentController(at: 1),
              let graph = findSubview(of: PriceGraphView.self, in: content.view),
              let setAlert = findButton(title: "Set price alert", in: graph)
        else {
            XCTFail("an alert-less price card should offer to set an alert")
            return
        }
        XCTAssertFalse(setAlert.isHidden)
        XCTAssertEqual(
            findButton(accessibilityLabel: "Alert threshold", in: graph)?.isHidden, true,
            "no threshold means no draggable line handle")

        setAlert.sendActions(for: .touchUpInside)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        let alerted = ReadingListStore.shared.items()
            .compactMap { $0.priceTracker }
            .filter { $0.hasAlertThreshold }
        XCTAssertEqual(alerted.count, 1, "only the tapped card's tracker gained an alert")
        XCTAssertEqual(
            alerted.first?.alertThresholdFraction, PriceTracker.defaultAlertThresholdFraction)
        _ = window
    }

    /// The other editor's answer to the same state: the slider parks and shows its
    /// own call to action, which commits the default threshold.
    func testEditorSliderShowsCallToActionWhenNoAlertIsSet() {
        UITestSupport.seedSharedStore(.priceTracking)
        clearEverySeededThreshold()
        guard let item = ReadingListStore.shared.items().first(where: { $0.isPriceTracker }) else {
            XCTFail("no price tracker seeded"); return
        }
        let editor = PriceTrackingViewController(itemID: item.id)
        let window = UITestSupport.host(editor)
        guard let slider = findSubview(of: AlertThresholdSlider.self, in: editor.view),
              let setAlert = findButton(title: "Set price alert", in: slider)
        else {
            XCTFail("the unset threshold slider should carry a call to action")
            return
        }
        XCTAssertFalse(setAlert.isHidden)

        setAlert.sendActions(for: .touchUpInside)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        let tracker = ReadingListStore.shared.item(withID: item.id)?.priceTracker
        XCTAssertEqual(tracker?.hasAlertThreshold, true)
        XCTAssertTrue(setAlert.isHidden, "the control leaves the unset state once committed")
        _ = window
    }

    /// With a threshold set, neither editor shows the call to action — the set state
    /// is exactly what it was.
    func testEditorSliderHasNoCallToActionWhenAlertIsSet() {
        UITestSupport.seedSharedStore(.priceTracking)
        guard let item = ReadingListStore.shared.items().first(where: {
            $0.priceTracker?.hasAlertThreshold == true
        }) else {
            XCTFail("no price tracker with an alert seeded"); return
        }
        let editor = PriceTrackingViewController(itemID: item.id)
        let window = UITestSupport.host(editor)
        guard let slider = findSubview(of: AlertThresholdSlider.self, in: editor.view) else {
            XCTFail("the editor has no threshold slider"); return
        }
        XCTAssertEqual(findButton(title: "Set price alert", in: slider)?.isHidden, true)
        _ = window
    }

    /// Drops every seeded tracker back to "no alert set", the state a product saved
    /// before the notification prompt was answered is created in.
    private func clearEverySeededThreshold() {
        let store = ReadingListStore.shared
        for item in store.items() {
            guard var tracker = item.priceTracker else { continue }
            tracker.clearAlertThreshold()
            store.updatePriceTracker(tracker, for: item.id)
        }
    }

    private func findTableView(in view: UIView) -> UITableView? {
        if let table = view as? UITableView { return table }
        for subview in view.subviews {
            if let found = findTableView(in: subview) { return found }
        }
        return nil
    }

    private func findSubview<T: UIView>(of type: T.Type, in view: UIView) -> T? {
        if let match = view as? T { return match }
        for subview in view.subviews {
            if let match = findSubview(of: type, in: subview) { return match }
        }
        return nil
    }

    /// By visible title — the call-to-action buttons carry copy, not a bespoke
    /// accessibility label (`UIButton.Configuration` titles reach `currentTitle`).
    private func findButton(title: String, in view: UIView) -> UIButton? {
        if let button = view as? UIButton,
           button.currentTitle == title || button.configuration?.title == title {
            return button
        }
        for subview in view.subviews {
            if let button = findButton(title: title, in: subview) { return button }
        }
        return nil
    }

    private func findButton(accessibilityLabel: String, in view: UIView) -> UIButton? {
        if let button = view as? UIButton, button.accessibilityLabel == accessibilityLabel {
            return button
        }
        for subview in view.subviews {
            if let button = findButton(accessibilityLabel: accessibilityLabel, in: subview) {
                return button
            }
        }
        return nil
    }
}
