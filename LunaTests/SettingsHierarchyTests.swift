//
//  SettingsHierarchyTests.swift
//  LunaTests
//

import UIKit
import XCTest
@testable import Luna

@MainActor
final class SettingsHierarchyTests: XCTestCase {
    private var window: UIWindow?

    override func tearDown() {
        window?.isHidden = true
        window?.rootViewController = nil
        window = nil
        super.tearDown()
    }

    func testReaderIncludesPreloadControlsWithoutReadingListDisplayToggles() {
        let screen = ReaderSettingsScreen()
        window = UITestSupport.host(screen)

        XCTAssertEqual(screen.tableView.numberOfSections, 2)
        XCTAssertEqual(screen.tableView.numberOfRows(inSection: 0), 5)
        XCTAssertEqual(screen.tableView.numberOfRows(inSection: 1), 2)
        XCTAssertEqual(rowTitle(screen, row: 0, section: 1), "Wi-Fi Only")
        XCTAssertEqual(rowTitle(screen, row: 1, section: 1), "Preload Depth")

        let allTitles = (0..<screen.tableView.numberOfSections).flatMap { section in
            (0..<screen.tableView.numberOfRows(inSection: section)).compactMap {
                rowTitle(screen, row: $0, section: section)
            }
        }
        XCTAssertFalse(allTitles.contains("Reading Time"))
        XCTAssertFalse(allTitles.contains("Reading Progress"))
    }

    func testAudioIncludesVoiceStatusAndInstallRowsInline() {
        let screen = AudioSettingsScreen()
        window = UITestSupport.host(screen)

        XCTAssertEqual(screen.tableView.numberOfSections, 3)
        XCTAssertEqual(screen.tableView.numberOfRows(inSection: 2), 2)
        XCTAssertEqual(rowTitle(screen, row: 1, section: 2), "Install Enhanced Voices")
    }

    func testDownloadsUsesOneSharedTwoPickerLayout() {
        let screen = DownloadsSettingsScreen()
        window = UITestSupport.host(screen)

        XCTAssertEqual(screen.tableView.numberOfSections, 2)
        XCTAssertEqual(screen.tableView.numberOfRows(inSection: 0), 1)
        XCTAssertEqual(screen.tableView.numberOfRows(inSection: 1), 1)
        XCTAssertEqual(rowTitle(screen, row: 0, section: 0), "Download Automatically")
        XCTAssertEqual(rowTitle(screen, row: 0, section: 1), "Storage")
    }

    func testKindleForwardingDoesNotExposeDoubleSaveMode() {
        let screen = AutoSendBySourceScreen(
            destinationID: "test-kindle", destinationName: "Kindle")
        window = UITestSupport.host(screen)

        let cell = screen.tableView(
            screen.tableView, cellForRowAt: IndexPath(row: 0, section: 0))
        let modeButton = try! XCTUnwrap(cell.accessoryView as? UIButton)
        let modeTitles = modeButton.menu?.children.compactMap {
            ($0 as? UIAction)?.title
        }
        XCTAssertEqual(modeTitles, ["Off", "All Saved Articles"])
    }

    func testTopLevelHidesDiagnosticsAndRequiresEmailForKindle() {
        let screen = SettingsViewController(emailIsConfigured: { false })
        let nav = UINavigationController(rootViewController: screen)
        window = UITestSupport.host(nav)

        let titles = (0..<screen.tableView.numberOfRows(inSection: 0)).compactMap {
            rowTitle(screen, row: $0, section: 0)
        }
        XCTAssertTrue(titles.contains("Email"))
        XCTAssertTrue(titles.contains("Kindle"))
        XCTAssertFalse(titles.contains("Reading List"))
        XCTAssertFalse(titles.contains("Diagnostics"))

        let kindleRow = try! XCTUnwrap(titles.firstIndex(of: "Kindle"))
        screen.tableView(
            screen.tableView, didSelectRowAt: IndexPath(row: kindleRow, section: 0))
        let alert = try! XCTUnwrap(screen.presentedViewController as? UIAlertController)
        XCTAssertEqual(alert.title, "Set up email first")
        XCTAssertEqual(alert.actions.map(\.title), ["Not Now", "OK"])
    }

    /// The Safari extension needs no particular OS or hardware, so its section
    /// survives on a device with no Action Button to assign the shortcut to —
    /// and the screen renames itself to what is left of it.
    func testWithoutShortcutHardwareOnlyTheSafariSectionRemains() {
        let screen = ShortcutSettingsScreen(showsShortcutSetup: false)
        window = UITestSupport.host(screen)

        XCTAssertEqual(screen.tableView.numberOfSections, 1)
        XCTAssertEqual(sectionTitles(screen), ["Luna Button"])
        XCTAssertEqual(
            ShortcutSettingsScreen.screenTitle(showsShortcutSetup: false), "Safari")
    }

    func testShortcutCapableDeviceKeepsEveryShortcutSection() {
        let screen = ShortcutSettingsScreen(showsShortcutSetup: true)
        window = UITestSupport.host(screen)

        XCTAssertEqual(
            sectionTitles(screen),
            [
                "Luna Button", "On-Screen URLs", "Double Save Articles",
                "Action Button Shortcut",
            ])
        XCTAssertEqual(
            ShortcutSettingsScreen.screenTitle(showsShortcutSetup: true),
            "Shortcut & Safari")
    }

    func testSettingsHasFiveTapDiagnosticsGesture() {
        let screen = SettingsViewController(emailIsConfigured: { false })
        window = UITestSupport.host(screen)

        XCTAssertTrue(screen.tableView.gestureRecognizers?.contains {
            ($0 as? UITapGestureRecognizer)?.numberOfTapsRequired == 5
        } ?? false)
    }

    private func sectionTitles(_ screen: UITableViewController) -> [String] {
        (0..<screen.tableView.numberOfSections).compactMap {
            screen.tableView(screen.tableView, titleForHeaderInSection: $0)
        }
    }

    private func rowTitle(
        _ screen: UITableViewController, row: Int, section: Int
    ) -> String? {
        let cell = screen.tableView(
            screen.tableView, cellForRowAt: IndexPath(row: row, section: section))
        return (cell.contentConfiguration as? UIListContentConfiguration)?.text
    }
}
