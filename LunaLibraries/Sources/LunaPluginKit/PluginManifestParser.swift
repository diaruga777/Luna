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
    public static let idCharacters = Set("abcdefghijklmnopqrstuvwxyz0123456789.-")

    /// The largest plugin file the parser accepts — the cap every Luna file
    /// shares (`LunaFileLimits`).
    public static let maxSourceKB = LunaFileLimits.maxSourceKB

    public static let idMaxLength = 100
    public static let nameMaxLength = 40
    public static let descriptionMaxLength = 200
    public static let versionMaxLength = 32

    // MARK: - Entry point

    /// Parses the leading `/* luna-plugin … */` header of a plugin file.
    ///
    /// `languages` resolves every localized copy field (§2.2) to the `String`
    /// the rest of the platform reads — the preferred list a user's device
    /// reports, most-preferred first. Resolution happens HERE, once, so a
    /// `PluginManifest` never carries a table past this call.
    public static func parse(
        source: String, languages: [String] = Locale.preferredLanguages
    ) -> Result<PluginManifest, PluginManifestError> {
        guard source.utf8.count <= maxSourceKB * 1024 else {
            return .failure(.sourceTooLarge(limitKB: maxSourceKB))
        }
        let header: Header
        switch extractHeader(from: source) {
        case .success(let extracted): header = extracted
        case .failure(let error): return .failure(error)
        }
        let object: [String: Any]
        switch header.jsonObject() {
        case .success(let dictionary): object = dictionary
        case .failure(let error): return .failure(pluginError(error))
        }
        do {
            return .success(try manifest(from: object, lines: header, languages: languages))
        } catch let error as PluginManifestError {
            return .failure(error)
        } catch {
            return .failure(.headerNotJSON(
                line: header.jsonStartLine, detail: error.localizedDescription))
        }
    }

    // MARK: - The header comment

    /// The plugin file's header. `LunaFileHeader` reads the shape every Luna
    /// file shares; this names the one marker a plugin may carry and speaks
    /// `PluginManifestError` so an author reads one vocabulary.
    typealias Header = LunaFileHeader

    static func extractHeader(from source: String) -> Result<Header, PluginManifestError> {
        switch LunaFileHeader.parse(source) {
        case .success(let header):
            // A `luna-recovery` file is a Luna file, but it is not a plugin.
            guard header.marker == .plugin else { return .failure(.noHeader) }
            return .success(header)
        case .failure(let error):
            return .failure(pluginError(error))
        }
    }

    /// The plugin vocabulary for a shared-parser failure.
    private static func pluginError(_ error: LunaFileError) -> PluginManifestError {
        switch error {
        case .headerNotJSON(let line, let detail):
            return .headerNotJSON(line: line, detail: detail)
        case .fileTooLarge(let limitKB):
            return .sourceTooLarge(limitKB: limitKB)
        default:
            return .noHeader
        }
    }

    // MARK: - Fields

    private static func manifest(
        from object: [String: Any], lines: Header, languages: [String]
    ) throws -> PluginManifest {
        let api = try apiVersion(object, lines)
        let id = try pluginID(object, lines)
        let name = try localizedBoundedString(
            object, "name", limit: nameMaxLength, lines: lines, required: true,
            languages: languages)!
        let version = try self.version(object, lines)
        let description = try localizedBoundedString(
            object, "description", limit: descriptionMaxLength, lines: lines, required: false,
            languages: languages)
        let produces = try self.produces(object, lines)
        let match = try self.match(object, lines, isIngest: !produces.isEmpty)
        let priority = try self.priority(object, lines)
        let capabilities = try self.capabilities(object, lines)
        let export = try self.export(object, lines, languages: languages)
        let settings = try self.settings(object, lines, languages: languages)
        // `export.requiresSettings` must name a settings key this same
        // manifest declares (R1#21) — checked here, after both are parsed,
        // rather than inside `export(...)`, so it needs no settings knowledge
        // of its own.
        if let export {
            let declaredKeys = Set(settings.map(\.key))
            for key in export.requiresSettings where !declaredKeys.contains(key) {
                throw PluginManifestError.invalidField(
                    field: "export.requiresSettings", line: lines.line(of: "requiresSettings"),
                    detail: "\"\(key)\" is not a key any \"settings\" entry declares")
            }
        }
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
        let text = try boundedString(
            object, "version", limit: versionMaxLength, lines: lines, required: true)!
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
                // A "*" may lead a pattern as "*." and nowhere else — anything
                // wider (a bare "*", "a.*.com", "*.*.com") parses but never
                // matches a real host (`PluginSummary.matches`), so it is
                // refused here rather than silently never firing.
                let isLeadingWildcard = lowered.hasPrefix("*.") && !lowered.dropFirst(2).contains("*")
                guard !lowered.contains("*") || isLeadingWildcard else {
                    throw PluginManifestError.invalidField(
                        field: "match.hosts", line: lines.line(of: "hosts"),
                        detail: "\"\(host)\" is not a host pattern — a \"*\" may only lead "
                            + "it as \"*.\"; use \"any\": true to match every host")
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
        _ object: [String: Any], _ lines: Header, languages: [String]
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
              let format = PluginExportInputFormat(rawValue: input)
        else {
            throw PluginManifestError.invalidField(
                field: "export.input", line: lines.line(of: "input"),
                detail: "it must be one of "
                    + PluginExportInputFormat.allCases.map(\.rawValue).joined(separator: ", "))
        }
        let unsupported = PluginExportInputAvailability.unsupportedKinds(in: kinds, format: format)
        guard unsupported.isEmpty else {
            throw PluginManifestError.invalidField(
                field: "export.input", line: lines.line(of: "input"),
                detail: "Luna cannot build \"\(input)\" for a "
                    + unsupported.map(\.rawValue).joined(separator: " or ")
                    + " save — that kind takes "
                    + PluginExportInputAvailability.formats(for: unsupported[0])
                        .map(\.rawValue).sorted().joined(separator: ", "))
        }
        guard let rawTitle = export["title"] else {
            throw PluginManifestError.invalidField(
                field: "export.title", line: lines.line(of: "title"),
                detail: "it must be a share-row label of at most 40 characters")
        }
        let title = try localizedField(
            rawTitle, field: "export.title", lines: lines, limit: 40, nonEmpty: true,
            languages: languages)
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
        let dequeueOnRead = (export["dequeueOnRead"] as? NSNumber).map(\.boolValue) ?? false
        return PluginExportSummary(
            kinds: kinds, input: input, epubProfile: epubProfile, epubImages: epubImages,
            title: title, symbol: export["symbol"] as? String, isDestination: destination,
            requiresSettings: requires, dequeueOnRead: dequeueOnRead)
    }

    private static func settings(
        _ object: [String: Any], _ lines: Header, languages: [String]
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
                  key.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") })
            else {
                throw PluginManifestError.invalidField(
                    field: "settings.key", line: lines.line(of: "key"),
                    detail: "a key uses ASCII letters, digits and '_' only")
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
            guard let rawLabel = entry["label"] else {
                throw PluginManifestError.invalidField(
                    field: "settings.label", line: lines.line(of: "label"),
                    detail: "every field needs a label")
            }
            let label = try localizedField(
                rawLabel, field: "settings.label", lines: lines, limit: nil, nonEmpty: true,
                languages: languages)
            let help = try entry["help"].map {
                try localizedField(
                    $0, field: "settings.help", lines: lines, limit: nil, nonEmpty: false,
                    languages: languages)
            }
            let placeholder = try entry["placeholder"].map {
                try localizedField(
                    $0, field: "settings.placeholder", lines: lines, limit: nil, nonEmpty: false,
                    languages: languages)
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
                          let rawOptionLabel = option["label"]
                    else {
                        throw PluginManifestError.invalidField(
                            field: "settings.options", line: lines.line(of: "options"),
                            detail: "every option needs an \"id\" and a \"label\"")
                    }
                    let optionLabel = try localizedField(
                        rawOptionLabel, field: "settings.options", lines: lines, limit: nil,
                        nonEmpty: true, languages: languages)
                    options.append(PluginSettingOption(id: id, label: optionLabel))
                }
            }
            var defaultJSON: String?
            if let value = entry["default"] {
                guard let data = try? JSONSerialization.data(
                    withJSONObject: value, options: [.fragmentsAllowed])
                else {
                    throw PluginManifestError.invalidField(
                        field: "settings.default", line: lines.line(of: "default"),
                        detail: "it must be a JSON value Luna can encode")
                }
                defaultJSON = String(decoding: data, as: UTF8.self)
            }
            fields.append(PluginSettingField(
                key: key, type: type, label: label, help: help,
                placeholder: placeholder, options: options,
                defaultJSON: defaultJSON,
                isRequired: try flag(entry, "settings.required", lines, key: "required") ?? false,
                isSecret: try flag(entry, "settings.secret", lines, key: "secret") ?? false))
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

    /// Reads a boolean field, rejecting anything an `NSNumber` cast would
    /// otherwise let through unchecked — `1`, `"true"`, and so on (R1#18).
    /// `key` is the object's own key when it differs from `field`, the name
    /// the error names (a nested field like `"settings.required"` is looked
    /// up as `"required"` but reported by its dotted, human path).
    private static func flag(
        _ object: [String: Any], _ field: String, _ lines: Header, key: String? = nil
    ) throws -> Bool? {
        let lookupKey = key ?? field
        guard let value = object[lookupKey] else { return nil }
        guard let number = value as? NSNumber, isBoolean(number) else {
            throw PluginManifestError.invalidField(
                field: field, line: lines.line(of: lookupKey), detail: "it must be true or false")
        }
        return number.boolValue
    }

    /// Reads a user-visible field that may be a plain string or a localized
    /// table (§2.2): `{ "<language tag>": "<text>" }`, which must include
    /// `"en"`. Resolves at parse time against `languages`, so every caller
    /// keeps reading a plain `String`. `limit` is `nil` for a field with no
    /// length cap; `nonEmpty` rejects a blank variant.
    private static func localizedField(
        _ value: Any, field: String, lines: Header, limit: Int?, nonEmpty: Bool,
        languages: [String]
    ) throws -> String {
        let table: [String: String]
        if let text = value as? String {
            table = ["en": text]
        } else if let raw = value as? [String: Any] {
            var built: [String: String] = [:]
            for (tag, entry) in raw {
                guard let text = entry as? String else {
                    throw PluginManifestError.invalidField(
                        field: field, line: lines.line(of: field),
                        detail: "every value in a localized table must be a string")
                }
                built[tag] = text
            }
            table = built
        } else {
            throw PluginManifestError.invalidField(
                field: field, line: lines.line(of: field),
                detail: "it must be a string or a { \"<language tag>\": \"…\" } table")
        }
        guard table["en"] != nil else {
            throw PluginManifestError.invalidField(
                field: field, line: lines.line(of: field),
                detail: "a localized table must include \"en\"")
        }
        for text in table.values {
            if nonEmpty {
                guard !text.trimmingCharacters(in: .whitespaces).isEmpty else {
                    throw PluginManifestError.invalidField(
                        field: field, line: lines.line(of: field),
                        detail: "it must be a non-empty string")
                }
            }
            if let limit {
                guard text.count <= limit else {
                    throw PluginManifestError.invalidField(
                        field: field, line: lines.line(of: field),
                        detail: "it may be at most \(limit) characters")
                }
            }
        }
        return PluginLocalizedText.resolve(table, preferring: languages)
    }

    /// `localizedField`, plus the missing-vs-required check `boundedString`
    /// does for a plain string.
    private static func localizedBoundedString(
        _ object: [String: Any], _ field: String, limit: Int, lines: Header, required: Bool,
        languages: [String]
    ) throws -> String? {
        guard let value = object[field] else {
            guard required else { return nil }
            throw PluginManifestError.missingField(field: field, line: lines.jsonStartLine)
        }
        return try localizedField(
            value, field: field, lines: lines, limit: limit, nonEmpty: true, languages: languages)
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
