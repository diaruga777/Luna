import LunaBundledPlugins
import LunaPluginKit
import LunaPluginRuntime
import XCTest

/// A media install outlives the app resource that supplied it. Build 132 used
/// PluginStore.install at launch; subsequent builds must keep loading its files.
final class MediaPluginPersistenceTests: XCTestCase {
    private var root: URL!
    private var store: PluginStore!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        store = PluginStore(rootURL: root.appendingPathComponent("Plugins"))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    private var sourceBundle: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/plugins/bundles/Luna-Media.lunabundle")
    }

    func testInstalledMediaLoadsInEveryProcessAfterItsOriginalBundleIsRemoved() throws {
        let archive = root.appendingPathComponent("Luna-Media.lunabundle")
        try FileManager.default.copyItem(at: sourceBundle, to: archive)
        let sources = try PluginBundleArchive.sources(in: Data(contentsOf: archive))
        XCTAssertEqual(sources.count, 14)
        for source in sources {
            let manifest = try PluginManifestParser.parse(source: source).get()
            try store.install(source: source, manifest: manifest, origin: .files)
        }
        try FileManager.default.removeItem(at: archive)
        let reopened = PluginStore(rootURL: store.rootURL)
        for kind in [PluginProcessKind.app, .share, .action] {
            let runtime = PluginRuntime(store: reopened,
                bundled: BundledPluginCatalog(source: .empty, store: reopened),
                processContext: PluginProcessContext(kind: kind), isolated: true)
            let reports = runtime.loadAll()
            XCTAssertEqual(reports.count, 14)
            XCTAssertTrue(reports.allSatisfy(\.isLoaded), "\(reports)")
            XCTAssertEqual(runtime.loadedPlugins.count, 14)
        }
        for plugin in reopened.installedPlugins() {
            XCTAssertFalse(plugin.isBundled)
            XCTAssertEqual(plugin.state.consentedCapabilities, plugin.manifest.capabilities)
        }
    }

    func testFreshStoreHasOnlySixNonMediaBundledPlugins() {
        let bundled = BundledPluginCatalog(bundle: LunaBundledPluginsBundle.bundle, store: store)
        let runtime = PluginRuntime(store: store, bundled: bundled,
            processContext: PluginProcessContext(kind: .app), isolated: true)
        XCTAssertTrue(store.installedPlugins().isEmpty)
        XCTAssertEqual(runtime.loadAll().count, 6)
        XCTAssertEqual(runtime.loadedPlugins.count, 6)
        XCTAssertFalse(bundled.plugins().contains { $0.manifest.produces.contains(.media) })
        XCTAssertNil(Bundle.main.url(forResource: "Luna-Media", withExtension: "lunabundle"))
    }

    func testPortableBundleMatchesTheFourteenMediaSourcesInTheRepository() throws {
        let sources = try PluginBundleArchive.sources(in: Data(contentsOf: sourceBundle))
        let directory = sourceBundle.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("media")
        let files = try FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: nil).filter { $0.pathExtension == "js" }
        XCTAssertEqual(files.count, 14)
        XCTAssertEqual(Set(sources), Set(try files.map { try String(contentsOf: $0, encoding: .utf8) }))
    }
}
