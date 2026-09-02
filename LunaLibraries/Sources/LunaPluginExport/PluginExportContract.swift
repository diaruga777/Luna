//
//  PluginExportContract.swift
//  LunaPluginExport
//

import Foundation
import LunaModels
import LunaPluginKit

/// The `ExportInput` one `export` call receives
/// (`claudedocs/plans/plugin-platform.md` §9.2).
///
/// It is the WHOLE argument: the runtime encodes it to JSON and hands it to the
/// hook, so a field absent here is a field the plugin cannot see.
public struct PluginExportInput: Encodable, Equatable {
    public let kind: PluginModelKind
    public let saveID: UUID
    public let url: String
    public let title: String
    public let format: PluginExportInputFormat
    /// Set for `epub`, `pdf`, `docx` and `file`. The plugin reads it through
    /// `luna.files.read` or hands it back in its result.
    public let file: PluginExportFileHandle?
    /// Set for `markdown`, `text` and `html`.
    public let text: String?
    /// Set for `json`.
    public let json: PluginExportJSON?
    /// True when the send coordinator is delivering a queued send, false for a
    /// share-row tap.
    public let auto: Bool
    /// The save's `CaptureSource` raw value.
    public let source: String?
    /// Other saves still queued for this destination.
    public let queuedRemaining: Int?

    public init(
        kind: PluginModelKind, saveID: UUID, url: String, title: String,
        format: PluginExportInputFormat, file: PluginExportFileHandle? = nil,
        text: String? = nil, json: PluginExportJSON? = nil, auto: Bool,
        source: String? = nil, queuedRemaining: Int? = nil
    ) {
        self.kind = kind
        self.saveID = saveID
        self.url = url
        self.title = title
        self.format = format
        self.file = file
        self.text = text
        self.json = json
        self.auto = auto
        self.source = source
        self.queuedRemaining = queuedRemaining
    }

    private enum CodingKeys: String, CodingKey {
        case kind, saveId, url, title, format, file, text, json, auto, source, queuedRemaining
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encode(saveID.uuidString, forKey: .saveId)
        try container.encode(url, forKey: .url)
        try container.encode(title, forKey: .title)
        try container.encode(format, forKey: .format)
        try container.encodeIfPresent(file, forKey: .file)
        try container.encodeIfPresent(text, forKey: .text)
        try container.encodeIfPresent(json, forKey: .json)
        try container.encode(auto, forKey: .auto)
        try container.encodeIfPresent(source, forKey: .source)
        try container.encodeIfPresent(queuedRemaining, forKey: .queuedRemaining)
    }
}

/// The `FileHandle` shape `luna.files` uses, as an export input or result
/// carries it (§6.7).
public struct PluginExportFileHandle: Codable, Equatable {
    public let id: String
    public let name: String
    public let size: Int
    public let mime: String?

    public init(id: String, name: String, size: Int, mime: String?) {
        self.id = id
        self.name = name
        self.size = size
        self.mime = mime
    }

    public init(_ descriptor: PluginFileDescriptor) {
        self.init(
            id: descriptor.id, name: descriptor.name, size: descriptor.size,
            mime: descriptor.mime)
    }

    public var descriptor: PluginFileDescriptor {
        PluginFileDescriptor(id: id, name: name, size: size, mime: mime)
    }
}

/// A JSON document an export input carries, as values rather than text.
///
/// Luna's models are `Codable`, but the runtime encodes a hook's argument with
/// its own `JSONEncoder`, whose date strategy is not the plugin API's. Re-reading
/// the model's own encoding into this tree is what pins a date to ISO-8601 on
/// the way to the plugin.
public enum PluginExportJSON: Encodable, Equatable {
    case object([String: PluginExportJSON])
    case array([PluginExportJSON])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    /// Encodes `value` with the plugin API's own strategies and reads the
    /// result back as a value tree. Nil when the value cannot encode.
    public static func encoding(_ value: any Encodable) -> PluginExportJSON? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(PluginExportEncodableBox(value)),
              let object = try? JSONSerialization.jsonObject(
                with: data, options: [.fragmentsAllowed])
        else { return nil }
        return PluginExportJSON(jsonObject: object)
    }

    public init(jsonObject: Any) {
        switch jsonObject {
        case let dictionary as [String: Any]:
            self = .object(dictionary.mapValues { PluginExportJSON(jsonObject: $0) })
        case let list as [Any]:
            self = .array(list.map { PluginExportJSON(jsonObject: $0) })
        case let text as String:
            self = .string(text)
        case let number as NSNumber:
            // CFBoolean answers to NSNumber, so the boolean check comes first.
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else {
                self = .number(number.doubleValue)
            }
        default:
            self = .null
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .object(let members):
            var container = encoder.container(keyedBy: PluginExportJSONKey.self)
            for (key, value) in members.sorted(by: { $0.key < $1.key }) {
                try container.encode(value, forKey: PluginExportJSONKey(stringValue: key))
            }
        case .array(let values):
            var container = encoder.unkeyedContainer()
            for value in values { try container.encode(value) }
        case .string(let text):
            var container = encoder.singleValueContainer()
            try container.encode(text)
        case .number(let number):
            var container = encoder.singleValueContainer()
            // A whole number reaches the plugin as one: JavaScript has one
            // number type, and `1` reads better than `1.0` in a log line.
            if number == number.rounded(), abs(number) < 9_007_199_254_740_992 {
                try container.encode(Int64(number))
            } else {
                try container.encode(number)
            }
        case .bool(let flag):
            var container = encoder.singleValueContainer()
            try container.encode(flag)
        case .null:
            var container = encoder.singleValueContainer()
            try container.encodeNil()
        }
    }
}

struct PluginExportJSONKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

/// Encodes an `Encodable` existential, which `JSONEncoder` will not take
/// directly in the package's Swift 5 language mode.
struct PluginExportEncodableBox: Encodable {
    private let wrapped: any Encodable
    init(_ wrapped: any Encodable) { self.wrapped = wrapped }
    func encode(to encoder: Encoder) throws { try wrapped.encode(to: encoder) }
}

/// What an `export` hook answered (§9.2).
///
/// The union is decoded by SHAPE, in the plan's order, so a plugin that adds a
/// field Luna does not read still lands on the branch its main field names.
public enum PluginExportResult: Decodable, Equatable {

    /// The status a destination reports for its own bookkeeping.
    public enum Status: String, Decodable, Equatable {
        case sent, failed, retry
    }

    /// `null` — the plugin handled the save itself and nothing is presented.
    case handled
    /// A file to hand to the share sheet.
    case file(PluginExportFileHandle, name: String?, mime: String?)
    /// Text to hand to the share sheet, written to a temporary file first.
    case text(String, name: String?, mime: String?)
    /// A URL to hand to the share sheet.
    case url(String)
    /// A destination's outcome. `hard` makes a failure terminal.
    case status(Status, message: String?, hard: Bool)

    private enum CodingKeys: String, CodingKey {
        case file, text, url, status, name, mime, message, hard
    }

    public init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(), single.decodeNil() {
            self = .handled
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let name = try container.decodeIfPresent(String.self, forKey: .name)
        let mime = try container.decodeIfPresent(String.self, forKey: .mime)
        if let handle = try container.decodeIfPresent(
            PluginExportFileHandle.self, forKey: .file) {
            self = .file(handle, name: name, mime: mime)
            return
        }
        if let text = try container.decodeIfPresent(String.self, forKey: .text) {
            self = .text(text, name: name, mime: mime)
            return
        }
        if let url = try container.decodeIfPresent(String.self, forKey: .url) {
            self = .url(url)
            return
        }
        if let status = try container.decodeIfPresent(Status.self, forKey: .status) {
            self = .status(
                status,
                message: try container.decodeIfPresent(String.self, forKey: .message),
                hard: try container.decodeIfPresent(Bool.self, forKey: .hard) ?? false)
            return
        }
        throw DecodingError.dataCorrupted(DecodingError.Context(
            codingPath: container.codingPath,
            debugDescription: "an export result must be null, or carry file, text, url or status"))
    }
}
