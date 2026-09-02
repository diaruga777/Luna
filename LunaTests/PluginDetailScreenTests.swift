//
//  PluginDetailScreenTests.swift
//  LunaTests
//
//  One plugin's settings screen (plugin-platform.md §11.1): a settings edit
//  must persist through the store and notify the runtime, and Delete must
//  never be offered for a bundled plugin.
//

import LunaModels
import LunaPluginKit
import LunaPluginUI
import UIKit
import XCTest
@testable import Luna

@MainActor
final class PluginDetailScreenTests: XCTestCase {

    private final class FakeCatalog: PluginCatalogProviding {
        var storedListings: [PluginListing]
        private(set) var deleteCalls: [String] = []
        private(set) var enabledCalls: [(pluginID: String, enabled: Bool)] = []
        var deleteError: Error?

        init(_ listings: [PluginListing]) { storedListings = listings }
        func listings() -> [PluginListing] { storedListings }
        func listing(pluginID: String) -> PluginListing? {
            storedListings.first { $0.summary.id == pluginID }
        }
        func sourceText(pluginID: String) -> String? { "source" }
        func setEnabled(_ enabled: Bool, pluginID: String) throws {
            enabledCalls.append((pluginID, enabled))
        }
        func delete(pluginID: String) throws {
            deleteCalls.append(pluginID)
            if let deleteError { throw deleteError }
        }
    }

    private final class FakeInvoker: PluginHookInvoking {
        var loadedPlugins: [PluginSummary] = []
        var disabledPlugins: [String: String] = [:]
        private(set) var invocations: [(hook: PluginHook, pluginID: String)] = []

        func matchedPlugins(forHost host: String) -> [PluginSummary] { [] }

        /// `PluginDetailScreen` never reads the settled value of a UI-driven
        /// `onAction`/`onSettingsChanged` call, so this always answers
        /// `.missingHook` — only the recorded invocation matters here.
        func invoke<T: Decodable>(
            _ hook: PluginHook, pluginID: String, argument: Encodable, timeout: TimeInterval,
            decode: T.Type
        ) async -> Result<T, PluginInvocationFailure> {
            invocations.append((hook, pluginID))
            return .failure(.missingHook)
        }

        func reloadAll() {}
    }

    private func summary(id: String = "p", isBundled: Bool) -> PluginSummary {
        PluginSummary(
            id: id, name: "Price Watch", version: "1.0.0", priority: 0, matchesAnyHost: true,
            hostPatterns: [], produces: [.product], hooks: [.classify], export: nil,
            isBundled: isBundled)
    }

    private func field(
        key: String, type: PluginSettingFieldType, isRequired: Bool = false, isSecret: Bool = false
    ) -> PluginSettingField {
        PluginSettingField(key: key, type: type, label: key, isRequired: isRequired, isSecret: isSecret)
    }

    private func allRowTexts(_ screen: PluginDetailScreen) -> [String?] {
        var texts: [String?] = []
        for section in 0..<screen.numberOfSections(in: screen.tableView) {
            let rows = screen.tableView(screen.tableView, numberOfRowsInSection: section)
            for row in 0..<rows {
                let cell = screen.tableView(
                    screen.tableView, cellForRowAt: IndexPath(row: row, section: section))
                texts.append(cell.textLabel?.text)
            }
        }
        return texts
    }

    // MARK: - Delete

    func testDeleteIsNotOfferedForABundledPlugin() {
        let listing = PluginListing(
            summary: summary(isBundled: true), description: nil, status: .enabled,
            capabilities: [], runsInBackground: false, settings: [])
        let screen = PluginDetailScreen(
            listing: listing, catalog: FakeCatalog([listing]), settingsStore: FakePluginSettingsStore(),
            invoker: nil)
        _ = UITestSupport.host(screen)
        XCTAssertFalse(
            allRowTexts(screen).contains(L10n.string("Plugins_deleteRow")),
            "a bundled plugin can only be disabled, never deleted")
    }

    func testSelectingDeleteAsksForConfirmationRatherThanDeletingImmediately() {
        let listing = PluginListing(
            summary: summary(isBundled: false), description: nil, status: .enabled,
            capabilities: [], runsInBackground: false, settings: [])
        let catalog = FakeCatalog([listing])
        let screen = PluginDetailScreen(
            listing: listing, catalog: catalog, settingsStore: FakePluginSettingsStore(), invoker: nil)
        let nav = UINavigationController(rootViewController: screen)
        _ = UITestSupport.host(nav)

        XCTAssertTrue(allRowTexts(screen).contains(L10n.string("Plugins_deleteRow")))

        // Delete is the row of the screen's LAST section (no settings, no
        // capabilities, no description here, so section 1 is "Show Source"
        // and section 2 is Delete).
        screen.tableView(screen.tableView, didSelectRowAt: IndexPath(row: 0, section: 2))

        guard let alert = screen.presentedViewController as? UIAlertController else {
            return XCTFail("expected a confirmation alert before deleting")
        }
        XCTAssertEqual(alert.actions.map(\.style), [.cancel, .destructive])
        XCTAssertTrue(
            catalog.deleteCalls.isEmpty, "the catalog must not be touched before confirmation")
    }

    // MARK: - Settings edits

    func testTogglingASettingWritesJSONAndNotifiesTheRuntime() {
        let toggleField = field(key: "notifyOnDrop", type: .toggle)
        let listing = PluginListing(
            summary: summary(isBundled: false), description: nil, status: .enabled,
            capabilities: [], runsInBackground: false, settings: [toggleField])
        let store = FakePluginSettingsStore()
        let invoker = FakeInvoker()
        let screen = PluginDetailScreen(
            listing: listing, catalog: FakeCatalog([listing]), settingsStore: store, invoker: invoker)
        _ = UITestSupport.host(screen)

        // The settings section is the first one after status (no "About"
        // section, since this listing has neither a description nor a
        // background flag) and no capabilities either, so it is section 1.
        let cell = screen.tableView(
            screen.tableView, cellForRowAt: IndexPath(row: 0, section: 1))
        guard let toggle = cell.accessoryView as? UISwitch else {
            return XCTFail("expected the toggle field to render as a switch")
        }
        toggle.isOn = true
        toggle.sendActions(for: .valueChanged)

        let pumped = expectation(description: "runtime notified")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { pumped.fulfill() }
        wait(for: [pumped], timeout: 2)

        XCTAssertEqual(store.setCalls.count, 1)
        XCTAssertEqual(store.setCalls.first?.key, "notifyOnDrop")
        XCTAssertEqual(store.setCalls.first?.json, "true")
        XCTAssertEqual(store.valueJSON(pluginID: listing.summary.id, key: "notifyOnDrop"), "true")
        XCTAssertEqual(invoker.invocations.count, 1)
        XCTAssertEqual(invoker.invocations.first?.hook, .onSettingsChanged)
    }

    func testEnablingAStoppedPluginCallsSetEnabled() {
        let listing = PluginListing(
            summary: summary(isBundled: false), description: nil,
            status: .stopped(reason: "timed out"), capabilities: [], runsInBackground: false,
            settings: [])
        let catalog = FakeCatalog([listing])
        let screen = PluginDetailScreen(
            listing: listing, catalog: catalog, settingsStore: FakePluginSettingsStore(), invoker: nil)
        _ = UITestSupport.host(screen)

        XCTAssertTrue(
            allRowTexts(screen).contains(L10n.string("Plugins_reenableRow")),
            "a stopped plugin must offer Re-enable")

        // The status section is section 0; enable is row 0, Re-enable is row 1.
        screen.tableView(screen.tableView, didSelectRowAt: IndexPath(row: 1, section: 0))
        XCTAssertEqual(catalog.enabledCalls.count, 1)
        XCTAssertEqual(catalog.enabledCalls.first?.pluginID, listing.summary.id)
        XCTAssertEqual(catalog.enabledCalls.first?.enabled, true)
    }
}
