//
//  BundledPluginCatalog.swift
//  LunaPluginKit
//

import Foundation

/// The plugins Luna ships with, read out of the `LunaBundledPlugins` resource
/// bundle.
///
/// The bundle is INJECTED rather than imported: `LunaPluginKit` sits below
/// `LunaBundledPlugins` in the link graph, and only the four processes that run
/// plugins carry the resources. A catalog built with no bundle answers empty,
/// which is what a process with no bundled plugins should see.
public final class BundledPluginCatalog {

    /// Where the shipped `.js` files are read from.
    public enum Source {
        case bundle(Bundle, subdirectory: String)
        /// A plain directory of `.js` files. The staged catalogs and the test
        /// fixtures use it; a resource bundle is a directory with a wrapper.
        case directory(URL)
        /// A process that carries no bundled plugins.
        case empty
    }

    private let source: Source
    private let store: PluginStore
    private let manifestLock = NSLock()
    private var bundledManifests: [(manifest: PluginManifest, url: URL)]?

    public init(source: Source, store: PluginStore = .shared) {
        self.source = source
        self.store = store
    }

    public convenience init(
        bundle: Bundle?, subdirectory: String = "Plugins", store: PluginStore = .shared
    ) {
        self.init(
            source: bundle.map { .bundle($0, subdirectory: subdirectory) } ?? .empty,
            store: store)
    }

    /// Every bundled plugin whose header parses, id order.
    ///
    /// A plugin whose header is broken is DROPPED rather than reported: a
    /// bundled file is Luna's own, so a bad one is a build fault the suite
    /// catches, not a user-facing import error.
    public func plugins() -> [InstalledPlugin] {
        manifests().map { entry in
            installedPlugin(manifest: entry.manifest, url: entry.url)
        }
    }

    /// Resolve one schema without reading every other plugin's enabled state.
    public func plugin(id: String) -> InstalledPlugin? {
        guard let entry = manifests().first(where: { $0.manifest.id == id }) else { return nil }
        return installedPlugin(manifest: entry.manifest, url: entry.url)
    }

    private func installedPlugin(manifest: PluginManifest, url: URL) -> InstalledPlugin {
        InstalledPlugin(
            manifest: manifest, sourceURL: url,
            state: store.state(manifest.id, isBundled: true), isBundled: true)
    }

    /// App-bundle source is immutable for this process. Parse it once, but read
    /// enabled state afresh so changes from Settings or an extension still win.
    /// Directory catalogs remain live for staging and editable test fixtures.
    private func manifests() -> [(manifest: PluginManifest, url: URL)] {
        guard case .bundle = source else { return readManifests() }
        manifestLock.lock()
        defer { manifestLock.unlock() }
        if let bundledManifests { return bundledManifests }
        let entries = readManifests()
        bundledManifests = entries
        return entries
    }

    private func readManifests() -> [(manifest: PluginManifest, url: URL)] {
        sourceURLs().compactMap { url -> (manifest: PluginManifest, url: URL)? in
            guard let source = try? String(contentsOf: url, encoding: .utf8),
                  case .success(let manifest) = PluginManifestParser.parse(source: source)
            else { return nil }
            return (manifest, url)
        }
        .sorted { $0.manifest.id < $1.manifest.id }
    }

    /// The `.js` files the source holds, file-name order.
    public func sourceURLs() -> [URL] {
        let urls: [URL]
        switch source {
        case .empty:
            urls = []
        case .bundle(let bundle, let subdirectory):
            urls = bundle.urls(forResourcesWithExtension: "js", subdirectory: subdirectory) ?? []
        case .directory(let directory):
            let contents = (try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil)) ?? []
            urls = contents.filter { $0.pathExtension == "js" }
        }
        return urls.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Bundled plugins that no imported plugin shadows.
    ///
    /// An imported plugin with a bundled id REPLACES it while installed, so the
    /// bundled copy is the fallback after a delete rather than a second entry.
    public func plugins(shadowedBy installed: [InstalledPlugin]) -> [InstalledPlugin] {
        let shadowed = Set(installed.map(\.id))
        return plugins().filter { !shadowed.contains($0.id) }
    }
}
