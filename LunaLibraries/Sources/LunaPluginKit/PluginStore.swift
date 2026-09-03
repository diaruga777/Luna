//
//  PluginStore.swift
//  LunaPluginKit
//

import Foundation
import LunaAppConfig
import LunaModels

/// Why a plugin could not be installed, read or removed.
public enum PluginStoreError: Error, Equatable {
    case manifest(PluginManifestError)
    case notInstalled(id: String)
    /// A bundled plugin can be switched off, never deleted.
    case bundledCannotBeDeleted(id: String)
    case fileSystem(detail: String)
    case storageUnavailable

    public var message: String {
        switch self {
        case .manifest(let error): return error.message
        case .notInstalled(let id): return L10n.string("PluginImportError_notInstalled", id)
        case .bundledCannotBeDeleted(let id):
            return L10n.string("PluginImportError_bundledCannotBeDeleted", id)
        case .fileSystem(let detail): return L10n.string("PluginImportError_writeFailed", detail)
        case .storageUnavailable:
            return L10n.string("PluginImportError_writeFailed", "the App Group container is unavailable")
        }
    }
}

extension PluginStoreError: LocalizedError {
    public var errorDescription: String? { message }
}

/// What the store remembers about one plugin beside its file.
public struct PluginState: Equatable, Codable, Sendable {
    public var isEnabled: Bool
    public var installedAt: Date?
    public var origin: PluginImportOrigin?
    /// The capabilities the user agreed to. An update that adds one asks again.
    public var consentedCapabilities: [PluginCapabilityName]

    public init(
        isEnabled: Bool = true, installedAt: Date? = nil, origin: PluginImportOrigin? = nil,
        consentedCapabilities: [PluginCapabilityName] = []
    ) {
        self.isEnabled = isEnabled
        self.installedAt = installedAt
        self.origin = origin
        self.consentedCapabilities = consentedCapabilities
    }
}

/// One plugin the runtime can load: its parsed manifest, its source, and where
/// it came from.
public struct InstalledPlugin: Equatable, Sendable {
    public let manifest: PluginManifest
    public let sourceURL: URL
    public let state: PluginState
    public let isBundled: Bool

    public init(manifest: PluginManifest, sourceURL: URL, state: PluginState, isBundled: Bool) {
        self.manifest = manifest
        self.sourceURL = sourceURL
        self.state = state
        self.isBundled = isBundled
    }

    public var id: String { manifest.id }

    /// The plugin's own text, or nil when the file is gone or is not UTF-8.
    public func sourceText() -> String? {
        try? String(contentsOf: sourceURL, encoding: .utf8)
    }
}

/// The imported plugins on this device, in the §11.3 layout:
///
/// ```
/// <AppGroup>/Plugins/user/<id>/<version>/plugin.js
/// <AppGroup>/Plugins/user/<id>/state.json
/// <AppGroup>/Plugins/state/<bundledId>.json
/// <AppGroup>/Plugins/scratch/<id>/<generation>/
/// ```
///
/// The container is resolved on every call rather than kept, because
/// `-LunaStage` repoints the whole container and a remembered URL would keep
/// writing where the container used to be.
public final class PluginStore {

    public static let shared = PluginStore()

    private let overrideRootURL: URL?
    private let fileManager: FileManager

    /// A test (or a staged run) may pass its own root; nil means the App Group.
    public init(rootURL: URL? = nil, fileManager: FileManager = .default) {
        self.overrideRootURL = rootURL
        self.fileManager = fileManager
    }

    /// `<AppGroup>/Plugins/`, created on first use.
    public var rootURL: URL {
        resolvedRootURL ?? fileManager.temporaryDirectory
            .appendingPathComponent(".luna-plugin-storage-unavailable", isDirectory: true)
    }

    /// Production never writes to a temporary directory when App Group
    /// resolution fails. Explicit roots remain available for tests and staged
    /// runs, where a temporary root is an intentional dependency injection.
    public var storageAvailable: Bool {
        guard let root = resolvedRootURL else { return false }
        do {
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
            return true
        } catch { return false }
    }

    private var resolvedRootURL: URL? {
        if let overrideRootURL { return overrideRootURL }
        return AppConfig.sharedContainerURL(fileManager)?.appendingPathComponent(
            "Plugins", isDirectory: true)
    }

    public var userRootURL: URL { rootURL.appendingPathComponent("user", isDirectory: true) }
    /// Enabled state for BUNDLED plugins, which have no folder of their own.
    public var bundledStateRootURL: URL {
        rootURL.appendingPathComponent("state", isDirectory: true)
    }
    public var scratchRootURL: URL { rootURL.appendingPathComponent("scratch", isDirectory: true) }

    // MARK: - Reading

    /// Every imported plugin whose file still parses, id order.
    public func installedPlugins() -> [InstalledPlugin] {
        installedIDs().compactMap { plugin(id: $0) }.sorted { $0.id < $1.id }
    }

    public func installedIDs() -> [String] {
        guard storageAvailable else { return [] }
        let contents = (try? fileManager.contentsOfDirectory(
            at: userRootURL, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        return contents
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            .map { $0.lastPathComponent }
            .sorted()
    }

    /// The versions of one imported plugin, oldest first.
    public func versions(of pluginID: String) -> [PluginVersion] {
        guard storageAvailable else { return [] }
        let folder = userRootURL.appendingPathComponent(pluginID, isDirectory: true)
        let contents = (try? fileManager.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil)) ?? []
        return contents.compactMap { PluginVersion($0.lastPathComponent) }.sorted()
    }

    /// One imported plugin at its newest version. A file that no longer parses
    /// is not a plugin.
    public func plugin(id: String) -> InstalledPlugin? {
        guard let version = versions(of: id).last else { return nil }
        let sourceURL = fileURL(id: id, version: version)
        guard let source = try? String(contentsOf: sourceURL, encoding: .utf8),
              case .success(let manifest) = PluginManifestParser.parse(source: source)
        else { return nil }
        return InstalledPlugin(
            manifest: manifest, sourceURL: sourceURL, state: state(id), isBundled: false)
    }

    public func fileURL(id: String, version: PluginVersion) -> URL {
        userRootURL
            .appendingPathComponent(id, isDirectory: true)
            .appendingPathComponent(version.description, isDirectory: true)
            .appendingPathComponent("plugin.js")
    }

    // MARK: - Installing

    /// Writes the plugin's own text verbatim under its id and version, replacing
    /// whatever that id held.
    ///
    /// The replace happens through a scratch folder AND the new version lands
    /// before any old one is removed, so a failed write cannot leave the plugin
    /// half-installed or with no version at all. Older versions are removed
    /// after: only the newest is ever loaded, and a stale copy would confuse the
    /// source view.
    @discardableResult
    public func install(
        source: String, manifest: PluginManifest, origin: PluginImportOrigin, now: Date = Date()
    ) throws -> InstalledPlugin {
        guard storageAvailable else { throw PluginStoreError.storageUnavailable }
        let destination = fileURL(id: manifest.id, version: manifest.version)
            .deletingLastPathComponent()
        let idFolder = destination.deletingLastPathComponent()
        let scratch = rootURL.appendingPathComponent(
            ".installing-\(UUID().uuidString)", isDirectory: true)
        let backup = idFolder.appendingPathComponent(
            ".backup-\(UUID().uuidString)", isDirectory: true)
        let hadDestination = fileManager.fileExists(atPath: destination.path)
        let oldStateURL = stateURL(manifest.id, isBundled: false)
        let oldStateData = try? Data(contentsOf: oldStateURL)
        do {
            try fileManager.createDirectory(at: scratch, withIntermediateDirectories: true)
            try Data(source.utf8).write(
                to: scratch.appendingPathComponent("plugin.js"), options: .atomic)
            try fileManager.createDirectory(at: idFolder, withIntermediateDirectories: true)
            let replaced = versions(of: manifest.id).filter { $0 != manifest.version }
            if hadDestination { try fileManager.moveItem(at: destination, to: backup) }
            try fileManager.moveItem(at: scratch, to: destination)
            var state = self.state(manifest.id)
            state.isEnabled = true
            state.installedAt = now
            state.origin = origin
            state.consentedCapabilities = manifest.capabilities
            try writeChecked(state, id: manifest.id, isBundled: false)
            if hadDestination { try fileManager.removeItem(at: backup) }
            for stale in replaced {
                try? fileManager.removeItem(
                    at: idFolder.appendingPathComponent(stale.description, isDirectory: true))
            }
        } catch {
            try? fileManager.removeItem(at: scratch)
            try? fileManager.removeItem(at: destination)
            if hadDestination, fileManager.fileExists(atPath: backup.path) {
                try? fileManager.moveItem(at: backup, to: destination)
            }
            if let oldStateData {
                try? oldStateData.write(to: oldStateURL, options: .atomic)
            } else {
                try? fileManager.removeItem(at: oldStateURL)
            }
            throw PluginStoreError.fileSystem(detail: error.localizedDescription)
        }
        let state = self.state(manifest.id)
        return InstalledPlugin(
            manifest: manifest, sourceURL: fileURL(id: manifest.id, version: manifest.version),
            state: state, isBundled: false)
    }

    /// Restores a previously installed version after activation rejected an
    /// update. This uses the same staged replacement path as a normal install,
    /// then restores the exact prior state rather than resetting consent.
    func restore(
        _ previous: InstalledPlugin?, source: String?, pluginID: String
    ) throws {
        if let previous {
            guard let source else {
                throw PluginStoreError.fileSystem(detail: "the previous plugin source is gone")
            }
            _ = try install(
                source: source, manifest: previous.manifest,
                origin: previous.state.origin ?? .paste,
                now: previous.state.installedAt ?? Date())
            try writeChecked(previous.state, id: pluginID, isBundled: false)
        } else if fileManager.fileExists(
            atPath: userRootURL.appendingPathComponent(pluginID, isDirectory: true).path) {
            try delete(pluginID: pluginID)
        }
    }

    /// Removes an imported plugin and everything it stored on disk.
    public func delete(pluginID: String) throws {
        guard storageAvailable else { throw PluginStoreError.storageUnavailable }
        let folder = userRootURL.appendingPathComponent(pluginID, isDirectory: true)
        guard fileManager.fileExists(atPath: folder.path) else {
            throw PluginStoreError.notInstalled(id: pluginID)
        }
        do { try fileManager.removeItem(at: folder) } catch {
            throw PluginStoreError.fileSystem(detail: error.localizedDescription)
        }
        try? fileManager.removeItem(
            at: scratchRootURL.appendingPathComponent(pluginID, isDirectory: true))
    }

    // MARK: - State

    /// A bundled plugin's state lives in its own file, because the plugin has no
    /// folder in the container at all.
    public func state(_ pluginID: String, isBundled: Bool = false) -> PluginState {
        guard storageAvailable else { return PluginState() }
        let url = stateURL(pluginID, isBundled: isBundled)
        guard let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(PluginState.self, from: data)
        else { return PluginState() }
        return state
    }

    public func setEnabled(_ enabled: Bool, pluginID: String, isBundled: Bool) {
        try? setEnabledChecked(enabled, pluginID: pluginID, isBundled: isBundled)
    }

    public func setEnabledChecked(
        _ enabled: Bool, pluginID: String, isBundled: Bool
    ) throws {
        guard storageAvailable else { throw PluginStoreError.storageUnavailable }
        var state = self.state(pluginID, isBundled: isBundled)
        state.isEnabled = enabled
        try writeChecked(state, id: pluginID, isBundled: isBundled)
    }

    /// Records what the user agreed to, so an update that adds a capability can
    /// tell that it must ask again.
    public func recordConsent(
        _ capabilities: [PluginCapabilityName], pluginID: String, isBundled: Bool
    ) {
        try? recordConsentChecked(capabilities, pluginID: pluginID, isBundled: isBundled)
    }

    public func recordConsentChecked(
        _ capabilities: [PluginCapabilityName], pluginID: String, isBundled: Bool
    ) throws {
        guard storageAvailable else { throw PluginStoreError.storageUnavailable }
        var state = self.state(pluginID, isBundled: isBundled)
        state.consentedCapabilities = capabilities
        try writeChecked(state, id: pluginID, isBundled: isBundled)
    }

    public func write(_ state: PluginState, id: String, isBundled: Bool) {
        try? writeChecked(state, id: id, isBundled: isBundled)
    }

    private func writeChecked(_ state: PluginState, id: String, isBundled: Bool) throws {
        let url = stateURL(id, isBundled: isBundled)
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(state)
        try data.write(to: url, options: .atomic)
    }

    private func stateURL(_ pluginID: String, isBundled: Bool) -> URL {
        isBundled
            ? bundledStateRootURL.appendingPathComponent("\(pluginID).json")
            : userRootURL
                .appendingPathComponent(pluginID, isDirectory: true)
                .appendingPathComponent("state.json")
    }
}
