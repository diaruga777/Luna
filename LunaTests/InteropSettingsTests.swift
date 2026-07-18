//
//  InteropSettingsTests.swift
//  LunaTests
//

import LunaInterop
import LunaInteropUI
import LunaSocialUI
import XCTest
@testable import Luna

@MainActor
final class InteropSettingsTests: XCTestCase {

    func testSharedSettingsRowShowsEntitlementAndOpensPaywall() {
        let settings = SettingsViewController()
        let nav = UINavigationController(rootViewController: settings)
        settings.loadViewIfNeeded()

        let rows = 0..<settings.tableView(settings.tableView, numberOfRowsInSection: 0)
        guard let row = rows.first(where: {
            let path = IndexPath(row: $0, section: 0)
            let cell = settings.tableView(settings.tableView, cellForRowAt: path)
            return (cell.contentConfiguration as? UIListContentConfiguration)?.text
                == "Luna Interoperability"
        }) else {
            return XCTFail("every app must expose Luna Interoperability in Settings")
        }

        let path = IndexPath(row: row, section: 0)
        let cell = settings.tableView(settings.tableView, cellForRowAt: path)
        let content = cell.contentConfiguration as? UIListContentConfiguration
        XCTAssertEqual(
            content?.secondaryText,
            InteropEntitlement.shared.isUnlocked ? "Unlocked" : nil)

        settings.tableView(settings.tableView, didSelectRowAt: path)
        XCTAssertTrue(nav.topViewController is InteropPaywallViewController)
    }

    func testFriendsIsASettingsSubpage() {
        let settings = SettingsViewController()
        let nav = UINavigationController(rootViewController: settings)
        settings.loadViewIfNeeded()

        let rows = 0..<settings.tableView(settings.tableView, numberOfRowsInSection: 0)
        guard let row = rows.first(where: {
            let path = IndexPath(row: $0, section: 0)
            let cell = settings.tableView(settings.tableView, cellForRowAt: path)
            return (cell.contentConfiguration as? UIListContentConfiguration)?.text == "Friends"
        }) else {
            return XCTFail("Settings must expose Friends")
        }

        settings.tableView(
            settings.tableView, didSelectRowAt: IndexPath(row: row, section: 0))
        XCTAssertTrue(nav.topViewController is FriendsViewController)
    }
}
