//
//  SettingsScreenTests.swift
//  LunaTests
//
//  Snapshot + navigation coverage for the Settings menu and every subscreen.
//

import LunaReadingListUI
import UIKit
import XCTest
@testable import Luna

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

    func testEmailAndKindleSettingsSnapshot() {
        snapshotSubscreen(EmailAndKindleSettingsScreen(), named: "settings-email-kindle")
    }

    func testMediaProviderSettingsSnapshot() {
        snapshotSubscreen(MediaProviderSettingsScreen(), named: "settings-media-provider")
    }

    func testAutoDownloadSettingsSnapshot() {
        snapshotSubscreen(AutoDownloadSettingsScreen(), named: "settings-auto-download")
    }

    func testShortcutSettingsSnapshot() {
        guard #available(iOS 27.0, *) else { return }
        snapshotSubscreen(ShortcutSettingsScreen(), named: "settings-shortcut")
    }

    func testAppearanceSettingsSnapshot() {
        snapshotSubscreen(AppearanceSettingsScreen(), named: "settings-appearance")
    }

    func testExperimentalSettingsSnapshot() {
        snapshotSubscreen(ExperimentalSettingsScreen(), named: "settings-experimental")
    }

    // Note: DiagnosticsViewController renders the device's live diagnostic log (entries
    // with wall-clock timestamps) — not pixel-stable, so (like ReplaysViewController) it's
    // covered by an instantiation/layout assertion rather than a snapshot. It previously
    // "passed" as a snapshot only because the old nav-bar header left the log content
    // uncaptured by the rasterizer; with the header now in-content the log is captured.
    func testDiagnosticsScreenLayoutSane() {
        let diagnostics = DiagnosticsViewController()
        let nav = UINavigationController(rootViewController: diagnostics)
        let window = UITestSupport.host(nav)
        LayoutAssertions.assertVisibleAndInBounds(diagnostics.textView, in: diagnostics.view)
        _ = window
    }

    func testAutoSendBySourceSnapshot() {
        let screen = AutoSendBySourceScreen(destinationID: "kindle", destinationName: "Kindle")
        snapshotSubscreen(screen, named: "settings-auto-send-by-source")
    }

    // Note: ReplaysViewController lists the device's real accumulated diagnostic
    // replays (live save URLs + wall-clock timestamps) — not pixel-stable, so it's
    // covered by an instantiation/layout assertion rather than a snapshot.
    func testReplaysScreenLayoutSane() {
        let replays = ReplaysViewController()
        let nav = UINavigationController(rootViewController: replays)
        let window = UITestSupport.host(nav)
        LayoutAssertions.assertVisibleAndInBounds(replays.tableView, in: replays.view)
        _ = window
    }

    // MARK: - Navigation: each top-level row pushes the right subscreen

    /// Drives `didSelectRowAt` for every row in section 0 and asserts the pushed
    /// view controller's class matches the expected subscreen, in order.
    func testSettingsRowsPushExpectedSubscreens() {
        var expected: [AnyClass] = [
            ReaderSettingsScreen.self,
            VoiceSettingsScreen.self,
            ReadingListSettingsScreen.self,
            EmailAndKindleSettingsScreen.self,
            MediaProviderSettingsScreen.self,
            AutoDownloadSettingsScreen.self,
        ]
        expected.append(contentsOf: [
            ShortcutSettingsScreen.self,
            AppearanceSettingsScreen.self,
            ExperimentalSettingsScreen.self,
            DiagnosticsViewController.self,
        ])
        // Validate the row count once against a single instance.
        let probe = SettingsViewController()
        _ = UITestSupport.host(UINavigationController(rootViewController: probe))
        XCTAssertEqual(probe.tableView(probe.tableView, numberOfRowsInSection: 0), expected.count,
                       "settings row count drifted from the expected subscreen list")

        // Use a fresh navigation stack per row so each push is independent (avoids
        // pop timing issues in a hosted, animation-disabled stack).
        for (row, expectedClass): (Int, AnyClass) in expected.enumerated() {
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

    /// The Kindle and Boox forwarding rows both drill into the per-source
    /// auto-send screen.
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
        // Section/row indices that push AutoSendBySourceScreen (from the VC's source).
        // On the Reader surface (the test host) the visible sections are:
        // lunaAccount(0), kindle(1), doubleSave(2), booxAccount(3), boox(4), … .
        // Kindle forwarding: section .kindle (1), row 0.
        // Boox forwarding: section .boox (4), row 0.
        [(EmailAndKindleSettingsScreen(), 1, 0), (EmailAndKindleSettingsScreen(), 4, 0)]
    }

    private func snapshotSubscreen(_ viewController: UIViewController, named name: String) {
        let nav = UINavigationController(rootViewController: viewController)
        SnapshotTesting.assertSnapshot(of: nav, named: name)
    }
}
