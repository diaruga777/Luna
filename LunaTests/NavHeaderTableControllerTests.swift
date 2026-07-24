//
//  NavHeaderTableControllerTests.swift
//  LunaTests
//

import LunaDesignSystem
import UIKit
import XCTest

/// The two ways out of a settings sub-screen. Both used to break because the
/// screens replace the navigation bar with an in-content `NavHeaderBar`: the bar
/// is a subview of the scrolling table (so section views scrolled in after it won
/// hit-testing), and hiding the real nav bar takes UIKit's left-edge pop gesture
/// with it.
@MainActor
final class NavHeaderTableControllerTests: XCTestCase {

    /// A settings-shaped screen with enough rows to scroll well past the header.
    private final class LongScreen: NavHeaderTableController {
        override func viewDidLoad() {
            headerTitle = "Long Screen"
            super.viewDidLoad()
        }
        override func numberOfSections(in tableView: UITableView) -> Int { 20 }
        override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
            3
        }
        override func tableView(
            _ tableView: UITableView, titleForHeaderInSection section: Int
        ) -> String? {
            "Section \(section)"
        }
        override func tableView(
            _ tableView: UITableView, titleForFooterInSection section: Int
        ) -> String? {
            "An explanatory footer for section \(section)."
        }
        override func tableView(
            _ tableView: UITableView, cellForRowAt indexPath: IndexPath
        ) -> UITableViewCell {
            let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
            var content = cell.defaultContentConfiguration()
            content.text = "Row \(indexPath.row)"
            cell.contentConfiguration = content
            return cell
        }
    }

    private func pushedScreen() -> (LongScreen, UINavigationController, UIWindow) {
        let root = UIViewController()
        let nav = UINavigationController(rootViewController: root)
        let window = UITestSupport.host(nav)
        let screen = LongScreen(style: .insetGrouped)
        nav.pushViewController(screen, animated: false)
        screen.loadViewIfNeeded()
        screen.view.frame = window.bounds
        screen.view.layoutIfNeeded()
        return (screen, nav, window)
    }

    /// A point inside the back chevron's hit target, in the table's coordinates.
    private func backButtonPoint(in screen: LongScreen) -> CGPoint {
        CGPoint(x: NavHeaderBar.horizontalInset + 17,
                y: screen.header.frame.maxY - NavHeaderBar.barHeight / 2)
    }

    /// Scrolls to an offset where one of the table's OWN section header/footer views
    /// covers the back button. Those are siblings of the bar inside the same scroll
    /// view, created as they scroll into range — i.e. added to `subviews` AFTER the
    /// bar — which is exactly what used to win hit-testing over it. (Cells don't:
    /// they live in a wrapper view that stays below the bar.) Settings pages are
    /// mostly section headers and long explanatory footers, so once scrolled at all,
    /// one is almost always under the bar.
    @discardableResult
    private func scrollUntilASectionViewCoversTheBackButton(_ screen: LongScreen) -> Bool {
        let table = screen.tableView!
        for offset in stride(from: CGFloat(0), through: 1200, by: 4) {
            table.contentOffset.y = offset
            table.layoutIfNeeded()
            let point = backButtonPoint(in: screen)
            let covered = table.subviews.contains {
                $0 is UITableViewHeaderFooterView && $0.frame.contains(point)
            }
            if covered { return true }
        }
        return false
    }

    func testBackButtonIsHittableAtTheTop() {
        let (screen, _, window) = pushedScreen()
        let hit = screen.tableView.hitTest(backButtonPoint(in: screen), with: nil)
        XCTAssertTrue(hit?.isDescendant(of: screen.header) == true,
                      "the header bar should own touches in its own frame")
        _ = window
    }

    func testBackButtonStaysHittableWhenScrolled() {
        let (screen, _, window) = pushedScreen()
        XCTAssertTrue(scrollUntilASectionViewCoversTheBackButton(screen),
                      "test setup: expected a section header/footer to reach the bar")

        let hit = screen.tableView.hitTest(backButtonPoint(in: screen), with: nil)
        XCTAssertTrue(hit?.isDescendant(of: screen.header) == true,
                      "a section header/footer under the bar must not swallow taps on the back button")
        XCTAssertTrue(hit is UIControl, "the hit view should be the back control itself")
        _ = window
    }

    func testPushedScreenRestoresTheInteractivePopGesture() {
        let (screen, nav, window) = pushedScreen()
        screen.viewDidAppear(false)

        guard let popGesture = nav.interactivePopGestureRecognizer else {
            XCTFail("navigation controller should provide an interactive-pop gesture"); return
        }
        XCTAssertTrue(popGesture.isEnabled)
        guard let claim = popGesture.delegate as? InteractivePopGestureClaim else {
            XCTFail("the visible screen should own the recognizer's delegate"); return
        }
        XCTAssertTrue(claim.gestureRecognizerShouldBegin(popGesture),
                      "there is something to pop back to")
        _ = window
    }

    func testRootScreenDoesNotBeginTheGestureAndOwnershipIsReturned() {
        let screen = LongScreen(style: .insetGrouped)
        let nav = UINavigationController(rootViewController: screen)
        let window = UITestSupport.host(nav)
        screen.viewDidAppear(false)

        guard let popGesture = nav.interactivePopGestureRecognizer,
              let claim = popGesture.delegate as? InteractivePopGestureClaim else {
            XCTFail("the visible screen should own the recognizer's delegate"); return
        }
        XCTAssertFalse(claim.gestureRecognizerShouldBegin(popGesture),
                       "nothing to pop back to from the root")

        screen.viewWillDisappear(false)
        XCTAssertFalse(popGesture.delegate is InteractivePopGestureClaim,
                       "ownership must go back to UIKit when the screen goes away")
        _ = window
    }
}
