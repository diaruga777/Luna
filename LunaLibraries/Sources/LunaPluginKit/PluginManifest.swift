//
//  PluginManifest.swift
//  LunaPluginKit
//

import Foundation
import LunaModels

/// The `bluetooth` declaration (§10.1). The transport tier reads it; the
/// manifest layer only checks its shape, so a Wave-1 build parses a plugin
/// Wave 3 will run.
public struct PluginBluetoothDeclaration: Equatable, Codable, Sendable {
    public enum Pairing: String, Codable, Sendable { case accessorySetupKit, none }

    /// GATT service UUIDs the plugin talks to. They scope the discovery
    /// descriptors and the background restoration.
    public let services: [String]
    public let pairing: Pairing
    /// Keep a pending connect to paired peripherals, so a background wake can
    /// deliver `onBluetooth`.
    public let standingConnect: Bool

    public init(services: [String], pairing: Pairing, standingConnect: Bool) {
        self.services = services
        self.pairing = pairing
        self.standingConnect = standingConnect
    }
}

/// One plugin's header, parsed without evaluating its script.
///
/// The header is the only thing the consent screen and the store read, which is
/// why it is a leading block comment rather than a call the body makes: an
/// import decision must never run the code it is deciding about.
public struct PluginManifest: Equatable, Sendable {
    public let id: String
    public let name: String
    public let version: PluginVersion
    public let api: Int
    public let description: String?
    /// The Model kinds this plugin may return. Empty means it is not an ingest
    /// plugin.
    public let produces: [PluginModelKind]
    /// Exact hosts and `*.` suffix patterns, lowercased.
    public let hosts: [String]
    /// True for a plugin that runs after every host-matched plugin has passed.
    public let matchesAnyHost: Bool
    public let priority: Int
    public let capabilities: [PluginCapabilityName]
    public let export: PluginExportSummary?
    public let settings: [PluginSettingField]
    public let bluetooth: PluginBluetoothDeclaration?
    /// True lets `onBluetooth` and `export` run when the app is woken in the
    /// background. The consent screen shows it.
    public let runsInBackground: Bool

    public init(
        id: String, name: String, version: PluginVersion, api: Int, description: String?,
        produces: [PluginModelKind], hosts: [String], matchesAnyHost: Bool, priority: Int,
        capabilities: [PluginCapabilityName], export: PluginExportSummary?,
        settings: [PluginSettingField], bluetooth: PluginBluetoothDeclaration?,
        runsInBackground: Bool
    ) {
        self.id = id
        self.name = name
        self.version = version
        self.api = api
        self.description = description
        self.produces = produces
        self.hosts = hosts
        self.matchesAnyHost = matchesAnyHost
        self.priority = priority
        self.capabilities = capabilities
        self.export = export
        self.settings = settings
        self.bluetooth = bluetooth
        self.runsInBackground = runsInBackground
    }

    /// True when the manifest declares ingest work, so `classify` and `ingest`
    /// are both required (§3.3).
    public var isIngestPlugin: Bool { !produces.isEmpty }

    /// The hooks §3.3 requires of this manifest.
    public var requiredHooks: Set<PluginHook> {
        var hooks: Set<PluginHook> = []
        if isIngestPlugin { hooks.formUnion([.classify, .ingest]) }
        if export != nil { hooks.insert(.export) }
        if bluetooth != nil { hooks.insert(.onBluetooth) }
        return hooks
    }

    /// The seam shape the ingest and export stages read.
    public func summary(hooks: Set<PluginHook>, isBundled: Bool) -> PluginSummary {
        PluginSummary(
            id: id, name: name, version: version.description, priority: priority,
            matchesAnyHost: matchesAnyHost, hostPatterns: hosts, produces: produces,
            hooks: hooks, export: export, isBundled: isBundled)
    }
}
