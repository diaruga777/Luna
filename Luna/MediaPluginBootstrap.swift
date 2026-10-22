import Foundation
import LunaPluginKit

/// Build 132 only: turn the shipped media sources into ordinary persistent
/// installs before the runtime loads. Later builds remove this file and resource.
enum MediaPluginBootstrap {
    static func install(bundleURL: URL, store: PluginStore = .shared) throws {
        let sources = try PluginBundleArchive.sources(in: Data(contentsOf: bundleURL))
        guard store.storageAvailable else { throw PluginStoreError.storageUnavailable }
        let markers = store.rootURL.appendingPathComponent("media-bootstrap-132", isDirectory: true)
        try FileManager.default.createDirectory(at: markers, withIntermediateDirectories: true)
        for source in sources {
            let manifest = try PluginManifestParser.parse(source: source).get()
            let marker = markers.appendingPathComponent(manifest.id)
            guard !FileManager.default.fileExists(atPath: marker.path) else { continue }
            // Preserve imported/custom versions and their permissions/enabled state.
            if store.plugin(id: manifest.id) == nil {
                let enabled = store.state(manifest.id, isBundled: true).isEnabled
                try store.install(source: source, manifest: manifest, origin: .files)
                if !enabled {
                    try store.setEnabledChecked(false, pluginID: manifest.id, isBundled: false)
                }
            }
            // A successful install stays removable: subsequent launches must not
            // resurrect a plugin the user deleted. Failed members retry next launch.
            try Data().write(to: marker, options: .atomic)
        }
    }
}
