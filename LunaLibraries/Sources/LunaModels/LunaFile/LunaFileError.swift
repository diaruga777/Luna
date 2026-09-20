//
//  LunaFileError.swift
//  LunaModels
//

import Foundation

/// Why a Luna file was refused. Every case reads as one sentence a card can
/// show, and names the line an author must fix whenever there is one.
public enum LunaFileError: Error, Equatable {
    /// No leading `/* luna-… */` comment, or an unrecognized marker.
    case noHeader
    case headerNotJSON(line: Int, detail: String)
    case missingField(field: String, line: Int)
    case invalidField(field: String, line: Int, detail: String)
    /// The header declares a format version this build does not read.
    case unsupportedAPIVersion(declared: Int, supported: Int)
    /// The header's `kind` and the content's `kind` disagree.
    case kindMismatch(header: PluginModelKind, content: PluginModelKind)
    case bodyNotJSON(detail: String)
    case fileTooLarge(limitKB: Int)
    /// The bytes are not UTF-8 text.
    case notText

    /// The 1-based line in the file, or nil when the error is about the file
    /// rather than a place in it.
    public var line: Int? {
        switch self {
        case .noHeader, .unsupportedAPIVersion, .kindMismatch, .bodyNotJSON,
             .fileTooLarge, .notText:
            return nil
        case .headerNotJSON(let line, _): return line
        case .missingField(_, let line): return line
        case .invalidField(_, let line, _): return line
        }
    }

    /// The same error with `line` filled in. A type decoded below the header
    /// cannot know where it sits in the file, so it reports line 0 and the
    /// caller — which does know — stamps the body's line here.
    public func atLine(_ line: Int) -> LunaFileError {
        switch self {
        case .missingField(let field, 0): return .missingField(field: field, line: line)
        case .invalidField(let field, 0, let detail):
            return .invalidField(field: field, line: line, detail: detail)
        default: return self
        }
    }

    /// One sentence the failed card or the import screen shows.
    public var message: String {
        switch self {
        case .noHeader:
            return L10n.string("LunaFileError_noHeader")
        case .headerNotJSON(let line, let detail):
            return L10n.string("LunaFileError_headerNotJSON", line, detail)
        case .missingField(let field, let line):
            return L10n.string("LunaFileError_missingField", field, line)
        case .invalidField(let field, let line, let detail):
            return L10n.string("LunaFileError_invalidField", field, line, detail)
        case .unsupportedAPIVersion(let declared, let supported):
            return L10n.string("LunaFileError_unsupportedAPIVersion", declared, supported)
        case .kindMismatch(let header, let content):
            return L10n.string("LunaFileError_kindMismatch", header.rawValue, content.rawValue)
        case .bodyNotJSON(let detail):
            return L10n.string("LunaFileError_bodyNotJSON", detail)
        case .fileTooLarge(let limitKB):
            return L10n.string("LunaFileError_fileTooLarge", limitKB)
        case .notText:
            return L10n.string("LunaFileError_notText")
        }
    }
}

extension LunaFileError: LocalizedError {
    public var errorDescription: String? { message }
}
