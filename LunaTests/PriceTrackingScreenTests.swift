//
//  PriceTrackingScreenTests.swift
//  LunaTests
//
//  Navigation/layout coverage for the price-tracking editor.
//

import LunaReadingListUI
@testable import LunaPriceUI
import LunaShareSurface
import LunaStorage
import LunaModels
import UIKit
import XCTest
@testable import Luna

/// Stands in for the extension host the editor hands its exit to.
@MainActor
private final class RecordingPriceEditorHost: PriceEditorScreenDelegate {
    var finishCount = 0

    func priceEditorDidFinish(_ editor: UIViewController) { finishCount += 1 }
}

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

    // MARK: - The waiting row while a fan-out is out

    /// The seller list is where the user learns Luna is still looking. Both
    /// product surfaces draw the row from the SAME fact — the tracker's pending
    /// marker — so the editor and the card can never disagree about whether a
    /// comparison is running.
    @MainActor
    func testTheEditorShowsAWaitingRowWhileAComparisonIsPendingAndDropsItAfter() {
        UITestSupport.seedSharedStore(.priceTracking)
        guard let item = SavesStore.shared.items().first(where: { $0.isPriceTracker }),
              var tracker = item.priceTracker else {
            XCTFail("no price tracker seeded"); return
        }
        let storeCount = tracker.stores.count
        tracker.beginPendingComparison(sourceURLString: tracker.stores[0].urlString)
        SavesStore.shared.updatePriceTracker(tracker, for: item.id)

        let editor = PriceTrackingViewController(mode: .existing(itemID: item.id))
        let window = UITestSupport.host(UINavigationController(rootViewController: editor))
        editor.loadViewIfNeeded()
        editor.view.layoutIfNeeded()

        XCTAssertEqual(
            editor.view.descendants(ofType: SellerRowView.self).count, storeCount,
            "one row per seller — the waiting row is not one of them")
        XCTAssertNotNil(
            editor.view.firstDescendant(ofType: UIActivityIndicatorView.self),
            "and a spinner says the fan-out is still out")

        // The run finishes; the row goes with the marker.
        guard var finished = SavesStore.shared.item(withID: item.id)?.priceTracker else {
            XCTFail("tracker vanished"); return
        }
        finished.completePendingComparison()
        SavesStore.shared.updatePriceTracker(finished, for: item.id)
        NotificationCenter.default.post(name: .savesChanged, object: nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        editor.view.layoutIfNeeded()
        XCTAssertNil(
            editor.view.firstDescendant(ofType: UIActivityIndicatorView.self),
            "and stops saying it when the run ends")
        XCTAssertEqual(editor.view.descendants(ofType: SellerRowView.self).count, storeCount)
        _ = window
    }

    @MainActor
    func testTheProductCardShowsTheSameWaitingRow() {
        UITestSupport.seedSharedStore(.priceTracking)
        guard let item = SavesStore.shared.items().first(where: { $0.isPriceTracker }),
              var tracker = item.priceTracker else {
            XCTFail("no price tracker seeded"); return
        }
        tracker.beginPendingComparison(sourceURLString: tracker.stores[0].urlString)
        SavesStore.shared.updatePriceTracker(tracker, for: item.id)

        let card = ProductCardContentViewController(itemID: item.id)
        let window = UITestSupport.host(UINavigationController(rootViewController: card))
        card.loadViewIfNeeded()
        card.view.layoutIfNeeded()
        XCTAssertNotNil(
            card.view.firstDescendant(ofType: UIActivityIndicatorView.self),
            "the card says it is still looking too")

        guard var finished = SavesStore.shared.item(withID: item.id)?.priceTracker else {
            XCTFail("tracker vanished"); return
        }
        finished.completePendingComparison()
        SavesStore.shared.updatePriceTracker(finished, for: item.id)
        NotificationCenter.default.post(name: .savesChanged, object: nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertNil(
            card.view.firstDescendant(ofType: UIActivityIndicatorView.self),
            "and stops saying it when the run ends")
        _ = window
    }

    // MARK: - Price Tracker card root

    /// One hosted deck answers both questions about the Price Tracker's root: it
    /// is the shared carousel (util card at zero, mini-card scrubber, archive
    /// tray), and its newest card — a tracker with no history points — still owns
    /// the graph and mirrors its alert as a non-editable bell marker.
    @MainActor
    func testPriceTrackerRootIsTheSharedCarouselAndKeepsThresholdOnZeroPointGraph() {
        UITestSupport.seedSharedStore(.priceTracking)
        let deck = ProductCardDeck.makeRoot()
        let window = UITestSupport.host(UINavigationController(rootViewController: deck))
        deck.view.layoutIfNeeded()

        XCTAssertEqual(deck.carousel.dataSource?.numberOfCards(in: deck.carousel), 4)
        XCTAssertTrue(deck.carousel.contentController(at: 0) is UtilCardContentViewController)
        XCTAssertNotNil(deck.archiveTray)

        // Pending Keyboard is newest: it has no history points but still owns
        // the graph and its alert marker.
        guard let content = deck.carousel.contentController(at: 1),
              let graph = findSubview(of: PriceGraphView.self, in: content.view),
              let threshold = findButton(accessibilityLabel: "Alert threshold", in: graph)
        else {
            XCTFail("zero-point price card should expose its graph alert marker")
            return
        }
        XCTAssertEqual(threshold.accessibilityValue, "$108.00")
        XCTAssertNil(threshold.currentTitle, "the graph shows only the bell, never the value")
        XCTAssertFalse(threshold.isUserInteractionEnabled, "the alert is edited by the row below")
        _ = window
    }

    // MARK: - Price tracking editor

    func testPriceTrackingEditorLayoutHasStoreList() {
        UITestSupport.seedSharedStore(.priceTracking)
        guard let tracker = SavesStore.shared.items().first(where: { $0.isPriceTracker }) else {
            XCTFail("no price tracker seeded"); return
        }
        let editor = PriceTrackingViewController(itemID: tracker.id)
        let window = UITestSupport.host(editor)
        guard let row = findSubview(of: SellerRowView.self, in: editor.view) else {
            XCTFail("price tracking editor has no seller rows"); return
        }
        LayoutAssertions.assertVisibleAndInBounds(row, in: editor.view)
        _ = window
    }

    // MARK: - Exit

    /// The price editor uses a custom Back item, which otherwise disables UIKit's
    /// stock interactive-pop recognizer. A left-edge swipe must still return a
    /// tracker opened from a root screen back to that root controller.
    func testExistingModeEnablesInteractivePopBackToSaves() {
        UITestSupport.seedSharedStore(.priceTracking)
        guard let tracker = SavesStore.shared.items().first(where: { $0.isPriceTracker }) else {
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

    /// The extension host exits through the floating glass circle every other Luna
    /// extension surface shows — NOT a header control. In-app the same editor exits
    /// through the header's Back chevron and grows no circle.
    @MainActor
    func testExtensionHostExitsByFloatingGlassButtonInAppByBack() {
        UITestSupport.seedSharedStore(.priceTracking)
        guard let tracker = SavesStore.shared.items().first(where: { $0.isPriceTracker }) else {
            XCTFail("no price tracker seeded"); return
        }
        // In-app: the header's back control pops the nav stack, and there is no
        // floating exit anywhere in the hierarchy.
        let root = UIViewController()   // stands in for whatever pushed the editor
        let nav = UINavigationController(rootViewController: root)
        let window = UITestSupport.host(nav)
        let inAppEditor = PriceTrackingViewController(mode: .creation(itemID: tracker.id, host: .inApp))
        nav.pushViewController(inAppEditor, animated: false)
        inAppEditor.loadViewIfNeeded()
        XCTAssertNil(Self.findExitButton(in: inAppEditor.view),
                     "the in-app editor keeps its Back chevron, not an extension exit circle")
        inAppEditor.perform(#selector(PriceTrackingViewController.leftButtonTapped))
        let popDeadline = Date().addingTimeInterval(2.0)
        while nav.topViewController !== root && Date() < popDeadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertTrue(nav.topViewController === root, "in-app Back pops to the pushing root")
        XCTAssertNotNil(SavesStore.shared.item(withID: tracker.id),
                        "Back must not delete the tracker")

        // Extension host: the exit is a titleless floating button that hands off to
        // the host's completion leg.
        let extEditor = PriceTrackingViewController(mode: .creation(itemID: tracker.id, host: .extension))
        let extHost = RecordingPriceEditorHost()
        extEditor.completionDelegate = extHost
        let extWindow = UITestSupport.host(extEditor)
        guard let exit = Self.findExitButton(in: extEditor.view) else {
            XCTFail("extension-hosted editor should install an ExtensionExitButton"); return
        }
        XCTAssertNil(exit.currentTitle, "the extension exit is a glyph, not a 'Done' text button")
        exit.sendActions(for: .touchUpInside)
        XCTAssertEqual(extHost.finishCount, 1, "the extension exit invokes the host's exit leg")
        _ = window
        _ = extWindow
    }

    /// The exit circle must not be laid over the seller list it shares a corner
    /// with — the content stands down to leave it room.
    @MainActor
    func testExtensionExitButtonDoesNotCoverTheSellerList() {
        UITestSupport.seedSharedStore(.priceTracking)
        guard let tracker = SavesStore.shared.items().first(where: { $0.isPriceTracker }) else {
            XCTFail("no price tracker seeded"); return
        }
        let editor = PriceTrackingViewController(mode: .creation(itemID: tracker.id, host: .extension))
        let window = UITestSupport.host(editor)
        guard let exit = Self.findExitButton(in: editor.view),
              let sellers = editor.view.firstDescendant(ofType: SellerRowView.self) else {
            XCTFail("extension-hosted editor should show an exit button and a seller row")
            return
        }
        LayoutAssertions.assertNoOverlap(
            exit.convert(exit.bounds, to: editor.view),
            sellers.convert(sellers.bounds, to: editor.view))
        // And the circle is still a circle: it used to be pulled into a 700pt
        // lozenge by the seller list's appetite for the space beneath it.
        XCTAssertEqual(exit.bounds.height, exit.bounds.width, accuracy: 1)
        _ = window
    }

    @MainActor
    func testExtensionAddSellerHandsTheExactTrackerBackToTheContainingApp() throws {
        UITestSupport.seedSharedStore(.priceTracking)
        let item = try XCTUnwrap(
            SavesStore.shared.items().first(where: { $0.isPriceTracker }))
        let handoff = RecordingAddSellerHandoff()
        let editor = PriceTrackingViewController(
            mode: .creation(itemID: item.id, host: .extension),
            addSellerHandoff: handoff)
        let window = UITestSupport.host(editor)
        let button = try XCTUnwrap(
            editor.view.descendants(ofType: UIButton.self).first {
                $0.accessibilityLabel == "Add seller"
            })
        button.sendActions(for: .touchUpInside)
        XCTAssertEqual(handoff.requestedItemIDs, [item.id])
        XCTAssertNil(editor.presentedViewController, "the extension must not host the seller webview")
        _ = window
    }

    /// The exit circle: a floating `UIButton` that is a DIRECT subview of the
    /// screen's view (the header's controls are nested inside the header bar).
    @MainActor
    private static func findExitButton(in view: UIView) -> UIButton? {
        view.subviews.compactMap { $0 as? UIButton }.first { $0.currentTitle == nil }
    }

    /// Opening an alerting tracker marks its alert viewed, so it stops floating.
    @MainActor
    func testOpeningAlertingTrackerMarksAlertViewed() {
        UITestSupport.seedSharedStore(.mixed)
        guard let alerting = SavesStore.shared.items().first(where: {
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
        let refreshed = SavesStore.shared.item(withID: alerting.id)?.priceTracker
        XCTAssertEqual(refreshed?.isAlerting, true, "still alerting after viewing")
        XCTAssertEqual(refreshed?.hasUnviewedAlert, false, "alert acknowledged on open")
        _ = window
    }

    // MARK: - No alert set yet

    /// A product tracked before the notification prompt was ever answered has no
    /// threshold, so the card's graph has no alert line or marker. The alert row
    /// below is the only editor and call to action.
    @MainActor
    func testPriceTrackerCardOffersToSetAnAlertWhenNoneIsSet() {
        UITestSupport.seedSharedStore(.priceTracking)
        clearEverySeededThreshold()
        let deck = ProductCardDeck.makeRoot()
        let window = UITestSupport.host(UINavigationController(rootViewController: deck))
        deck.view.layoutIfNeeded()

        guard let content = deck.carousel.contentController(at: 1),
              let graph = findSubview(of: PriceGraphView.self, in: content.view),
              let row = findSubview(of: AlertThresholdRow.self, in: content.view),
              let setAlert = findButton(title: "Set price alert", in: row)
        else {
            let content = deck.carousel.contentController(at: 1)
            let graph = content.flatMap { findSubview(of: PriceGraphView.self, in: $0.view) }
            XCTFail("""
                an alert-less price card should offer to set an alert in its row \
                (content: \(String(describing: content)), graph: \(String(describing: graph)))
                """)
            return
        }
        XCTAssertFalse(setAlert.isHidden)
        XCTAssertEqual(
            findButton(accessibilityLabel: "Alert threshold", in: graph)?.isHidden, true,
            "no threshold means no graph bell or line")

        setAlert.sendActions(for: .touchUpInside)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        let alerted = SavesStore.shared.items()
            .compactMap { $0.priceTracker }
            .filter { $0.hasAlertThreshold }
        XCTAssertEqual(alerted.count, 1, "only the tapped card's tracker gained an alert")
        XCTAssertEqual(
            alerted.first?.alertThresholdFraction ?? -1,
            PriceTracker.defaultAlertThresholdFraction, accuracy: 0.0001)
        _ = window
    }

    /// The other control's answer to the same state: the alert row parks its
    /// slider and shows its own call to action, which commits the default
    /// threshold.
    func testEditorAlertRowShowsCallToActionWhenNoAlertIsSet() {
        UITestSupport.seedSharedStore(.priceTracking)
        clearEverySeededThreshold()
        guard let item = SavesStore.shared.items().first(where: { $0.isPriceTracker }) else {
            XCTFail("no price tracker seeded"); return
        }
        let editor = PriceTrackingViewController(itemID: item.id)
        let window = UITestSupport.host(editor)
        guard let row = findSubview(of: AlertThresholdRow.self, in: editor.view),
              let setAlert = findButton(title: "Set price alert", in: row)
        else {
            XCTFail("the unset threshold row should carry a call to action")
            return
        }
        XCTAssertFalse(setAlert.isHidden)

        setAlert.sendActions(for: .touchUpInside)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        let tracker = SavesStore.shared.item(withID: item.id)?.priceTracker
        XCTAssertEqual(tracker?.hasAlertThreshold, true)
        XCTAssertTrue(setAlert.isHidden, "the control leaves the unset state once committed")
        _ = window
    }

    /// With a threshold set, neither editor shows the call to action — the set state
    /// is exactly what it was.
    func testEditorAlertRowHasNoCallToActionWhenAlertIsSet() {
        UITestSupport.seedSharedStore(.priceTracking)
        guard let item = SavesStore.shared.items().first(where: {
            $0.priceTracker?.hasAlertThreshold == true
        }) else {
            XCTFail("no price tracker with an alert seeded"); return
        }
        let editor = PriceTrackingViewController(itemID: item.id)
        let window = UITestSupport.host(editor)
        guard let row = findSubview(of: AlertThresholdRow.self, in: editor.view) else {
            XCTFail("the editor has no alert row"); return
        }
        XCTAssertEqual(findButton(title: "Set price alert", in: row)?.isHidden, true)
        _ = window
    }

    /// Drops every seeded tracker back to "no alert set", the state a product saved
    /// before the notification prompt was answered is created in.
    private func clearEverySeededThreshold() {
        let store = SavesStore.shared
        for item in store.items() {
            guard var tracker = item.priceTracker else { continue }
            tracker.clearAlertThreshold()
            store.updatePriceTracker(tracker, for: item.id)
        }
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

/// Type-based descendant search — the waiting row is identified by WHAT it is
/// (a spinner in a cell's accessory) rather than by a label.
private extension UIView {
    func firstDescendant<T: UIView>(ofType type: T.Type) -> T? {
        if let match = self as? T { return match }
        return subviews.lazy.compactMap { $0.firstDescendant(ofType: type) }.first
    }

    func descendants<T: UIView>(ofType type: T.Type) -> [T] {
        var found: [T] = []
        if let match = self as? T { found.append(match) }
        for subview in subviews { found += subview.descendants(ofType: type) }
        return found
    }
}

/// Records the items the editor hands back to the containing app instead of
/// opening a deep link.
final class RecordingAddSellerHandoff: AddSellerHandoffHandling {
    private(set) var requestedItemIDs: [UUID] = []

    func openContainingApp(forAddingSellerTo itemID: UUID) {
        requestedItemIDs.append(itemID)
    }
}
