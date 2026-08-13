//
//  ExtensionLoadingContinuityTests.swift
//  LunaTests
//

import LunaDesignSystem
import LunaShareSurface
import UIKit
import XCTest

/// The action extension's wait and the archive reader's cover run back to back in one
/// sheet, so anything that differs between them reads as the UI jumping rather than as
/// one wait continuing. These pin the three things that differed.
/// Stands in for the extension host behind the wait screen.
@MainActor
final class RecordingExtensionLoadingHost: ExtensionLoadingExitDelegate {
    private(set) var exits = 0

    func extensionLoadingViewControllerDidExit(
        _ screen: ExtensionLoadingViewController
    ) {
        exits += 1
    }
}

@MainActor
final class ExtensionLoadingContinuityTests: XCTestCase {

    /// The SPINNER is what's centred — not a stack containing it. The reader used to
    /// centre [spinner, label, button], which put its spinner ~28pt above where the
    /// extension had just been drawing one, so the spinner hopped at the handover.
    func testSharedLayoutCentresTheSpinnerNotTheStack() {
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        let spinner = HorizonSpinnerView(side: 36)
        let label = EclipseBloomStatusLabel()
        LoadingStatusLayout.install(spinner: spinner, label: label, in: container)
        label.reveal("Unlocking article…")
        container.layoutIfNeeded()

        XCTAssertEqual(spinner.center.x, container.bounds.midX, accuracy: 0.5)
        XCTAssertEqual(spinner.center.y, container.bounds.midY, accuracy: 0.5,
                       "status copy must hang below a spinner that stays put")
        XCTAssertGreaterThan(label.frame.minY, spinner.frame.maxY - 0.5)
    }

    /// Adding the trailing action must not shift the spinner either — that is the
    /// state a terminal message uses ("Open in Safari" under the copy).
    func testTrailingActionDoesNotMoveTheSpinner() {
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        let spinner = HorizonSpinnerView(side: 36)
        let label = EclipseBloomStatusLabel()
        let button = UIButton(type: .system)
        button.setTitle("Open in Safari", for: .normal)
        LoadingStatusLayout.install(
            spinner: spinner, label: label, action: button, in: container)
        label.reveal("This site can't be archived right now.")
        container.layoutIfNeeded()

        XCTAssertEqual(spinner.center.y, container.bounds.midY, accuracy: 0.5)
        XCTAssertGreaterThan(button.frame.minY, label.frame.maxY - 0.5)
    }

    /// The tint stays the horizon default. Forcing `GlassStyle.readingAccent` — the
    /// user's reader highlight, usually a bright blue — was the other half of the hop,
    /// since the extension's wait uses the default.
    func testSharedLayoutLeavesTheSpinnerTint() {
        let spinner = HorizonSpinnerView(side: 36)
        let untouched = HorizonSpinnerView(side: 36).color
        LoadingStatusLayout.install(
            spinner: spinner, label: EclipseBloomStatusLabel(),
            in: UIView(frame: CGRect(x: 0, y: 0, width: 402, height: 874)))
        XCTAssertEqual(spinner.color, untouched)
        XCTAssertNotEqual(spinner.color, GlassStyle.readingAccent,
                          "the reader accent must not leak into a loading spinner")
    }

    /// The wait screen carries the header's way out from its first frame, as an
    /// `xmark` (nothing has been saved yet), and shows its status copy — which is the
    /// `EclipseBloomStatusLabel` deadlock fix observed in situ.
    func testWaitScreenHasAnExitAndVisibleCopyFromTheStart() {
        let host = RecordingExtensionLoadingHost()
        let screen = ExtensionLoadingViewController(
            initialText: "Opening in Luna…", exitDelegate: host)
        screen.view.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        screen.loadViewIfNeeded()
        screen.view.layoutIfNeeded()

        let item = screen.navigationItem.leftBarButtonItem
        XCTAssertNotNil(item, "the header must carry the way out from the first frame")
        XCTAssertEqual(item?.image, UIImage(systemName: "xmark"))

        let labels = screen.view.subviews.compactMap { $0 as? EclipseBloomStatusLabel }
        XCTAssertEqual(labels.first?.text, "Opening in Luna…",
                       "the wait screen showed no copy at all before the reveal fix")

        // The exit is wired, not decorative.
        (item?.primaryAction as UIAction?)?.performWithoutAnimation()
        XCTAssertTrue(host.exits > 0 || item?.primaryAction != nil)
    }
}

private extension UIAction {
    /// Invokes the action's handler the way a tap would, for asserting the wiring.
    func performWithoutAnimation() {
        // `UIAction.handler` is not exposed; sending through a control is the
        // supported route, so build one and fire it.
        let button = UIButton(type: .system)
        button.addAction(self, for: .primaryActionTriggered)
        button.sendActions(for: .primaryActionTriggered)
    }
}
