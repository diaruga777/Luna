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

    private struct StagedImport {
        let manifest: PluginManifest
        let previous: InstalledPlugin?
        let previousSource: String?
    }

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
        let staged = try stage(preview, origin: origin)
        guard let runtime else { return }
        do {
            try runtime.activate(pluginID: staged.manifest.id)
        } catch {
            // The old source remains available as a value even though the new
            // version is currently staged in the store. Restore it before
            // rebuilding the runtime, so a failed update never leaves a
            // working installation disabled.
            do {
                try restore(staged)
                try runtime.activate(pluginID: staged.manifest.id)
            } catch let rollbackError {
                throw PluginStoreError.fileSystem(
                    detail: "activation failed (\(error)); rollback failed (\(rollbackError))")
            }
            throw error
        }
    }

    /// Transactional, nonblocking installation for UI callers. All runtime
    /// evaluation happens in `PluginRuntime.activateAsync`, so the main actor
    /// is never held while a candidate's top-level code is preflighted.
    public func installAsync(
        _ preview: PluginImportPreview, origin: PluginImportOrigin
    ) async throws {
        let staged = try stage(preview, origin: origin)
        guard let runtime else { return }
        do {
            try await runtime.activateAsync(pluginID: staged.manifest.id)
        } catch {
            do {
                try restore(staged)
                try await runtime.activateAsync(pluginID: staged.manifest.id)
            } catch let rollbackError {
                throw PluginStoreError.fileSystem(
                    detail: "activation failed (\(error)); rollback failed (\(rollbackError))")
            }
            throw error
        }
    }

    private func stage(
        _ preview: PluginImportPreview, origin: PluginImportOrigin
    ) throws -> StagedImport {
        let manifest: PluginManifest
        switch PluginManifestParser.parse(source: preview.sourceText) {
        case .success(let parsed): manifest = parsed
        case .failure(let error): throw error
        }
        let previous = store.plugin(id: manifest.id)
        let previousSource = previous?.sourceText()
        _ = try store.install(source: preview.sourceText, manifest: manifest, origin: origin)
        return StagedImport(
            manifest: manifest, previous: previous, previousSource: previousSource)
    }

    private func restore(_ staged: StagedImport) throws {
        try store.restore(
            staged.previous, source: staged.previousSource, pluginID: staged.manifest.id)
    }
}
