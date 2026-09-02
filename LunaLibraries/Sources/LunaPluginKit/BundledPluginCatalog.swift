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

    private let bundle: Bundle?
    private let subdirectory: String
    private let store: PluginStore

    public init(bundle: Bundle?, subdirectory: String = "Plugins", store: PluginStore = .shared) {
        self.bundle = bundle
        self.subdirectory = subdirectory
        self.store = store
    }

    /// Every bundled plugin whose header parses, id order.
    ///
    /// A plugin whose header is broken is DROPPED rather than reported: a
    /// bundled file is Luna's own, so a bad one is a build fault the suite
    /// catches, not a user-facing import error.
    public func plugins() -> [InstalledPlugin] {
        sourceURLs().compactMap { url in
            guard let source = try? String(contentsOf: url, encoding: .utf8),
                  case .success(let manifest) = PluginManifestParser.parse(source: source)
            else { return nil }
            return InstalledPlugin(
                manifest: manifest, sourceURL: url,
                state: store.state(manifest.id, isBundled: true), isBundled: true)
        }
        .sorted { $0.id < $1.id }
    }

    /// The `.js` files in the bundle's plugins subdirectory.
    public func sourceURLs() -> [URL] {
        guard let bundle else { return [] }
        let urls = bundle.urls(
            forResourcesWithExtension: "js", subdirectory: subdirectory) ?? []
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
