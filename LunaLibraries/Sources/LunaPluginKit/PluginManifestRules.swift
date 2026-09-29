//
//  PluginManifestRules.swift
//  LunaPluginKit
//

import Foundation

/// The manifest limits `PluginManifestParser` enforces, as data.
///
/// `tools/plugin-sim/run.mjs` used to re-implement them in JavaScript and
/// drifted: the harness accepted a 60-character name the app then rejected.
/// The harness reads `Resources/PluginManifestRules.json` out of this
/// repository, this type reads the same file out of the module bundle, and
/// `PluginManifestRulesParityTests` compares every value to the parser's own
/// constants — so the file cannot quietly say something the parser does not do.
public struct PluginManifestRules: Decodable, Equatable, Sendable {

    public struct APIRule: Decodable, Equatable, Sendable {
        public let current: Int
    }

    public struct SourceRule: Decodable, Equatable, Sendable {
        public let maxKB: Int
    }

    public struct IDRule: Decodable, Equatable, Sendable {
        public let characters: String
        public let maxLength: Int
        public let forbidsLeadingDot: Bool
        public let forbidsTrailingDot: Bool
        public let forbidsDoubleDot: Bool
    }

    public struct LengthRule: Decodable, Equatable, Sendable {
        public let maxLength: Int
    }

    public struct VersionRule: Decodable, Equatable, Sendable {
        public let maxLength: Int
        public let pattern: String
    }

    public let api: APIRule
    public let source: SourceRule
    public let id: IDRule
    public let name: LengthRule
    public let description: LengthRule
    public let version: VersionRule
    public let kinds: [String]
    public let capabilities: [String]
    public let exportInputFormats: [String]
    public let settingTypes: [String]
    public let hooks: [String]
    public let exportInputsByKind: [String: [String]]

    /// The bundled table. `nil` only when the resource is missing from the
    /// build, which is the one thing the parity test cannot repair.
    public static let bundled: PluginManifestRules? = {
        guard let url = Bundle.module.url(
            forResource: "PluginManifestRules", withExtension: "json"),
            let data = try? Data(contentsOf: url)
        else { return nil }
        return try? JSONDecoder().decode(PluginManifestRules.self, from: data)
    }()
}
