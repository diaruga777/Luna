//
//  PluginsSettingsScreenTests.swift
//  LunaTests
//
//  Settings → Plugins' list (plugin-platform.md §11.2): every row must show
//  what the catalog actually reports, status included.
//

import LunaModels
import LunaPluginKit
import LunaPluginUI
import LunaStorage
import UIKit
import XCTest
@testable import Luna

@MainActor
final class PluginsSettingsScreenTests: XCTestCase {

    private final class FakeCatalog: PluginCatalogProviding {
        var storedListings: [PluginListing]
        init(_ listings: [PluginListing]) { storedListings = listings }
        func listings() -> [PluginListing] { storedListings }
        func listing(pluginID: String) -> PluginListing? {
            storedListings.first { $0.summary.id == pluginID }
        }
        func sourceText(pluginID: String) -> String? { nil }
        func setEnabled(_ enabled: Bool, pluginID: String) throws {}
        func delete(pluginID: String) throws {}
    }

    private func summary(id: String, name: String, version: String = "1.0.0") -> PluginSummary {
        PluginSummary(
            id: id, name: name, version: version, priority: 0, matchesAnyHost: true,
            hostPatterns: [], produces: [.article], hooks: [.classify], export: nil,
            isBundled: false)
    }

    private func rowTexts(_ screen: PluginsSettingsScreen, section: Int = 0) -> [(String?, String?)] {
        let rows = screen.tableView(screen.tableView, numberOfRowsInSection: section)
        return (0..<rows).map { row in
            let cell = screen.tableView(
                screen.tableView, cellForRowAt: IndexPath(row: row, section: section))
            return (cell.textLabel?.text, cell.detailTextLabel?.text)
        }
    }

    func testAnEmptyCatalogShowsTheEmptyRow() {
        let screen = PluginsSettingsScreen(
            catalog: FakeCatalog([]), importer: nil, settingsStore: FakePluginSettingsStore(), invoker: nil)
        _ = UITestSupport.host(screen)
        let texts = rowTexts(screen)
        XCTAssertEqual(texts.count, 1)
        XCTAssertEqual(texts.first?.0, L10n.string("Plugins_emptyRow"))
    }

    func testEachRowShowsItsOwnNameVersionAndStatus() {
        let listings = [
            PluginListing(
                summary: summary(id: "a", name: "Recipe Saver"), description: nil,
                status: .enabled, capabilities: [], runsInBackground: false, settings: []),
            PluginListing(
                summary: summary(id: "b", name: "Gallery Grab"), description: nil,
                status: .disabled, capabilities: [], runsInBackground: false, settings: []),
            PluginListing(
                summary: summary(id: "c", name: "Price Watch"), description: nil,
                status: .stopped(reason: "timed out"), capabilities: [], runsInBackground: false,
                settings: []),
        ]
        let screen = PluginsSettingsScreen(
            catalog: FakeCatalog(listings), importer: nil, settingsStore: FakePluginSettingsStore(),
            invoker: nil)
        _ = UITestSupport.host(screen)
        let texts = rowTexts(screen)

        XCTAssertEqual(texts.map(\.0), ["Recipe Saver", "Gallery Grab", "Price Watch"])
        // The enabled plugin's quiet default status is not repeated in the row.
        XCTAssertFalse(texts[0].1?.contains(PluginCapabilityCopy.sentence(for: .enabled)) ?? true)
        XCTAssertTrue(texts[1].1?.contains(PluginCapabilityCopy.sentence(for: .disabled)) ?? false)
        XCTAssertTrue(
            texts[2].1?.contains(PluginCapabilityCopy.sentence(for: .stopped(reason: "timed out")))
                ?? false)
    }

    func testTheAddButtonIsAbsentWithoutAnImporter() {
        let screen = PluginsSettingsScreen(
            catalog: FakeCatalog([]), importer: nil, settingsStore: FakePluginSettingsStore(), invoker: nil)
        XCTAssertTrue(screen.makeTrailingControls().isEmpty)
    }

    func testTheAddButtonAppearsWithAnImporter() {
        let screen = PluginsSettingsScreen(
            catalog: FakeCatalog([]), importer: FakePluginImporter(), settingsStore: FakePluginSettingsStore(),
            invoker: nil)
        XCTAssertEqual(screen.makeTrailingControls().count, 1)
    }

    /// The wand needs somewhere to send the request. A surface that cannot open
    /// a chat model offers import only.
    func testTheCreateButtonAppearsOnlyWithALauncher() {
        let withoutLauncher = PluginsSettingsScreen(
            catalog: FakeCatalog([]), importer: FakePluginImporter(),
            settingsStore: FakePluginSettingsStore(), invoker: nil)
        let withLauncher = PluginsSettingsScreen(
            catalog: FakeCatalog([]), importer: FakePluginImporter(),
            settingsStore: FakePluginSettingsStore(), invoker: nil,
            launcher: SilentLauncher())

        XCTAssertEqual(
            withoutLauncher.makeTrailingControls().compactMap(\.accessibilityLabel),
            [L10n.string("Plugins_importTitle")])
        XCTAssertEqual(
            withLauncher.makeTrailingControls().compactMap(\.accessibilityLabel),
            [L10n.string("Plugins_create1Title"), L10n.string("Plugins_importTitle")])
    }
}

/// Shared across the plugin UI test files.
final class FakePluginSettingsStore: PluginSettingsStoring {
    var values: [String: [String: String]] = [:]
    private(set) var setCalls: [(pluginID: String, key: String, json: String?)] = []

    func valueJSON(pluginID: String, key: String) -> String? { values[pluginID]?[key] }

    func setValueJSON(_ json: String?, pluginID: String, key: String) throws {
        setCalls.append((pluginID, key, json))
        var forPlugin = values[pluginID] ?? [:]
        forPlugin[key] = json
        values[pluginID] = forPlugin
    }

    func allValuesJSON(pluginID: String) -> [String: String] { values[pluginID] ?? [:] }

    func isConfigured(pluginID: String, fields: [PluginSettingField]) -> Bool {
        let all = allValuesJSON(pluginID: pluginID)
        return fields.filter(\.isRequired).allSatisfy { all[$0.key] != nil }
    }
}

/// A no-op importer, just to exercise the Add button's presence.
final class FakePluginImporter: PluginImporting {
    func preview(sourceText: String) throws -> PluginImportPreview {
        throw NSError(domain: "test", code: 0)
    }
    func install(_ preview: PluginImportPreview, origin: PluginImportOrigin) throws {}
}

/// A launcher that opens nothing, for a screen that only has to show its
/// Create button.
final class SilentLauncher: LLMLaunching {
    func launch(_ provider: LLMProvider, prompt: String) {}
}
