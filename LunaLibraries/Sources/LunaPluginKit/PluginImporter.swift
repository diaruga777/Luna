//
//  PluginImporter.swift
//  LunaPluginKit
//

import Foundation

/// Turns a plugin file's text into a consent preview, then into an install.
///
/// Nothing here evaluates the script: the preview is the parsed header, and the
/// install is a verbatim copy of the bytes the user handed over.
public final class PluginImporter: PluginImporting {

    private let store: PluginStore
    private let bundled: BundledPluginCatalog
    /// Reloaded after a successful install, so the new plugin is live without a
    /// relaunch. Held strongly: the runtime is a launch seam, not a view's
    /// delegate.
    private let runtime: PluginHookInvoking?

    public init(store: PluginStore, bundled: BundledPluginCatalog, runtime: PluginHookInvoking?) {
        self.store = store
        self.bundled = bundled
        self.runtime = runtime
    }

    public func preview(sourceText: String) throws -> PluginImportPreview {
        let manifest: PluginManifest
        switch PluginManifestParser.parse(source: sourceText) {
        case .success(let parsed): manifest = parsed
        case .failure(let error): throw error
        }
        let installed = store.plugin(id: manifest.id)
        let isBundled = installed == nil
            && bundled.plugins().contains { $0.id == manifest.id }
        let consented = Set(
            installed?.state.consentedCapabilities
                ?? (isBundled ? store.state(manifest.id, isBundled: true).consentedCapabilities : []))
        let added = manifest.capabilities.filter { !consented.contains($0) }
        return PluginImportPreview(
            summary: manifest.summary(hooks: [], isBundled: isBundled),
            description: manifest.description,
            capabilities: manifest.capabilities,
            runsInBackground: manifest.runsInBackground,
            addedCapabilities: added,
            requiresConsent: installed == nil || !added.isEmpty,
            replacesVersion: installed?.manifest.version.description,
            sourceText: sourceText)
    }

    public func install(_ preview: PluginImportPreview, origin: PluginImportOrigin) throws {
        let manifest: PluginManifest
        switch PluginManifestParser.parse(source: preview.sourceText) {
        case .success(let parsed): manifest = parsed
        case .failure(let error): throw error
        }
        try store.install(source: preview.sourceText, manifest: manifest, origin: origin)
        runtime?.reloadAll()
    }
}
