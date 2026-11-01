import LunaModels
import LunaPluginKit
import LunaPluginRuntime
import LunaPluginUI
import XCTest
@testable import Luna

final class BundledPluginVisibilityTests: XCTestCase {
    private var root: URL!
    private var store: PluginStore!
    private var bundled: BundledPluginCatalog!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        store = PluginStore(rootURL: root.appendingPathComponent("Plugins"))
        let scripts = root.appendingPathComponent("Bundled")
        try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
        bundled = BundledPluginCatalog(source: .directory(scripts), store: store)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    private func source(
        id: String, hosts: [String] = ["example.com"], any: Bool = false,
        ingest: Bool = true, body: String? = nil
    ) throws -> String {
        var header: [String: Any] = ["id": id, "name": id, "version": "1.0.0", "api": 1]
        if ingest {
            header["produces"] = ["article"]
            header["match"] = any ? ["any": true] : ["hosts": hosts]
        } else {
            header["export"] = ["kinds": ["article"], "input": "text", "title": "Export"]
        }
        let json = String(decoding: try JSONSerialization.data(withJSONObject: header), as: UTF8.self)
        return "/* luna-plugin\n\(json)\n*/\n" + (body ?? """
        luna.register({ classify() { return false; }, async ingest() { return null; },
                        async export() {} });
        """)
    }

    private func ship(_ text: String, name: String = "default") throws {
        try text.write(to: root.appendingPathComponent("Bundled/\(name).js"), atomically: true, encoding: .utf8)
    }

    private func runtime() -> PluginRuntime {
        PluginRuntime(store: store, bundled: bundled, processContext: PluginProcessContext(kind: .app))
    }

    private func catalog(debug: Bool = false) -> PluginCatalog {
        PluginCatalog(store: store, bundled: bundled, runtime: runtime(),
                      includeUnrevealedBundledPlugins: debug)
    }

    func testReleaseHidesManagementWithoutDisablingRuntimeOrFeatureLookup() throws {
        try ship(source(id: "app.luna.default"))
        let runtime = runtime()
        runtime.loadAll()
        let catalog = PluginCatalog(store: store, bundled: bundled, runtime: runtime,
                                    includeUnrevealedBundledPlugins: false)
        XCTAssertEqual(runtime.loadedPlugins.map(\.id), ["app.luna.default"])
        XCTAssertEqual(catalog.listings().count, 1)
        XCTAssertEqual(catalog.listing(pluginID: "app.luna.default")?.status, .enabled)
        XCTAssertTrue(catalog.managementListings().isEmpty)
        XCTAssertNil(catalog.sourceText(pluginID: "app.luna.default"))
        XCTAssertThrowsError(try catalog.setEnabled(false, pluginID: "app.luna.default"))
        XCTAssertTrue(store.state("app.luna.default", isBundled: true).isEnabled)
        XCTAssertFalse(store.bundledPluginsRevealed)
    }

    func testDebugShowsDefaultsWithoutPersistingAReveal() throws {
        try ship(source(id: "app.luna.default"))
        let debug = catalog(debug: true)
        XCTAssertEqual(debug.managementListings().count, 1)
        XCTAssertNotNil(debug.sourceText(pluginID: "app.luna.default"))
        try debug.setEnabled(false, pluginID: "app.luna.default")
        XCTAssertFalse(store.state("app.luna.default", isBundled: true).isEnabled)
        XCTAssertFalse(store.bundledPluginsRevealed)
        XCTAssertTrue(catalog().managementListings().isEmpty)
    }

    @MainActor
    func testOpeningDiagnosticsPermanentlyRevealsAllDefaults() throws {
        try ship(source(id: "app.luna.default"))
        try ship(source(id: "app.luna.other", hosts: ["other.org"]), name: "other")
        let catalog = catalog()
        let previous = PluginPlatformServices.catalog
        PluginPlatformServices.catalog = catalog
        defer { PluginPlatformServices.catalog = previous }
        DiagnosticsViewController().loadViewIfNeeded()
        XCTAssertEqual(catalog.managementListings().count, 2)
        XCTAssertTrue(PluginStore(rootURL: store.rootURL).bundledPluginsRevealed)
        XCTAssertEqual(self.catalog().managementListings().count, 2)
        try catalog.setEnabled(false, pluginID: "app.luna.default")
        XCTAssertFalse(store.state("app.luna.default", isBundled: true).isEnabled)
    }

    @MainActor
    func testSettingsListRefreshesFromHiddenToRevealed() throws {
        try ship(source(id: "app.luna.default"))
        let catalog = catalog()
        let screen = PluginsSettingsScreen(
            catalog: catalog, importer: nil, settingsStore: NullPluginSettingsStore(), invoker: nil)
        screen.loadViewIfNeeded()
        let first = IndexPath(row: 0, section: 0)
        XCTAssertEqual(screen.tableView(screen.tableView, cellForRowAt: first).textLabel?.text,
                       L10n.string("Plugins_emptyRow"))
        try catalog.revealBundledPlugins()
        screen.viewWillAppear(false)
        XCTAssertEqual(screen.tableView(screen.tableView, cellForRowAt: first).textLabel?.text,
                       "app.luna.default")
    }

    func testUnrelatedHostsAndExportOnlyImportsDoNotReveal() throws {
        try ship(source(id: "app.luna.default"))
        let importer = PluginImporter(store: store, bundled: bundled, runtime: nil)
        for text in [try source(id: "app.luna.unrelated", hosts: ["other.org"]),
                     try source(id: "app.luna.exporter", ingest: false)] {
            try importer.install(importer.preview(sourceText: text), origin: .files)
        }
        XCTAssertFalse(store.bundledPluginsRevealed)
        XCTAssertEqual(catalog().managementListings().map(\.summary.id),
                       ["app.luna.exporter", "app.luna.unrelated"])
    }

    func testHostOverlapRevealsAtInstallationBeforeAnyURLIsSaved() throws {
        let pairs: [([String], [String])] = [
            (["example.com"], ["EXAMPLE.COM"]),
            (["*.example.com"], ["news.example.com"]),
            (["news.example.com"], ["*.example.com"]),
            (["*.example.com"], ["*.news.example.com"]),
            (["*.news.example.com"], ["*.example.com"]),
            (["example.com"], ["*.example.com"])
        ]
        for (shipped, imported) in pairs {
            let pairRoot = root.appendingPathComponent(UUID().uuidString)
            let pairStore = PluginStore(rootURL: pairRoot)
            let scriptRoot = pairRoot.appendingPathComponent("Bundled")
            try FileManager.default.createDirectory(at: scriptRoot, withIntermediateDirectories: true)
            try source(id: "app.luna.default", hosts: shipped).write(
                to: scriptRoot.appendingPathComponent("default.js"), atomically: true, encoding: .utf8)
            let pairBundle = BundledPluginCatalog(source: .directory(scriptRoot), store: pairStore)
            let importer = PluginImporter(store: pairStore, bundled: pairBundle, runtime: nil)
            let preview = try importer.preview(sourceText: source(id: "app.luna.imported", hosts: imported))
            XCTAssertFalse(pairStore.bundledPluginsRevealed)
            try importer.install(preview, origin: .paste)
            XCTAssertTrue(pairStore.bundledPluginsRevealed, "\(shipped) / \(imported)")
        }
    }

    func testAnyHostCompetitionPersistsAfterDeletionAndRelaunch() async throws {
        try ship(source(id: "app.luna.default", any: true))
        let catalog = catalog()
        let importer = PluginImporter(store: store, bundled: bundled, runtime: runtime())
        let preview = try importer.preview(sourceText: source(id: "app.luna.imported", hosts: ["other.org"]))
        XCTAssertTrue(catalog.managementListings().isEmpty)
        try await importer.installAsync(preview, origin: .files)
        XCTAssertEqual(catalog.managementListings().count, 2)
        try store.setEnabledChecked(false, pluginID: "app.luna.imported", isBundled: false)
        try store.delete(pluginID: "app.luna.imported")
        XCTAssertEqual(self.catalog().managementListings().map(\.summary.id), ["app.luna.default"])
        XCTAssertTrue(PluginStore(rootURL: store.rootURL).bundledPluginsRevealed)
    }

    func testImportedAnyHostAlsoReveals() throws {
        try ship(source(id: "app.luna.default"))
        let importer = PluginImporter(store: store, bundled: bundled, runtime: nil)
        try importer.install(importer.preview(sourceText: source(id: "app.luna.any", any: true)), origin: .paste)
        XCTAssertTrue(store.bundledPluginsRevealed)
    }

    func testReplacingABundledIDRevealsItsFallbackAfterDeletion() throws {
        try ship(source(id: "app.luna.default", ingest: false))
        let importer = PluginImporter(store: store, bundled: bundled, runtime: nil)
        try importer.install(importer.preview(sourceText: source(id: "app.luna.default", ingest: false)), origin: .paste)
        XCTAssertTrue(store.bundledPluginsRevealed)
        try store.delete(pluginID: "app.luna.default")
        XCTAssertEqual(catalog().managementListings().count, 1)
    }

    func testExistingCompetingImportsMigrateOnCatalogCreation() throws {
        try ship(source(id: "app.luna.default"))
        let text = try source(id: "app.luna.imported")
        try store.install(source: text, manifest: PluginManifestParser.parse(source: text).get(), origin: .files)
        XCTAssertFalse(store.bundledPluginsRevealed)
        XCTAssertEqual(catalog().managementListings().count, 2)
        try store.delete(pluginID: "app.luna.imported")
        XCTAssertTrue(store.bundledPluginsRevealed)
    }

    func testRejectedActivationDoesNotReveal() async throws {
        try ship(source(id: "app.luna.default"))
        let catalog = catalog()
        let importer = PluginImporter(store: store, bundled: bundled, runtime: runtime())
        let preview = try importer.preview(sourceText: source(
            id: "app.luna.imported", body: "throw new Error('bad plugin');"))
        do {
            try await importer.installAsync(preview, origin: .paste)
            XCTFail("Activation should fail")
        } catch {}
        XCTAssertNil(store.plugin(id: "app.luna.imported"))
        XCTAssertFalse(store.bundledPluginsRevealed)
        XCTAssertTrue(catalog.managementListings().isEmpty)
    }
}
