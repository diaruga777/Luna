//
//  PluginStoreTests.swift
//  LunaTests
//

import LunaModels
import LunaPluginKit
import XCTest

/// What the store owes the Plugins screen: an install that replaces cleanly, a
/// bundled plugin a user copy shadows, and state that survives being switched
/// off.
final class PluginStoreTests: XCTestCase {

    private var containerURL: URL!
    private var store: PluginStore!

    override func setUp() {
        super.setUp()
        containerURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("plugin-store-\(UUID().uuidString)", isDirectory: true)
        store = PluginStore(rootURL: containerURL)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: containerURL)
        super.tearDown()
    }

    // MARK: - Fixtures

    private func source(id: String = "app.luna.test", version: String = "1.0.0") -> String {
        """
        /* luna-plugin
        {
          "id": "\(id)",
          "name": "Test",
          "version": "\(version)",
          "api": 1,
          "produces": ["media"],
          "match": { "hosts": ["example.com"] }
        }
        */
        luna.register({ classify() { return false; }, async ingest() { return null; } });
        """
    }

    @discardableResult
    private func install(
        _ text: String, origin: PluginImportOrigin = .paste
    ) throws -> InstalledPlugin {
        guard case .success(let manifest) = PluginManifestParser.parse(source: text) else {
            throw PluginManifestError.noHeader
        }
        return try store.install(source: text, manifest: manifest, origin: origin)
    }

    // MARK: - Installing

    func testAnInstalledPluginIsReadBackVerbatimWithItsManifest() throws {
        let text = source()
        try install(text, origin: .files)

        let plugin = store.plugin(id: "app.luna.test")
        XCTAssertEqual(plugin?.manifest.version.description, "1.0.0")
        XCTAssertEqual(plugin?.sourceText(), text)
        XCTAssertEqual(plugin?.state.origin, .files)
        XCTAssertEqual(plugin?.state.consentedCapabilities, [])
        XCTAssertEqual(plugin?.isBundled, false)
    }

    func testInstallingASecondVersionReplacesTheFirstRatherThanStackingIt() throws {
        try install(source(version: "1.0.0"))
        try install(source(version: "2.1.3"))

        XCTAssertEqual(store.versions(of: "app.luna.test").map(\.description), ["2.1.3"])
        XCTAssertEqual(store.plugin(id: "app.luna.test")?.manifest.version.description, "2.1.3")
    }

    /// The stale versions used to be removed BEFORE the new one landed, so a
    /// move that failed left the plugin with no version installed at all.
    func testAFailedInstallLeavesTheVersionThatWasAlreadyThere() throws {
        try install(source(version: "1.0.0"))
        let fileManager = FailingMoveFileManager()
        let brittle = PluginStore(rootURL: containerURL, fileManager: fileManager)
        let manifest = try XCTUnwrap(
            try? PluginManifestParser.parse(source: source(version: "2.0.0")).get())

        XCTAssertThrowsError(
            try brittle.install(
                source: source(version: "2.0.0"), manifest: manifest, origin: .paste))

        XCTAssertEqual(store.versions(of: "app.luna.test").map(\.description), ["1.0.0"])
        XCTAssertEqual(store.plugin(id: "app.luna.test")?.manifest.version.description, "1.0.0")
    }

    func testInstallingALowerVersionOverAnInstalledOneStillReplacesIt() throws {
        try install(source(version: "2.0.0"))
        try install(source(version: "1.0.0"))

        XCTAssertEqual(store.plugin(id: "app.luna.test")?.manifest.version.description, "1.0.0")
    }

    func testConsentedCapabilitiesAreRecordedAtInstall() throws {
        let text = """
        /* luna-plugin
        { "id": "app.luna.caps", "name": "Caps", "version": "1.0.0", "api": 1,
          "capabilities": ["fetch", "storage"] }
        */
        luna.register({});
        """
        try install(text)
        XCTAssertEqual(
            store.plugin(id: "app.luna.caps")?.state.consentedCapabilities, [.fetch, .storage])
    }

    // MARK: - Enabling and deleting

    func testSwitchingAPluginOffKeepsItsFileAndItsOrigin() throws {
        try install(source(), origin: .files)
        store.setEnabled(false, pluginID: "app.luna.test", isBundled: false)

        let plugin = store.plugin(id: "app.luna.test")
        XCTAssertEqual(plugin?.state.isEnabled, false)
        XCTAssertEqual(plugin?.state.origin, .files)
        XCTAssertNotNil(plugin?.sourceText())
    }

    func testDeletingRemovesEveryTraceOfThePlugin() throws {
        try install(source())
        try store.delete(pluginID: "app.luna.test")

        XCTAssertNil(store.plugin(id: "app.luna.test"))
        XCTAssertEqual(store.installedIDs(), [])
    }

    func testDeletingAPluginThatIsNotInstalledSaysSo() {
        XCTAssertThrowsError(try store.delete(pluginID: "app.luna.nope")) { error in
            XCTAssertEqual(error as? PluginStoreError, .notInstalled(id: "app.luna.nope"))
        }
    }

    func testAFolderWhoseFileNoLongerParsesIsNotAPlugin() throws {
        try install(source())
        let fileURL = store.fileURL(
            id: "app.luna.test", version: PluginVersion(major: 1, minor: 0, patch: 0))
        try Data("not a plugin".utf8).write(to: fileURL)

        XCTAssertNil(store.plugin(id: "app.luna.test"))
        // The id still has a folder, so the store lists it; the loader skips it.
        XCTAssertEqual(store.installedIDs(), ["app.luna.test"])
    }

    // MARK: - Bundled state and shadowing

    func testABundledPluginsEnabledStateLivesInItsOwnFile() {
        XCTAssertEqual(store.state("app.luna.bundled", isBundled: true).isEnabled, true)

        store.setEnabled(false, pluginID: "app.luna.bundled", isBundled: true)

        XCTAssertEqual(store.state("app.luna.bundled", isBundled: true).isEnabled, false)
        // The bundled state file is separate from any imported plugin's folder.
        XCTAssertEqual(store.installedIDs(), [])
    }

    func testAnImportedPluginWithABundledIdShadowsTheBundledCopy() throws {
        let bundleURL = containerURL.appendingPathComponent("bundle", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        try Data(source(id: "app.luna.shared", version: "1.0.0").utf8)
            .write(to: bundleURL.appendingPathComponent("shared.js"))
        let catalog = BundledPluginCatalog(source: .directory(bundleURL), store: store)

        // With no user copy the bundled one stands.
        let bundledOnly = catalog.plugins(shadowedBy: [])
        try install(source(id: "app.luna.shared", version: "9.9.9"))
        let installed = store.installedPlugins()
        let afterShadow = catalog.plugins(shadowedBy: installed)

        XCTAssertEqual(bundledOnly.map(\.id), ["app.luna.shared"])
        XCTAssertEqual(bundledOnly.first?.manifest.version.description, "1.0.0")
        XCTAssertEqual(bundledOnly.first?.isBundled, true)
        XCTAssertEqual(installed.map(\.id), ["app.luna.shared"])
        XCTAssertEqual(installed.first?.manifest.version.description, "9.9.9")
        XCTAssertEqual(afterShadow, [])
    }

    func testDeletingTheUserCopyLetsTheBundledOneStandAgain() throws {
        let bundleURL = containerURL.appendingPathComponent("bundle", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        try Data(source(id: "app.luna.shared", version: "1.0.0").utf8)
            .write(to: bundleURL.appendingPathComponent("shared.js"))
        let catalog = BundledPluginCatalog(source: .directory(bundleURL), store: store)
        try install(source(id: "app.luna.shared", version: "9.9.9"))

        try store.delete(pluginID: "app.luna.shared")

        XCTAssertEqual(
            catalog.plugins(shadowedBy: store.installedPlugins()).map(\.id),
            ["app.luna.shared"])
    }

    func testABundledPluginCarriesItsOwnEnabledState() throws {
        let bundleURL = containerURL.appendingPathComponent("bundle", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        try Data(source(id: "app.luna.shared").utf8)
            .write(to: bundleURL.appendingPathComponent("shared.js"))
        let catalog = BundledPluginCatalog(source: .directory(bundleURL), store: store)

        store.setEnabled(false, pluginID: "app.luna.shared", isBundled: true)

        XCTAssertEqual(catalog.plugins().first?.state.isEnabled, false)
    }

    func testACatalogWithNoBundleAnswersEmpty() {
        let catalog = BundledPluginCatalog(source: .empty, store: store)
        XCTAssertEqual(catalog.plugins().count, 0)
        XCTAssertEqual(catalog.sourceURLs().count, 0)
    }

    // MARK: - Import preview

    func testAPreviewOfANewPluginAsksForConsentForEveryCapability() throws {
        let importer = PluginImporter(
            store: store, bundled: BundledPluginCatalog(bundle: nil, store: store), runtime: nil)
        let text = """
        /* luna-plugin
        { "id": "app.luna.caps", "name": "Caps", "version": "1.0.0", "api": 1,
          "description": "Reads pages", "capabilities": ["fetch", "html"] }
        */
        luna.register({});
        """

        let preview = try importer.preview(sourceText: text)

        XCTAssertEqual(preview.summary.id, "app.luna.caps")
        XCTAssertEqual(preview.description, "Reads pages")
        XCTAssertEqual(preview.capabilities, [.fetch, .html])
        XCTAssertEqual(preview.addedCapabilities, [.fetch, .html])
        XCTAssertTrue(preview.requiresConsent)
        XCTAssertNil(preview.replacesVersion)
    }

    func testAnUpdateThatAddsNoCapabilityDoesNotAskAgain() throws {
        let importer = PluginImporter(
            store: store, bundled: BundledPluginCatalog(bundle: nil, store: store), runtime: nil)
        let first = """
        /* luna-plugin
        { "id": "app.luna.caps", "name": "Caps", "version": "1.0.0", "api": 1,
          "capabilities": ["fetch"] }
        */
        luna.register({});
        """
        try importer.install(try importer.preview(sourceText: first), origin: .paste)

        let same = first.replacingOccurrences(of: "1.0.0", with: "1.1.0")
        let preview = try importer.preview(sourceText: same)

        XCTAssertEqual(preview.replacesVersion, "1.0.0")
        XCTAssertEqual(preview.addedCapabilities, [])
        XCTAssertFalse(preview.requiresConsent)
    }

    func testAnUpdateThatAddsACapabilityAsksAgainAndNamesTheNewOne() throws {
        let importer = PluginImporter(
            store: store, bundled: BundledPluginCatalog(bundle: nil, store: store), runtime: nil)
        let first = """
        /* luna-plugin
        { "id": "app.luna.caps", "name": "Caps", "version": "1.0.0", "api": 1,
          "capabilities": ["fetch"] }
        */
        luna.register({});
        """
        try importer.install(try importer.preview(sourceText: first), origin: .paste)

        let widened = """
        /* luna-plugin
        { "id": "app.luna.caps", "name": "Caps", "version": "2.0.0", "api": 1,
          "capabilities": ["fetch", "secrets"] }
        */
        luna.register({});
        """
        let preview = try importer.preview(sourceText: widened)

        XCTAssertEqual(preview.addedCapabilities, [.secrets])
        XCTAssertTrue(preview.requiresConsent)
    }

    func testImporterRestoresTheCapturedSourceWhenActivationRejectsAnUpdate() throws {
        let first = source(version: "1.0.0")
        let initial = PluginImporter(
            store: store, bundled: BundledPluginCatalog(bundle: nil, store: store), runtime: nil)
        try initial.install(try initial.preview(sourceText: first), origin: .paste)

        let replacement = source(version: "2.0.0")
        let runtime = FailOnceActivationInvoker()
        let importer = PluginImporter(
            store: store, bundled: BundledPluginCatalog(bundle: nil, store: store), runtime: runtime)

        XCTAssertThrowsError(
            try importer.install(try importer.preview(sourceText: replacement), origin: .paste))
        XCTAssertEqual(store.plugin(id: "app.luna.test")?.manifest.version.description, "1.0.0")
        XCTAssertEqual(store.plugin(id: "app.luna.test")?.sourceText(), first)
        XCTAssertEqual(runtime.activationCalls, ["app.luna.test", "app.luna.test"])
    }

    func testAPreviewOfAMalformedHeaderThrowsTheParserSSentence() {
        let importer = PluginImporter(
            store: store, bundled: BundledPluginCatalog(bundle: nil, store: store), runtime: nil)
        XCTAssertThrowsError(try importer.preview(sourceText: "luna.register({});")) { error in
            XCTAssertEqual(error as? PluginManifestError, .noHeader)
            XCTAssertFalse((error as? PluginManifestError)?.message.isEmpty ?? true)
        }
    }
}

/// Refuses the one move `PluginStore.install` makes, so the failure path can be
/// asserted without a full disk.
private final class FailingMoveFileManager: FileManager, @unchecked Sendable {
    override func moveItem(at srcURL: URL, to dstURL: URL) throws {
        throw CocoaError(.fileWriteNoPermission)
    }
}

private final class FailOnceActivationInvoker: PluginHookInvoking {
    var loadedPlugins: [PluginSummary] = []
    var disabledPlugins: [String: String] = [:]
    private(set) var activationCalls: [String] = []

    func matchedPlugins(forHost host: String) -> [PluginSummary] { loadedPlugins }

    func invoke<T: Decodable>(
        _ hook: PluginHook, pluginID: String, argument: Encodable,
        timeout: TimeInterval, decode: T.Type
    ) async -> Result<T, PluginInvocationFailure> {
        .failure(.missingHook)
    }

    func activate(pluginID: String) throws {
        activationCalls.append(pluginID)
        if activationCalls.count == 1 {
            throw PluginActivationError(failure: .exception(message: "bad update", stack: nil))
        }
    }

    func reloadAll() {}
}
