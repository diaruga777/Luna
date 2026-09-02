//
//  PluginSettingValueCoding.swift
//  LunaPluginUI
//
//  Turns a settings field's edited value into the JSON fragment
//  `PluginSettingsStoring` stores, and reads one back for display. Every
//  value that crosses `luna.settings` is JSON (plugin-platform.md §11.1), so
//  a plain string still needs its quotes.
//

import Foundation

enum PluginSettingValueCoding {

    static func encodeString(_ value: String) -> String {
        (try? String(data: JSONEncoder().encode(value), encoding: .utf8)) ?? "\"\""
    }

    static func decodeString(_ json: String?) -> String? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(String.self, from: data)
    }

    static func encodeBool(_ value: Bool) -> String { value ? "true" : "false" }

    static func decodeBool(_ json: String?) -> Bool {
        guard let json, let data = json.data(using: .utf8) else { return false }
        return (try? JSONDecoder().decode(Bool.self, from: data)) ?? false
    }

    static func encodeNumber(_ value: Double) -> String {
        (try? String(data: JSONEncoder().encode(value), encoding: .utf8)) ?? "0"
    }

    static func decodeNumber(_ json: String?) -> Double? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Double.self, from: data)
    }
}
