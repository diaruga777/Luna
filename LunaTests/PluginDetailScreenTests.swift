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

        private(set) var argumentJSON: [String] = []

        /// `PluginDetailScreen` never reads the settled value of a UI-driven
        /// `onAction`/`onSettingsChanged` call, so this always answers
        /// `.missingHook` — the recorded invocation and the ARGUMENT it
        /// carried are what a plugin actually sees.
        func invoke<T: Decodable>(
            _ hook: PluginHook, pluginID: String, argument: Encodable, timeout: TimeInterval,
            decode: T.Type
        ) async -> Result<T, PluginInvocationFailure> {
            invocations.append((hook, pluginID))
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            if let data = try? encoder.encode(EncodableBox(wrapped: argument)) {
                argumentJSON.append(String(decoding: data, as: UTF8.self))
            }
            return .failure(.missingHook)
        }

        func reloadAll() {}

        /// `JSONEncoder` will not take an `Encodable` existential in the
        /// package's Swift 5 language mode.
        private struct EncodableBox: Encodable {
            let wrapped: Encodable
            func encode(to encoder: Encoder) throws { try wrapped.encode(to: encoder) }
        }
    }

    private final class RecordingAutoSend: PluginDestinationAutoSendPresenting {
        private(set) var opened: [(destinationID: String, displayName: String)] = []
        func presentAutoSend(
            destinationID: String, displayName: String, from presenter: UIViewController
        ) {
            opened.append((destinationID, displayName))
        }
    }

    private func summary(
        id: String = "p", isBundled: Bool, export: PluginExportSummary? = nil
    ) -> PluginSummary {
        PluginSummary(
            id: id, name: "Price Watch", version: "1.0.0", priority: 0, matchesAnyHost: true,
            hostPatterns: [], produces: [.product], hooks: [.classify], export: export,
            isBundled: isBundled)
    }

    private func destinationExport() -> PluginExportSummary {
        PluginExportSummary(
            kinds: [.article], input: "epub", epubProfile: nil, epubImages: true,
            title: "Send to Reader", symbol: nil, isDestination: true, requiresSettings: [])
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

    // MARK: - Auto-send

    /// The row exists only where the app installed the screen it opens, and
    /// only for a plugin that is actually a destination — nothing else has
    /// per-source auto-send to configure.
    func testTheAutoSendRowNeedsBothADestinationAndAWitness() {
        let witness = RecordingAutoSend()
        PluginDestinationAutoSend.presenter = witness
        defer { PluginDestinationAutoSend.presenter = nil }

        let plain = PluginListing(
            summary: summary(isBundled: true), description: nil, status: .enabled,
            capabilities: [], runsInBackground: false, settings: [])
        let plainScreen = PluginDetailScreen(
            listing: plain, catalog: FakeCatalog([plain]),
            settingsStore: FakePluginSettingsStore(), invoker: nil)
        _ = UITestSupport.host(plainScreen)
        XCTAssertFalse(allRowTexts(plainScreen).contains(L10n.string("Plugins_autoSendRow")))

        let destination = PluginListing(
            summary: summary(isBundled: true, export: destinationExport()), description: nil,
            status: .enabled, capabilities: [], runsInBackground: false, settings: [])
        let screen = PluginDetailScreen(
            listing: destination, catalog: FakeCatalog([destination]),
            settingsStore: FakePluginSettingsStore(), invoker: nil)
        _ = UITestSupport.host(screen)
        XCTAssertTrue(allRowTexts(screen).contains(L10n.string("Plugins_autoSendRow")))

        PluginDestinationAutoSend.presenter = nil
        let unwitnessed = PluginDetailScreen(
            listing: destination, catalog: FakeCatalog([destination]),
            settingsStore: FakePluginSettingsStore(), invoker: nil)
        _ = UITestSupport.host(unwitnessed)
        XCTAssertFalse(
            allRowTexts(unwitnessed).contains(L10n.string("Plugins_autoSendRow")),
            "an app with no auto-send screen must not advertise one")
    }

    /// The row opens the screen under the DESTINATION id, not the plugin id —
    /// every send state and per-source toggle is keyed by the former.
    func testTheAutoSendRowOpensUnderTheDestinationID() {
        let witness = RecordingAutoSend()
        PluginDestinationAutoSend.presenter = witness
        defer { PluginDestinationAutoSend.presenter = nil }

        let listing = PluginListing(
            summary: summary(id: "app.luna.xteink", isBundled: true, export: destinationExport()),
            description: nil, status: .enabled, capabilities: [], runsInBackground: false,
            settings: [])
        let screen = PluginDetailScreen(
            listing: listing, catalog: FakeCatalog([listing]),
            settingsStore: FakePluginSettingsStore(), invoker: nil)
        _ = UITestSupport.host(screen)

        // Status is section 0; the settings section holding the row is 1.
        screen.tableView(screen.tableView, didSelectRowAt: IndexPath(row: 0, section: 1))

        XCTAssertEqual(witness.opened.map(\.destinationID), ["xteink"])
        XCTAssertEqual(witness.opened.map(\.displayName), ["Send to Reader"])
    }

    /// The hook takes a map of CHANGED KEYS. `xteink.js` reads
    /// `changes.enabled`, so a `{key, value}` pair means switching a
    /// destination off never stands its status dot down.
    func testTheSettingsHookReceivesAMapKeyedByTheSettingThatChanged() {
        let toggleField = field(key: "enabled", type: .toggle)
        let listing = PluginListing(
            summary: summary(isBundled: false), description: nil, status: .enabled,
            capabilities: [], runsInBackground: false, settings: [toggleField])
        let invoker = FakeInvoker()
        let screen = PluginDetailScreen(
            listing: listing, catalog: FakeCatalog([listing]),
            settingsStore: FakePluginSettingsStore(), invoker: invoker)
        _ = UITestSupport.host(screen)

        let cell = screen.tableView(screen.tableView, cellForRowAt: IndexPath(row: 0, section: 1))
        guard let toggle = cell.accessoryView as? UISwitch else {
            return XCTFail("expected the toggle field to render as a switch")
        }
        toggle.isOn = false
        toggle.sendActions(for: .valueChanged)

        let pumped = expectation(description: "runtime notified")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { pumped.fulfill() }
        wait(for: [pumped], timeout: 2)

        XCTAssertEqual(invoker.argumentJSON, ["{\"enabled\":false}"])
    }

    /// A `pairedDevice` row offers both Pair and Unpair under one key, so the
    /// key alone cannot say which the user pressed. Without the action,
    /// pairing is unreachable and the destination stays unconfigured forever.
    func testThePairedDeviceRowNamesTheActionItWants() {
        let deviceField = field(key: "device", type: .pairedDevice)
        let store = FakePluginSettingsStore()
        let listing = PluginListing(
            summary: summary(isBundled: false), description: nil, status: .enabled,
            capabilities: [], runsInBackground: false, settings: [deviceField])
        let invoker = FakeInvoker()
        let screen = PluginDetailScreen(
            listing: listing, catalog: FakeCatalog([listing]), settingsStore: store,
            invoker: invoker)
        _ = UITestSupport.host(screen)

        func pressTheButton() {
            let cell = screen.tableView(
                screen.tableView, cellForRowAt: IndexPath(row: 0, section: 1))
            guard let button = cell.accessoryView as? UIButton else {
                return XCTFail("expected a Pair/Unpair button")
            }
            button.sendActions(for: .touchUpInside)
            let pumped = expectation(description: "hook invoked")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { pumped.fulfill() }
            wait(for: [pumped], timeout: 2)
        }

        pressTheButton()
        XCTAssertEqual(invoker.argumentJSON.last, "{\"action\":\"pair\",\"key\":\"device\"}")

        store.setString("Xteink X3", pluginID: listing.summary.id, key: "device")
        screen.viewDidLoad()
        pressTheButton()
        XCTAssertEqual(invoker.argumentJSON.last, "{\"action\":\"unpair\",\"key\":\"device\"}")
    }

    /// Picking an option pops back to this screen, which must show what was
    /// picked rather than the value it had on the way in.
    func testPickingAChoiceRedrawsTheRowWithTheNewValue() {
        let choice = PluginSettingField(
            key: "mode", type: .choice, label: "Mode",
            options: [
                PluginSettingOption(id: "fast", label: "Fast"),
                PluginSettingOption(id: "slow", label: "Slow"),
            ])
        let listing = PluginListing(
            summary: summary(isBundled: false), description: nil, status: .enabled,
            capabilities: [], runsInBackground: false, settings: [choice])
        let screen = PluginDetailScreen(
            listing: listing, catalog: FakeCatalog([listing]),
            settingsStore: FakePluginSettingsStore(), invoker: nil)
        let nav = UINavigationController(rootViewController: screen)
        _ = UITestSupport.host(nav)

        screen.tableView(screen.tableView, didSelectRowAt: IndexPath(row: 0, section: 1))
        guard let picker = screen.navigationController?.topViewController
            as? PluginChoiceScreen
        else { return XCTFail("expected the choice picker") }
        _ = picker.view
        picker.tableView(picker.tableView, didSelectRowAt: IndexPath(row: 1, section: 0))

        let cell = screen.tableView(screen.tableView, cellForRowAt: IndexPath(row: 0, section: 1))
        XCTAssertEqual(cell.detailTextLabel?.text, "Slow")
    }

    /// A field's `help` is the only explanation its author can write. It used
    /// to render for `info` alone, which silently dropped it for the nine
    /// other types.
    func testHelpRendersForAFieldThatIsNotInfo() {
        let toggleField = PluginSettingField(
            key: "enabled", type: .toggle, label: "Send to Reader",
            help: "Queued articles go out when the reader opens a window.")
        let listing = PluginListing(
            summary: summary(isBundled: false), description: nil, status: .enabled,
            capabilities: [], runsInBackground: false, settings: [toggleField])
        let screen = PluginDetailScreen(
            listing: listing, catalog: FakeCatalog([listing]),
            settingsStore: FakePluginSettingsStore(), invoker: nil)
        _ = UITestSupport.host(screen)

        let cell = screen.tableView(screen.tableView, cellForRowAt: IndexPath(row: 0, section: 1))
        XCTAssertEqual(
            cell.detailTextLabel?.text,
            "Queued articles go out when the reader opens a window.")
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
