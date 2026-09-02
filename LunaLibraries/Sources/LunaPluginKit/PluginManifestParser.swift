//
//  PluginManifestParser.swift
//  LunaPluginKit
//

import Foundation
import LunaModels

/// Reads a plugin file's header into a `PluginManifest`, or says which field
/// stopped it and on which line.
///
/// Hand-written rather than `Codable`: a `DecodingError` names a coding path,
/// not a rule, and the author reading the message needs to be told what to
/// write. The SCRIPT is never evaluated here — the consent screen and the store
/// decide about a plugin without running it.
public enum PluginManifestParser {

    /// Characters a plugin id may use. The id is also a DIRECTORY name in the
    /// shared container, so a separator or a dot-dot cannot appear in it.
    static let idCharacters = Set("abcdefghijklmnopqrstuvwxyz0123456789.-")

    /// The largest plugin file the parser accepts. Safari's message channel
    /// caps a served source at 1.5 MB (§17), so a larger file could never run
    /// in every process that is supposed to run it.
    public static let maxSourceKB = 1024

    public static let idMaxLength = 100
    public static let nameMaxLength = 40
    public static let descriptionMaxLength = 200

    // MARK: - Entry point

    /// Parses the leading `/* luna-plugin … */` header of a plugin file.
    public static func parse(source: String) -> Result<PluginManifest, PluginManifestError> {
        guard source.utf8.count <= maxSourceKB * 1024 else {
            return .failure(.sourceTooLarge(limitKB: maxSourceKB))
        }
        let header: Header
        switch extractHeader(from: source) {
        case .success(let extracted): header = extracted
        case .failure(let error): return .failure(error)
        }
        let object: [String: Any]
        do {
            let parsed = try JSONSerialization.jsonObject(
                with: Data(header.json.utf8), options: [])
            guard let dictionary = parsed as? [String: Any] else {
                return .failure(.headerNotJSON(
                    line: header.jsonStartLine, detail: "the header is not a { … } object"))
            }
            object = dictionary
        } catch {
            return .failure(.headerNotJSON(
                line: header.jsonStartLine, detail: error.localizedDescription))
        }
        do {
            return .success(try manifest(from: object, lines: header))
        } catch let error as PluginManifestError {
            return .failure(error)
        } catch {
            return .failure(.headerNotJSON(
                line: header.jsonStartLine, detail: error.localizedDescription))
        }
    }

    // MARK: - The header comment

    /// Where the header sits in the file, so an error can name a line.
    struct Header {
        let json: String
        /// 1-based line of the header's opening `/*`.
        let commentStartLine: Int
        /// 1-based line the JSON object starts on.
        let jsonStartLine: Int
        /// Lines of the JSON text, for locating one field.
        let jsonLines: [String]

        /// The line a field is written on, or the JSON's first line when the
        /// field is absent.
        func line(of field: String) -> Int {
            let needle = "\"\(field)\""
            for (offset, text) in jsonLines.enumerated() where text.contains(needle) {
                return jsonStartLine + offset
            }
            return jsonStartLine
        }
    }

    static func extractHeader(from source: String) -> Result<Header, PluginManifestError> {
        var index = source.startIndex
        var line = 1
        while index < source.endIndex, source[index].isWhitespace {
            if source[index] == "\n" { line += 1 }
            index = source.index(after: index)
        }
        guard source[index...].hasPrefix("/*") else { return .failure(.noHeader) }
        let commentStartLine = line
        let bodyStart = source.index(index, offsetBy: 2)
        guard let closeRange = source.range(of: "*/", range: bodyStart..<source.endIndex) else {
            return .failure(.noHeader)
        }
        let body = String(source[bodyStart..<closeRange.lowerBound])
        var bodyLines = body.components(separatedBy: "\n")
        guard let first = bodyLines.first,
              first.trimmingCharacters(in: .whitespaces).hasPrefix("luna-plugin")
        else { return .failure(.noHeader) }
        bodyLines.removeFirst()
        // The JSON is everything after the marker line. A leading `{` on the
        // marker line itself is not supported: the marker names the format, and
        // the object below it is what an author reads.
        let jsonText = bodyLines.joined(separator: "\n")
        guard jsonText.contains("{") else {
            return .failure(.headerNotJSON(
                line: commentStartLine + 1, detail: "the header holds no { … } object"))
        }
        return .success(Header(
            json: jsonText, commentStartLine: commentStartLine,
            jsonStartLine: commentStartLine + 1, jsonLines: bodyLines))
    }

    // MARK: - Fields

    private static func manifest(
        from object: [String: Any], lines: Header
    ) throws -> PluginManifest {
        let api = try apiVersion(object, lines)
        let id = try pluginID(object, lines)
        let name = try boundedString(
            object, "name", limit: nameMaxLength, lines: lines, required: true)!
        let version = try self.version(object, lines)
        let description = try boundedString(
            object, "description", limit: descriptionMaxLength, lines: lines, required: false)
        let produces = try self.produces(object, lines)
        let match = try self.match(object, lines, isIngest: !produces.isEmpty)
        let priority = try self.priority(object, lines)
        let capabilities = try self.capabilities(object, lines)
        let export = try self.export(object, lines)
        let settings = try self.settings(object, lines)
        let bluetooth = try self.bluetooth(object, lines, capabilities: capabilities)
        let background = try flag(object, "background", lines) ?? false
        return PluginManifest(
            id: id, name: name, version: version, api: api, description: description,
            produces: produces, hosts: match.hosts, matchesAnyHost: match.any,
            priority: priority, capabilities: capabilities, export: export,
            settings: settings, bluetooth: bluetooth, runsInBackground: background)
    }

    private static func pluginID(_ object: [String: Any], _ lines: Header) throws -> String {
        let id = try boundedString(object, "id", limit: idMaxLength, lines: lines, required: true)!
        guard id.allSatisfy({ idCharacters.contains($0) }) else {
            throw PluginManifestError.invalidField(
                field: "id", line: lines.line(of: "id"),
                detail: "an id may use lower-case letters, digits, '.' and '-' only — "
                    + "it is also the folder the plugin is stored in")
        }
        guard !id.hasPrefix("."), !id.hasSuffix("."), !id.contains("..") else {
            throw PluginManifestError.invalidField(
                field: "id", line: lines.line(of: "id"),
                detail: "an id may not start or end with '.', or contain '..'")
        }
        return id
    }

    private static func version(_ object: [String: Any], _ lines: Header) throws -> PluginVersion {
        let text = try boundedString(object, "version", limit: 32, lines: lines, required: true)!
        guard let version = PluginVersion(text) else {
            throw PluginManifestError.invalidField(
                field: "version", line: lines.line(of: "version"),
                detail: "\"\(text)\" is not a version like 1.0.0")
        }
        return version
    }

    private static func apiVersion(_ object: [String: Any], _ lines: Header) throws -> Int {
        guard let value = object["api"] else {
            throw PluginManifestError.missingField(field: "api", line: lines.jsonStartLine)
        }
        guard let number = value as? NSNumber, isWholeNumber(number), number.intValue >= 1 else {
            throw PluginManifestError.invalidField(
                field: "api", line: lines.line(of: "api"),
                detail: "it must be a whole number, 1 or more")
        }
        guard number.intValue <= PluginAPIVersion.current else {
            throw PluginManifestError.apiTooNew(
                declared: number.intValue, supported: PluginAPIVersion.current)
        }
        return number.intValue
    }

    private static func produces(
        _ object: [String: Any], _ lines: Header
    ) throws -> [PluginModelKind] {
        guard let raw = object["produces"] else { return [] }
        guard let list = raw as? [String], !list.isEmpty else {
            throw PluginManifestError.invalidField(
                field: "produces", line: lines.line(of: "produces"),
                detail: "it must be a non-empty list of \"article\", \"media\" or \"product\"")
        }
        var kinds: [PluginModelKind] = []
        for name in list {
            guard let kind = PluginModelKind(rawValue: name) else {
                throw PluginManifestError.invalidField(
                    field: "produces", line: lines.line(of: "produces"),
                    detail: "\"\(name)\" is not a Model kind — "
                        + "use \"article\", \"media\" or \"product\"")
            }
            if !kinds.contains(kind) { kinds.append(kind) }
        }
        return kinds
    }

    private static func match(
        _ object: [String: Any], _ lines: Header, isIngest: Bool
    ) throws -> (hosts: [String], any: Bool) {
        guard let raw = object["match"] else {
            guard isIngest else { return ([], false) }
            throw PluginManifestError.missingField(field: "match", line: lines.jsonStartLine)
        }
        guard let match = raw as? [String: Any] else {
            throw PluginManifestError.invalidField(
                field: "match", line: lines.line(of: "match"),
                detail: "it must be an object with \"hosts\" or \"any\": true")
        }
        var anyHost = false
        if let value = match["any"] {
            guard let flag = value as? NSNumber, isBoolean(flag) else {
                throw PluginManifestError.invalidField(
                    field: "match.any", line: lines.line(of: "any"),
                    detail: "it must be true or false")
            }
            anyHost = flag.boolValue
        }
        var hosts: [String] = []
        if let value = match["hosts"] {
            guard let list = value as? [String] else {
                throw PluginManifestError.invalidField(
                    field: "match.hosts", line: lines.line(of: "hosts"),
                    detail: "it must be a list of host strings")
            }
            for host in list {
                let lowered = host.trimmingCharacters(in: .whitespaces).lowercased()
                guard !lowered.isEmpty, !lowered.contains("/") else {
                    throw PluginManifestError.invalidField(
                        field: "match.hosts", line: lines.line(of: "hosts"),
                        detail: "\"\(host)\" is not a host — write \"example.com\" "
                            + "or \"*.example.com\"")
                }
                if !hosts.contains(lowered) { hosts.append(lowered) }
            }
        }
        guard anyHost || !hosts.isEmpty else {
            throw PluginManifestError.invalidField(
                field: "match.hosts", line: lines.line(of: "match"),
                detail: "list the hosts this plugin claims, or set \"any\": true — "
                    + "the host pre-filter is what keeps classification cheap")
        }
        return (hosts, anyHost)
    }

    private static func priority(_ object: [String: Any], _ lines: Header) throws -> Int {
        guard let value = object["priority"] else { return 0 }
        guard let number = value as? NSNumber, isWholeNumber(number), !isBoolean(number) else {
            throw PluginManifestError.invalidField(
                field: "priority", line: lines.line(of: "priority"),
                detail: "it must be a whole number — matched plugins run highest first")
        }
        return number.intValue
    }

    private static func capabilities(
        _ object: [String: Any], _ lines: Header
    ) throws -> [PluginCapabilityName] {
        guard let raw = object["capabilities"] else { return [] }
        guard let list = raw as? [String] else {
            throw PluginManifestError.invalidField(
                field: "capabilities", line: lines.line(of: "capabilities"),
                detail: "it must be a list of capability names")
        }
        var names: [PluginCapabilityName] = []
        for raw in list {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            guard let name = PluginCapabilityName(rawValue: trimmed) else {
                throw PluginManifestError.unknownCapability(
                    name: trimmed, line: lines.line(of: "capabilities"))
            }
            if !names.contains(name) { names.append(name) }
        }
        return names
    }

    private static func export(
        _ object: [String: Any], _ lines: Header
    ) throws -> PluginExportSummary? {
        guard let raw = object["export"] else { return nil }
        guard let export = raw as? [String: Any] else {
            throw PluginManifestError.invalidField(
                field: "export", line: lines.line(of: "export"),
                detail: "it must be an object with \"kinds\", \"input\" and \"title\"")
        }
        guard let rawKinds = export["kinds"] as? [String], !rawKinds.isEmpty else {
            throw PluginManifestError.invalidField(
                field: "export.kinds", line: lines.line(of: "kinds"),
                detail: "it must be a non-empty list of Model kinds")
        }
        var kinds: [PluginModelKind] = []
        for name in rawKinds {
            guard let kind = PluginModelKind(rawValue: name) else {
                throw PluginManifestError.invalidField(
                    field: "export.kinds", line: lines.line(of: "kinds"),
                    detail: "\"\(name)\" is not a Model kind")
            }
            if !kinds.contains(kind) { kinds.append(kind) }
        }
        guard let input = export["input"] as? String,
              PluginExportInputFormat(rawValue: input) != nil
        else {
            throw PluginManifestError.invalidField(
                field: "export.input", line: lines.line(of: "input"),
                detail: "it must be one of "
                    + PluginExportInputFormat.allCases.map(\.rawValue).joined(separator: ", "))
        }
        guard let title = export["title"] as? String, !title.isEmpty, title.count <= 40 else {
            throw PluginManifestError.invalidField(
                field: "export.title", line: lines.line(of: "title"),
                detail: "it must be a share-row label of at most 40 characters")
        }
        var epubProfile: String?
        var epubImages = true
        if let options = export["inputOptions"] as? [String: Any],
           let epub = options["epub"] as? [String: Any] {
            if let profile = epub["profile"] as? String {
                guard profile == "standard" || profile == "compact" else {
                    throw PluginManifestError.invalidField(
                        field: "export.inputOptions.epub.profile", line: lines.line(of: "profile"),
                        detail: "it must be \"standard\" or \"compact\"")
                }
                epubProfile = profile
            }
            if let images = epub["images"] as? NSNumber, isBoolean(images) {
                epubImages = images.boolValue
            }
        }
        var requires: [String] = []
        if let raw = export["requiresSettings"] {
            guard let list = raw as? [String] else {
                throw PluginManifestError.invalidField(
                    field: "export.requiresSettings", line: lines.line(of: "requiresSettings"),
                    detail: "it must be a list of setting keys")
            }
            requires = list
        }
        let destination = (export["destination"] as? NSNumber).map(\.boolValue) ?? false
        return PluginExportSummary(
            kinds: kinds, input: input, epubProfile: epubProfile, epubImages: epubImages,
            title: title, symbol: export["symbol"] as? String, isDestination: destination,
            requiresSettings: requires)
    }

    private static func settings(
        _ object: [String: Any], _ lines: Header
    ) throws -> [PluginSettingField] {
        guard let raw = object["settings"] else { return [] }
        guard let list = raw as? [[String: Any]] else {
            throw PluginManifestError.invalidField(
                field: "settings", line: lines.line(of: "settings"),
                detail: "it must be a list of { \"key\": …, \"type\": …, \"label\": … }")
        }
        var seen: Set<String> = []
        var fields: [PluginSettingField] = []
        for entry in list {
            guard let key = entry["key"] as? String, !key.isEmpty,
                  key.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" })
            else {
                throw PluginManifestError.invalidField(
                    field: "settings.key", line: lines.line(of: "key"),
                    detail: "a key uses letters, digits and '_' only")
            }
            guard !key.hasPrefix("_") else {
                throw PluginManifestError.invalidField(
                    field: "settings.key", line: lines.line(of: "key"),
                    detail: "keys starting with '_' are reserved for Luna")
            }
            guard seen.insert(key).inserted else {
                throw PluginManifestError.invalidField(
                    field: "settings.key", line: lines.line(of: "key"),
                    detail: "the key \"\(key)\" is listed twice")
            }
            guard let rawType = entry["type"] as? String,
                  let type = PluginSettingFieldType(rawValue: rawType)
            else {
                throw PluginManifestError.invalidField(
                    field: "settings.type", line: lines.line(of: "type"),
                    detail: "it must be one of "
                        + PluginSettingFieldType.allCases.map(\.rawValue)
                            .joined(separator: ", "))
            }
            guard let label = entry["label"] as? String, !label.isEmpty else {
                throw PluginManifestError.invalidField(
                    field: "settings.label", line: lines.line(of: "label"),
                    detail: "every field needs a label")
            }
            var options: [PluginSettingOption] = []
            if type == .choice {
                guard let rawOptions = entry["options"] as? [[String: Any]], !rawOptions.isEmpty
                else {
                    throw PluginManifestError.invalidField(
                        field: "settings.options", line: lines.line(of: "options"),
                        detail: "a \"choice\" field needs a non-empty \"options\" list")
                }
                for option in rawOptions {
                    guard let id = option["id"] as? String, !id.isEmpty,
                          let optionLabel = option["label"] as? String, !optionLabel.isEmpty
                    else {
                        throw PluginManifestError.invalidField(
                            field: "settings.options", line: lines.line(of: "options"),
                            detail: "every option needs an \"id\" and a \"label\"")
                    }
                    options.append(PluginSettingOption(id: id, label: optionLabel))
                }
            }
            var defaultJSON: String?
            if let value = entry["default"],
               let data = try? JSONSerialization.data(
                withJSONObject: value, options: [.fragmentsAllowed]) {
                defaultJSON = String(decoding: data, as: UTF8.self)
            }
            fields.append(PluginSettingField(
                key: key, type: type, label: label, help: entry["help"] as? String,
                placeholder: entry["placeholder"] as? String, options: options,
                defaultJSON: defaultJSON,
                isRequired: (entry["required"] as? NSNumber)?.boolValue ?? false,
                isSecret: (entry["secret"] as? NSNumber)?.boolValue ?? false))
        }
        return fields
    }

    private static func bluetooth(
        _ object: [String: Any], _ lines: Header, capabilities: [PluginCapabilityName]
    ) throws -> PluginBluetoothDeclaration? {
        guard let raw = object["bluetooth"] else { return nil }
        guard let declaration = raw as? [String: Any] else {
            throw PluginManifestError.invalidField(
                field: "bluetooth", line: lines.line(of: "bluetooth"),
                detail: "it must be an object with \"services\" and \"pairing\"")
        }
        guard capabilities.contains(.bluetooth) else {
            throw PluginManifestError.invalidField(
                field: "bluetooth", line: lines.line(of: "bluetooth"),
                detail: "a bluetooth declaration needs the \"bluetooth\" capability")
        }
        guard let services = declaration["services"] as? [String], !services.isEmpty else {
            throw PluginManifestError.invalidField(
                field: "bluetooth.services", line: lines.line(of: "services"),
                detail: "list the GATT service UUIDs the plugin talks to")
        }
        let rawPairing = (declaration["pairing"] as? String) ?? "none"
        guard let pairing = PluginBluetoothDeclaration.Pairing(rawValue: rawPairing) else {
            throw PluginManifestError.invalidField(
                field: "bluetooth.pairing", line: lines.line(of: "pairing"),
                detail: "it must be \"accessorySetupKit\" or \"none\"")
        }
        return PluginBluetoothDeclaration(
            services: services, pairing: pairing,
            standingConnect: (declaration["standingConnect"] as? NSNumber)?.boolValue ?? false)
    }

    // MARK: - Helpers

    private static func boundedString(
        _ object: [String: Any], _ field: String, limit: Int, lines: Header, required: Bool
    ) throws -> String? {
        guard let value = object[field] else {
            guard required else { return nil }
            throw PluginManifestError.missingField(field: field, line: lines.jsonStartLine)
        }
        guard let text = value as? String,
              !text.trimmingCharacters(in: .whitespaces).isEmpty
        else {
            throw PluginManifestError.invalidField(
                field: field, line: lines.line(of: field),
                detail: "it must be a non-empty string")
        }
        guard text.count <= limit else {
            throw PluginManifestError.invalidField(
                field: field, line: lines.line(of: field),
                detail: "it may be at most \(limit) characters")
        }
        return text
    }

    private static func flag(
        _ object: [String: Any], _ field: String, _ lines: Header
    ) throws -> Bool? {
        guard let value = object[field] else { return nil }
        guard let number = value as? NSNumber, isBoolean(number) else {
            throw PluginManifestError.invalidField(
                field: field, line: lines.line(of: field), detail: "it must be true or false")
        }
        return number.boolValue
    }

    /// `JSONSerialization` reads `true` as an `NSNumber`; this is how a boolean
    /// is told apart from the number 1.
    private static func isBoolean(_ number: NSNumber) -> Bool {
        CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    private static func isWholeNumber(_ number: NSNumber) -> Bool {
        !isBoolean(number) && Double(number.intValue) == number.doubleValue
    }
}

/// The formats `ExportInputProducer` can hand a plugin (§9.1). The manifest
/// layer validates the name; the export tier produces the value.
public enum PluginExportInputFormat: String, CaseIterable, Codable, Sendable {
    case url, epub, pdf, docx, markdown, text, html, json, file
}
