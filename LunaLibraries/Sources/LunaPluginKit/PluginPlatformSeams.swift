//
//  PluginPlatformSeams.swift
//  LunaPluginKit
//
//  The contracts the plugin platform's tiers agree on. The runtime (LunaPluginRuntime)
//  provides witnesses; the ingest stage, the export stage and the Settings UI consume
//  them. Every witness is installed by `PluginPlatformComposition.install()`.
//  Governing plan: claudedocs/plans/plugin-platform.md §3.2, §7.1, §7.2, §11.
//

import Foundation
import LunaModels

// MARK: - Capabilities

/// The bridge namespaces a plugin can declare. The raw value is the manifest spelling
/// and the `luna.<name>` property name.
public enum PluginCapabilityName: String, CaseIterable, Codable, Sendable {
    case fetch, html, page, storage, secrets, files, crypto, browser, downloads
    case settings, ui, mail, notifications, bluetooth, wifi, exports
}

// MARK: - Hooks

public enum PluginHook: String, Codable, Sendable, CaseIterable {
    case classify, ingest, export, onBluetooth, onSettingsChanged, onAction
}

/// Why a hook call produced no usable value.
public enum PluginInvocationFailure: Error, Equatable, Sendable {
    /// The plugin is not loaded, or is disabled.
    case notLoaded
    /// The plugin registered no such hook.
    case missingHook
    /// The call exceeded its budget and was abandoned; the JS may still be running.
    case timedOut
    /// An earlier abandoned call still holds the runtime; nothing can run until it returns.
    case wedged
    /// The hook threw. `message` is the JS error text, `stack` when available.
    case exception(message: String, stack: String?)
    /// The settled value did not decode as the expected shape.
    case malformedResult(String)
    /// `luna.browser.open` was called where no browser can be shown; the request is stored
    /// and the save must lock. Only `ingest` produces this.
    case browserDeferred
    /// The runtime refused the call for a reason the caller cannot fix (bridge fault).
    case runtime(String)
}

/// A plugin activation could not be made live. The store remains untouched by
/// callers that stage an update until this error is resolved.
public struct PluginActivationError: Error, Equatable, Sendable {
    public let failure: PluginInvocationFailure

    public init(failure: PluginInvocationFailure) { self.failure = failure }
}

/// Which native process is running plugin JS. Bridges use it to decide availability.
public enum PluginProcessKind: String, Codable, Sendable {
    case app, share, action
}

/// What the ingest and export stages need to know about a loaded plugin without
/// seeing the runtime's own manifest type.
public struct PluginSummary: Equatable, Sendable {
    public let id: String
    public let name: String
    public let version: String
    public let priority: Int
    public let matchesAnyHost: Bool
    /// Exact hosts and `*.` suffix patterns from the manifest's `match.hosts`.
    public let hostPatterns: [String]
    public let produces: [PluginModelKind]
    public let hooks: Set<PluginHook>
    public let export: PluginExportSummary?
    public let isBundled: Bool

    public init(id: String, name: String, version: String, priority: Int, matchesAnyHost: Bool,
                hostPatterns: [String], produces: [PluginModelKind], hooks: Set<PluginHook>,
                export: PluginExportSummary?, isBundled: Bool) {
        self.id = id; self.name = name; self.version = version; self.priority = priority
        self.matchesAnyHost = matchesAnyHost; self.hostPatterns = hostPatterns
        self.produces = produces; self.hooks = hooks; self.export = export; self.isBundled = isBundled
    }

    /// True when `host` is an exact entry or ends with a `*.` pattern's suffix (dot included).
    public func matches(host: String) -> Bool {
        if matchesAnyHost { return true }
        let lower = host.lowercased()
        for pattern in hostPatterns {
            let p = pattern.lowercased()
            if p.hasPrefix("*.") {
                let suffix = String(p.dropFirst(1))          // ".example.com"
                if lower.hasSuffix(suffix) || lower == String(p.dropFirst(2)) { return true }
            } else if lower == p {
                return true
            }
        }
        return false
    }
}

/// The manifest's `export` declaration, as the export stage and Settings see it (§9.1).
public struct PluginExportSummary: Equatable, Codable, Sendable {
    public let kinds: [PluginModelKind]
    public let input: String              // ExportInputFormat raw value
    public let epubProfile: String?       // "standard" | "compact"
    public let epubImages: Bool
    public let title: String
    public let symbol: String?
    public let isDestination: Bool
    public let requiresSettings: [String]
    /// The destination's receiver files a delivered save away once it is read
    /// there, so Luna drops a still-queued send whose save was finished in
    /// Luna first (`ReadStateSendReconciler`).
    public let dequeueOnRead: Bool

    public init(kinds: [PluginModelKind], input: String, epubProfile: String?, epubImages: Bool,
                title: String, symbol: String?, isDestination: Bool, requiresSettings: [String],
                dequeueOnRead: Bool = false) {
        self.kinds = kinds; self.input = input; self.epubProfile = epubProfile; self.epubImages = epubImages
        self.title = title; self.symbol = symbol; self.isDestination = isDestination
        self.requiresSettings = requiresSettings; self.dequeueOnRead = dequeueOnRead
    }
}

/// Invokes plugin hooks. The runtime is the witness; stages never see `JSContext`.
public protocol PluginHookInvoking: AnyObject {
    /// Loaded, enabled plugins sorted by (host-matched before any-host, priority descending, id).
    var loadedPlugins: [PluginSummary] { get }
    /// Disabled plugins and why, keyed by id.
    var disabledPlugins: [String: String] { get }
    /// The host pre-filter over `loadedPlugins`, preserving order.
    func matchedPlugins(forHost host: String) -> [PluginSummary]
    /// Calls `hook` with `argument` encoded to JSON, awaits a returned Promise, decodes the
    /// settled value from `JSON.stringify`. `timeout` is wall-clock except for `.ingest`,
    /// where the bridge's activity resets the idle budget.
    func invoke<T: Decodable>(_ hook: PluginHook, pluginID: String, argument: Encodable,
                              timeout: TimeInterval, decode: T.Type) async -> Result<T, PluginInvocationFailure>
    /// Correlated form used by save/pipeline callers. The default keeps older
    /// witnesses source-compatible while the runtime records the metadata.
    func invoke<T: Decodable>(
        _ hook: PluginHook, pluginID: String, argument: Encodable, timeout: TimeInterval,
        decode: T.Type, invocationID: UUID, diagnosticRecorder: SaveDiagnosticsRecorder?
    ) async -> Result<T, PluginInvocationFailure>
    /// Activates one plugin after an import or settings change. Implementations
    /// should validate the candidate and reload only this plugin.
    func activate(pluginID: String) throws
    /// Async activation for UI callers. Implementations must not block the
    /// caller's actor while evaluating top-level JavaScript.
    func activateAsync(pluginID: String) async throws
    /// Re-reads the store and reloads every plugin whose file or state changed.
    func reloadAll()
}

public extension PluginHookInvoking {
    func activateAsync(pluginID: String) async throws { try activate(pluginID: pluginID) }

    func invoke<T: Decodable>(
        _ hook: PluginHook, pluginID: String, argument: Encodable, timeout: TimeInterval,
        decode: T.Type, invocationID: UUID, diagnosticRecorder: SaveDiagnosticsRecorder?
    ) async -> Result<T, PluginInvocationFailure> {
        await invoke(hook, pluginID: pluginID, argument: argument, timeout: timeout, decode: decode)
    }

    /// Legacy witnesses that cannot activate one plugin keep their old reload
    /// behavior. The concrete runtime overrides this with transactional
    /// preflight and a single-plugin reload.
    func activate(pluginID: String) throws { reloadAll() }
}

// MARK: - Settings schema (§11.1)

public enum PluginSettingFieldType: String, Codable, Sendable, CaseIterable {
    case text, email, url, password, number, toggle, choice, pairedDevice, action, info
}

public struct PluginSettingOption: Equatable, Codable, Sendable {
    public let id: String
    public let label: String
    public init(id: String, label: String) { self.id = id; self.label = label }
}

public struct PluginSettingField: Equatable, Codable, Sendable {
    public let key: String
    public let type: PluginSettingFieldType
    public let label: String
    public let help: String?
    public let placeholder: String?
    public let options: [PluginSettingOption]
    /// JSON-encoded default, or nil.
    public let defaultJSON: String?
    public let isRequired: Bool
    public let isSecret: Bool

    public init(key: String, type: PluginSettingFieldType, label: String, help: String? = nil,
                placeholder: String? = nil, options: [PluginSettingOption] = [], defaultJSON: String? = nil,
                isRequired: Bool = false, isSecret: Bool = false) {
        self.key = key; self.type = type; self.label = label; self.help = help; self.placeholder = placeholder
        self.options = options; self.defaultJSON = defaultJSON; self.isRequired = isRequired; self.isSecret = isSecret
    }
}

/// Reads and writes a plugin's settings values. Values are JSON fragments; a secret field
/// reads back as `"\"\""` (an empty JSON string) when set.
public protocol PluginSettingsStoring: AnyObject {
    func valueJSON(pluginID: String, key: String) -> String?
    func setValueJSON(_ json: String?, pluginID: String, key: String) throws
    func allValuesJSON(pluginID: String) -> [String: String]
    /// True when every `isRequired` field has a value.
    func isConfigured(pluginID: String, fields: [PluginSettingField]) -> Bool
}

// MARK: - Catalog and import (Settings → Plugins, §11.2)

public enum PluginStatus: Equatable, Sendable {
    case enabled
    case disabled
    /// Disabled by the runtime after repeated timeouts.
    case stopped(reason: String)
    case loadFailed(message: String)
}

/// One row of Settings → Plugins.
public struct PluginListing: Equatable, Sendable {
    public let summary: PluginSummary
    public let description: String?
    public let status: PluginStatus
    public let capabilities: [PluginCapabilityName]
    public let runsInBackground: Bool
    public let settings: [PluginSettingField]

    public init(summary: PluginSummary, description: String?, status: PluginStatus,
                capabilities: [PluginCapabilityName], runsInBackground: Bool, settings: [PluginSettingField]) {
        self.summary = summary; self.description = description; self.status = status
        self.capabilities = capabilities; self.runsInBackground = runsInBackground; self.settings = settings
    }
}

public protocol PluginCatalogProviding: AnyObject {
    func listings() -> [PluginListing]
    func listing(pluginID: String) -> PluginListing?
    /// The installed file's text, for the read-only source view.
    func sourceText(pluginID: String) -> String?
    func setEnabled(_ enabled: Bool, pluginID: String) throws
    /// Removes an imported plugin. A bundled plugin cannot be deleted; this throws.
    func delete(pluginID: String) throws
}

/// What the consent screen shows before anything is written (§15).
public struct PluginImportPreview: Equatable, Sendable {
    public let summary: PluginSummary
    public let description: String?
    public let capabilities: [PluginCapabilityName]
    public let runsInBackground: Bool
    /// Capabilities not consented to before, for an update of an installed id. Equals
    /// `capabilities` on first install.
    public let addedCapabilities: [PluginCapabilityName]
    public let requiresConsent: Bool
    /// The installed version this import replaces, if any.
    public let replacesVersion: String?
    public let sourceText: String

    public init(summary: PluginSummary, description: String?, capabilities: [PluginCapabilityName],
                runsInBackground: Bool, addedCapabilities: [PluginCapabilityName], requiresConsent: Bool,
                replacesVersion: String?, sourceText: String) {
        self.summary = summary; self.description = description; self.capabilities = capabilities
        self.runsInBackground = runsInBackground; self.addedCapabilities = addedCapabilities
        self.requiresConsent = requiresConsent; self.replacesVersion = replacesVersion; self.sourceText = sourceText
    }
}

public enum PluginImportOrigin: String, Codable, Sendable { case files, paste }

public protocol PluginImporting: AnyObject {
    /// Parses the header without evaluating the script. Throws a descriptive error naming
    /// the field and line on a malformed header or an unsupported `api`.
    func preview(sourceText: String) throws -> PluginImportPreview
    /// Writes the file and state, records consent for `preview.capabilities`, reloads the runtime.
    func install(_ preview: PluginImportPreview, origin: PluginImportOrigin) throws
    /// Nonblocking counterpart for UI callers. The default preserves the
    /// legacy synchronous importer witness until its caller adopts async work.
    func installAsync(_ preview: PluginImportPreview, origin: PluginImportOrigin) async throws
}

public extension PluginImporting {
    func installAsync(_ preview: PluginImportPreview, origin: PluginImportOrigin) async throws {
        try install(preview, origin: origin)
    }
}

// MARK: - Registry

/// The witnesses. Installed once per process by `PluginPlatformComposition.install()`;
/// nil in a process that runs no plugins.
public enum PluginPlatformServices {
    public static var invoker: PluginHookInvoking?
    public static var catalog: PluginCatalogProviding?
    public static var importer: PluginImporting?
    public static var settings: PluginSettingsStoring?
    /// The scratch directories this process's `luna.files` is serving. The
    /// export tier writes a hook's input file into the SAME store: a
    /// descriptor's id-to-file map is in memory, so a second store could not
    /// resolve a handle this one handed to the plugin.
    public static var scratch: PluginScratchStore?
}
