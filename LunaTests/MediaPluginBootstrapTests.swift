import LunaPluginKit
import LunaPluginRuntime
import XCTest
@testable import Luna

final class MediaPluginBootstrapTests: XCTestCase {
    private var root: URL!
    private var store: PluginStore!
    private var archive: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        store = PluginStore(rootURL: root.appendingPathComponent("Plugins"))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("docs/plugins/bundles/Luna-Media.lunabundle")
        archive = root.appendingPathComponent("Luna-Media.lunabundle")
        try FileManager.default.copyItem(at: source, to: archive)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    func testInstallsAllFourteenPluginsPermanentlyWithoutTheAppResource() throws {
        try MediaPluginBootstrap.install(bundleURL: archive, store: store)
        XCTAssertEqual(store.installedPlugins().count, 14)
        for plugin in store.installedPlugins() {
            XCTAssertFalse(plugin.isBundled)
            XCTAssertTrue(plugin.state.isEnabled)
            XCTAssertEqual(plugin.state.consentedCapabilities, plugin.manifest.capabilities)
        }
        try FileManager.default.removeItem(at: archive)
        // Model the next app version: only persistent storage, no media resource
        // and no installer. Its runtime must still load every plugin.
        let reopened = PluginStore(rootURL: store.rootURL)
        let runtime = PluginRuntime(store: reopened,
            bundled: BundledPluginCatalog(source: .empty, store: reopened),
            processContext: PluginProcessContext(kind: .app), isolated: true)
        let reports = runtime.loadAll()
        XCTAssertEqual(reports.count, 14)
        XCTAssertTrue(reports.allSatisfy(\.isLoaded), "\(reports)")
        XCTAssertEqual(runtime.loadedPlugins.count, 14)
    }

    func testRelaunchPreservesDisabledPluginsAndDoesNotResurrectDeletedOnes() throws {
        try MediaPluginBootstrap.install(bundleURL: archive, store: store)
        let plugins = store.installedPlugins()
        let disabled = try XCTUnwrap(plugins.first)
        let deleted = plugins[1]
        try store.setEnabledChecked(false, pluginID: disabled.id, isBundled: false)
        try store.delete(pluginID: deleted.id)
        let token = store.changeToken
        try MediaPluginBootstrap.install(bundleURL: archive, store: store)
        XCTAssertFalse(try XCTUnwrap(store.plugin(id: disabled.id)).state.isEnabled)
        XCTAssertNil(store.plugin(id: deleted.id))
        XCTAssertEqual(store.changeToken, token)
    }

    func testExistingCustomSourceAndStateArePreserved() throws {
        let original = try XCTUnwrap(PluginBundleArchive.sources(in: Data(contentsOf: archive)).first)
        let source = original + "\n// User customization\n"
        let manifest = try PluginManifestParser.parse(source: source).get()
        try store.install(source: source, manifest: manifest, origin: .paste)
        try store.setEnabledChecked(false, pluginID: manifest.id, isBundled: false)
        let before = store.plugin(id: manifest.id)
        try MediaPluginBootstrap.install(bundleURL: archive, store: store)
        XCTAssertEqual(store.plugin(id: manifest.id), before)
        XCTAssertEqual(store.plugin(id: manifest.id)?.sourceText(), source)
    }

    func testLegacyBundledDisabledStateIsPreserved() throws {
        let source = try XCTUnwrap(PluginBundleArchive.sources(in: Data(contentsOf: archive)).first)
        let manifest = try PluginManifestParser.parse(source: source).get()
        try store.setEnabledChecked(false, pluginID: manifest.id, isBundled: true)
        try MediaPluginBootstrap.install(bundleURL: archive, store: store)
        XCTAssertFalse(try XCTUnwrap(store.plugin(id: manifest.id)).state.isEnabled)
    }

    func testInvalidArchiveDoesNotPreventRetryWithAValidOne() throws {
        let invalid = root.appendingPathComponent("invalid.lunabundle")
        try Data("invalid".utf8).write(to: invalid)
        XCTAssertThrowsError(try MediaPluginBootstrap.install(bundleURL: invalid, store: store))
        XCTAssertTrue(store.installedPlugins().isEmpty)
        try MediaPluginBootstrap.install(bundleURL: archive, store: store)
        XCTAssertEqual(store.installedPlugins().count, 14)
    }

    func testCoreAppPackagesTheExactSourceBundle() throws {
        let shipped = try XCTUnwrap(Bundle.main.url(forResource: "Luna-Media", withExtension: "lunabundle"))
        XCTAssertEqual(try Data(contentsOf: shipped), try Data(contentsOf: archive))
    }
}
