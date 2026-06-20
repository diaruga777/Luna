//
//  SettingsScreenTests.swift
//  ClipTests
//
//  Snapshot + navigation coverage for the Settings menu and every subscreen.
//

import UIKit
import XCTest
@testable import Clip

final class SettingsScreenTests: XCTestCase {

    override func setUp() {
        super.setUp()
        UIView.setAnimationsEnabled(false)
    }

    // MARK: - Snapshots: top-level + every subscreen

    func testSettingsTopLevelSnapshot() {
        let nav = UINavigationController(rootViewController: SettingsViewController())
        SnapshotTesting.assertSnapshot(of: nav, named: "settings-top")
    }

    func testReaderSettingsSnapshot() {
        snapshotSubscreen(ReaderSettingsScreen(), named: "settings-reader")
    }

    func testReadingListSettingsSnapshot() {
        snapshotSubscreen(ReadingListSettingsScreen(), named: "settings-reading-list")
    }

    func testEyeTrackingSettingsSnapshot() {
        snapshotSubscreen(EyeTrackingSettingsScreen(), named: "settings-eye-tracking")
    }

    func testEmailAndKindleSettingsSnapshot() {
        snapshotSubscreen(EmailAndKindleSettingsScreen(), named: "settings-email-kindle")
    }

    func testBooxSettingsSnapshot() {
        snapshotSubscreen(BooxSettingsScreen(), named: "settings-boox")
    }

    func testMediaProviderSettingsSnapshot() {
        snapshotSubscreen(MediaProviderSettingsScreen(), named: "settings-media-provider")
    }

    func testAutoDownloadSettingsSnapshot() {
        snapshotSubscreen(AutoDownloadSettingsScreen(), named: "settings-auto-download")
    }

    func testShortcutSettingsSnapshot() {
        snapshotSubscreen(ShortcutSettingsScreen(), named: "settings-shortcut")
    }

    func testExperimentalSettingsSnapshot() {
        snapshotSubscreen(ExperimentalSettingsScreen(), named: "settings-experimental")
    }

    func testDiagnosticsSnapshot() {
        snapshotSubscreen(DiagnosticsViewController(), named: "settings-diagnostics")
    }

    func testAutoSendBySourceSnapshot() {
        let screen = AutoSendBySourceScreen(destinationID: "kindle", destinationName: "Kindle")
        snapshotSubscreen(screen, named: "settings-auto-send-by-source")
    }

    func testReplaysSnapshot() {
        snapshotSubscreen(ReplaysViewController(), named: "settings-replays")
    }

    // MARK: - Navigation: each top-level row pushes the right subscreen

    /// Drives `didSelectRowAt` for every row in section 0 and asserts the pushed
    /// view controller's class matches the expected subscreen, in order.
    func testSettingsRowsPushExpectedSubscreens() {
        let expected: [AnyClass] = [
            ReaderSettingsScreen.self,
            ReadingListSettingsScreen.self,
            EyeTrackingSettingsScreen.self,
            EmailAndKindleSettingsScreen.self,
            BooxSettingsScreen.self,
            MediaProviderSettingsScreen.self,
            AutoDownloadSettingsScreen.self,
            ShortcutSettingsScreen.self,
            ExperimentalSettingsScreen.self,
            DiagnosticsViewController.self,
        ]
        // Validate the row count once against a single instance.
        let probe = SettingsViewController()
        _ = UITestSupport.host(UINavigationController(rootViewController: probe))
        XCTAssertEqual(probe.tableView(probe.tableView, numberOfRowsInSection: 0), expected.count,
                       "settings row count drifted from the expected subscreen list")

        // Use a fresh navigation stack per row so each push is independent (avoids
        // pop timing issues in a hosted, animation-disabled stack).
        for (row, expectedClass) in expected.enumerated() {
            let settings = SettingsViewController()
            let nav = UINavigationController(rootViewController: settings)
            let window = UITestSupport.host(nav)
            settings.tableView(settings.tableView, didSelectRowAt: IndexPath(row: row, section: 0))
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            XCTAssertTrue(
                nav.topViewController?.isKind(of: expectedClass) ?? false,
                "row \(row) pushed \(String(describing: nav.topViewController)), expected \(expectedClass)")
            _ = window
        }
    }

    /// Email & Kindle and Boox both drill into the per-source auto-send screen.
    func testAutoSendDrilldownNavigation() {
        for (screen, section, row) in autoSendDrilldowns() {
            let nav = UINavigationController(rootViewController: screen)
            let window = UITestSupport.host(nav)
            (screen as UITableViewController).tableView(
                (screen as UITableViewController).tableView,
                didSelectRowAt: IndexPath(row: row, section: section))
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            XCTAssertTrue(nav.topViewController is AutoSendBySourceScreen,
                          "expected AutoSendBySourceScreen from \(type(of: screen))")
            _ = window
        }
    }

    // MARK: - Helpers

    private func autoSendDrilldowns() -> [(UITableViewController, Int, Int)] {
        // Section/row indices that push AutoSendBySourceScreen (from the VCs' source).
        // Email & Kindle: section .kindle (1), row 0. Boox: section .send (1), row 0.
        [(EmailAndKindleSettingsScreen(), 1, 0), (BooxSettingsScreen(), 1, 0)]
    }

    private func snapshotSubscreen(_ viewController: UIViewController, named name: String) {
        let nav = UINavigationController(rootViewController: viewController)
        SnapshotTesting.assertSnapshot(of: nav, named: name)
    }
}
