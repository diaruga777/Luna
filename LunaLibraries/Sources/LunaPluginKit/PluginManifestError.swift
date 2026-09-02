//
//  PluginManifestError.swift
//  LunaPluginKit
//

import Foundation
import LunaModels

/// Why a plugin file did not parse.
///
/// A plugin author reading the import screen is a first-class user of this
/// type, so every case names the FIELD it is about and the LINE in the file
/// where that field sits. `message` is the sentence the screen shows.
public enum PluginManifestError: Error, Equatable {
    /// No leading `/* luna-plugin … */` block comment.
    case noHeader
    /// The header comment holds no JSON object, or unparseable JSON.
    case headerNotJSON(line: Int, detail: String)
    case missingField(field: String, line: Int)
    case invalidField(field: String, line: Int, detail: String)
    /// The plugin needs a newer platform than this build has.
    case apiTooNew(declared: Int, supported: Int)
    case unknownCapability(name: String, line: Int)
    /// The bytes are not UTF-8 text.
    case notText(name: String)
    case sourceTooLarge(limitKB: Int)

    /// The field this error is about, or nil when the whole header failed.
    public var field: String? {
        switch self {
        case .noHeader, .notText, .sourceTooLarge: return nil
        case .headerNotJSON: return nil
        case .missingField(let field, _): return field
        case .invalidField(let field, _, _): return field
        case .apiTooNew: return "api"
        case .unknownCapability: return "capabilities"
        }
    }

    /// The 1-based line in the plugin file, or nil when the error is about the
    /// file rather than a place in it.
    public var line: Int? {
        switch self {
        case .noHeader, .notText, .sourceTooLarge, .apiTooNew: return nil
        case .headerNotJSON(let line, _): return line
        case .missingField(_, let line): return line
        case .invalidField(_, let line, _): return line
        case .unknownCapability(_, let line): return line
        }
    }

    /// One sentence a plugin author can act on.
    public var message: String {
        switch self {
        case .noHeader:
            return L10n.string("PluginImportError_noHeader")
        case .headerNotJSON(let line, let detail):
            return L10n.string("PluginImportError_headerNotJSON", line, detail)
        case .missingField(let field, let line):
            return L10n.string("PluginImportError_missingField", field, line)
        case .invalidField(let field, let line, let detail):
            return L10n.string("PluginImportError_invalidField", field, line, detail)
        case .apiTooNew(let declared, let supported):
            return L10n.string("PluginImportError_apiTooNew", declared, supported)
        case .unknownCapability(let name, let line):
            return L10n.string("PluginImportError_unknownCapability", name, line)
        case .notText(let name):
            return L10n.string("PluginImportError_notText", name)
        case .sourceTooLarge(let limitKB):
            return L10n.string("PluginImportError_sourceTooLarge", limitKB)
        }
    }
}

extension PluginManifestError: LocalizedError {
    public var errorDescription: String? { message }
}
