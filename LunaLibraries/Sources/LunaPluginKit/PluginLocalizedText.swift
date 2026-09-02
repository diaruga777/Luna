//
//  PluginLocalizedText.swift
//  LunaPluginKit
//

import Foundation

/// Resolves a plugin's localized copy table (§2.2) against a list of
/// preferred language tags: an exact tag, then that tag's language
/// (`pt-BR` → `pt`), then `"en"`.
///
/// A manifest's localized fields resolve through this ONCE, at parse time
/// (`PluginManifestParser`), so `PluginSettingField.label` and its siblings
/// stay plain `String`s and no UI code reads a table. `luna.localize`
/// (`PluginBootstrapScript`, `plugin_host.js`, `bridge.mjs`) applies the same
/// rule to a table a plugin builds itself at runtime.
public enum PluginLocalizedText {

    /// The manifest parser only calls this once a table has already been
    /// checked to contain `"en"`; a plugin's own runtime table carries no such
    /// guarantee, so a table missing `"en"` falls back to an empty string.
    public static func resolve(_ table: [String: String], preferring languages: [String]) -> String {
        for language in languages {
            if let value = table[language] { return value }
        }
        for language in languages {
            if let value = table[languagePrefix(of: language)] { return value }
        }
        return table["en"] ?? ""
    }

    /// The primary language subtag of a BCP-47 tag: `"pt-BR"` → `"pt"`.
    static func languagePrefix(of tag: String) -> String {
        guard let dash = tag.firstIndex(of: "-") else { return tag }
        return String(tag[tag.startIndex..<dash])
    }
}
