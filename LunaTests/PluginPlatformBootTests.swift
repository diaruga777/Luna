//
//  PluginPlatformBootTests.swift
//  LunaTests
//

import LunaBundledPlugins
import LunaFetch
import LunaIngest
import LunaMediaDownload
import LunaModels
import LunaPluginIngest
import LunaPluginKit
import LunaPluginRuntime
import XCTest

/// `PluginPlatformComposition.install()` builds the whole platform for one
/// process (`claudedocs/plans/plugin-platform.md` §2.3).
///
/// The suite runs the SHIPPED call against a scratch container and a fixture
/// bundle, so it asserts what a launching app gets: a runtime holding the
/// bundled plugins, the four `PluginPlatformServices` witnesses, and an ingest
/// stage bound to that runtime.
///
/// It replaces the test host's own platform while it runs, and `tearDown` puts
/// the shipped one back.
final class PluginPlatformBootTests: XCTestCase {

    private var containerURL: URL!
    private var store: PluginStore!
    private var keyValueStore: PluginKVStore!

    private static let toyPluginID = "test.luna.boot"

    private static let toyPlugin = """
        /* luna-plugin
        {
          "id": "\(toyPluginID)",
          "name": "Boot Fixture",
          "version": "1.0.0",
          "api": 1,
          "produces": ["media"],
          "match": { "hosts": ["boot.example.com"] },
          "priority": 100
        }
        */
        luna.register({
            classify({ url }) { return { kind: "media", itemId: "one" }; },
            async ingest({ url }) {
                return { kind: "media", assets: [
                    { url: "https://cdn.example.com/one.mp4", type: "video" }] };
            }
        });
        """

    override func setUpWithError() throws {
        try super.setUpWithError()
        containerURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("plugin-boot-\(UUID().uuidString)", isDirectory: true)
        let pluginsURL = containerURL
            .appendingPathComponent("Fixture.bundle", isDirectory: true)
            .appendingPathComponent("Plugins", isDirectory: true)
        try FileManager.default.createDirectory(at: pluginsURL, withIntermediateDirectories: true)
        try Self.toyPlugin.write(
            to: pluginsURL.appendingPathComponent("boot.js"), atomically: true, encoding: .utf8)
        store = PluginStore(rootURL: containerURL.appendingPathComponent("Plugins"))
        keyValueStore = PluginKVStore(
            fileURL: containerURL.appendingPathComponent("saves.sqlite"))
    }

    override func tearDown() {
        // The host app installed the shipped platform at launch; every later
        // suite reads it. Put it back before the scratch container goes away.
        PluginPlatformComposition.install(
            processKind: .app, bundledPluginsBundle: LunaBundledPluginsBundle.bundle)
        try? FileManager.default.removeItem(at: containerURL)
        containerURL = nil
        store = nil
        keyValueStore = nil
        super.tearDown()
    }

    private func fixtureBundle() throws -> Bundle {
        let url = containerURL.appendingPathComponent("Fixture.bundle", isDirectory: true)
        return try XCTUnwrap(Bundle(url: url), "no bundle at \(url.path)")
    }

    @discardableResult
    private func install() throws -> [PluginLoadReport] {
        PluginPlatformComposition.install(
            processKind: .app,
            bundledPluginsBundle: try fixtureBundle(),
            store: store,
            keyValueStore: keyValueStore)
    }

    func testInstallLoadsABundledPluginAndFillsEveryWitness() throws {
        let reports = try install()

        let report = try XCTUnwrap(reports.first { $0.pluginID == Self.toyPluginID })
        XCTAssertTrue(report.isLoaded, report.failure?.message ?? "no reason")
        let invoker = try XCTUnwrap(PluginPlatformServices.invoker)
        XCTAssertEqual(invoker.loadedPlugins.map(\.id), [Self.toyPluginID])
        XCTAssertNotNil(PluginPlatformServices.catalog)
        XCTAssertNotNil(PluginPlatformServices.importer)
        XCTAssertNotNil(PluginPlatformServices.settings)
        XCTAssertNotNil(IngestPipeline.pluginStage)
        XCTAssertNotNil(PluginMediaSeams.resolver)
        XCTAssertNotNil(PluginMediaSeams.reresolver)
    }

    /// The stage the install leaves behind runs the runtime the install built:
    /// the fixture plugin claims its host and answers a media Model.
    func testTheInstalledStageRunsTheLoadedPlugin() async throws {
        try install()
        let stage = try XCTUnwrap(IngestPipeline.pluginStage)

        let verdict = await stage.run(
            IngestInput(url: URL(string: "https://boot.example.com/clip")!, source: .manual),
            fetcher: ArticleFetcher())

        guard case let .outcome(_, pluginID) = verdict else {
            return XCTFail("the fixture plugin's Model was not adopted: \(verdict)")
        }
        XCTAssertEqual(pluginID, Self.toyPluginID)
    }

    /// Central Luna resolves media through its bundled plugins. Its two media
    /// wiring files must therefore name no Swift resolver: one that did would be
    /// a second, invisible answer to "what resolved this asset", and the
    /// Downloader's resolvers would quietly go on running in the central app.
    /// The shared shell asks `MediaAssetResolution`, which answers per app.
    func testTheCentralAppsMediaWiringNamesNoSwiftResolver() throws {
        let root = URL(fileURLWithPath: "\(#filePath)").deletingLastPathComponent()
            .deletingLastPathComponent()
        for path in ["Luna/KindWiring+Luna.swift", "Luna/MediaShellWiring.swift"] {
            let source = try String(
                contentsOf: root.appendingPathComponent(path), encoding: .utf8)
            XCTAssertFalse(
                source.contains("SocialMediaResolver("),
                "\(path) builds a Swift media resolver; central Luna uses its plugins")
        }
    }

    func testASecondInstallReplacesTheRuntimeWithoutDuplicatingThePlugin() throws {
        try install()
        let first = try XCTUnwrap(PluginPlatformServices.invoker)

        try install()

        let second = try XCTUnwrap(PluginPlatformServices.invoker)
        XCTAssertFalse(first === second, "the second install kept the first runtime")
        XCTAssertEqual(second.loadedPlugins.map(\.id), [Self.toyPluginID])
        XCTAssertEqual(second.matchedPlugins(forHost: "boot.example.com").count, 1)
    }
}
