//
//  LunaRecoveryFile.swift
//  LunaModels
//

import Foundation

/// A replayable way to reach the page, written beside the content so Luna can
/// learn a host rule instead of only adopting one answer
/// (`claudedocs/luna-file.md`).
///
/// The recipe is a REQUEST, not a result: whoever applies it validates the URL
/// against its own rules and runs the script in its own sandbox.
public struct LunaRecoveryRecipe: Equatable, Sendable {
    /// What the replay reads.
    public enum Returns: String, Equatable, Sendable, CaseIterable {
        case html, json, mediaURL
    }

    /// The only request headers a recipe may set. Everything else is dropped
    /// rather than refused: a model that adds `cookie` should lose the header,
    /// not the whole recovery.
    public static let allowedHeaderNames: Set<String> = [
        "user-agent", "referer", "accept-language",
    ]

    /// The longest page script a recipe may carry.
    public static let maxJavaScriptBytes = 8 * 1024

    public let url: URL
    /// Lower-cased names, filtered to `allowedHeaderNames`.
    public let headers: [String: String]
    /// Runs in an off-screen web view and must return a string.
    public let javascript: String?
    public let returns: Returns

    public init(
        url: URL, headers: [String: String] = [:], javascript: String? = nil,
        returns: Returns = .html
    ) {
        self.url = url
        self.headers = headers
        self.javascript = javascript
        self.returns = returns
    }
}

/// A `luna-recovery` Luna file: the page it recovers, the content Luna adopts,
/// and an optional recipe to replay first.
public struct LunaRecoveryFile: Equatable, Sendable {
    /// The format version this parser reads.
    public static let supportedAPIVersion = 1
    public static let noteMaxLength = 300

    /// The page the user saved.
    public let url: URL
    public let kind: PluginModelKind
    /// Free text for diagnostics. Shown nowhere.
    public let note: String?
    public let content: PluginModel
    public let recipe: LunaRecoveryRecipe?

    public init(
        url: URL, kind: PluginModelKind, note: String? = nil,
        content: PluginModel, recipe: LunaRecoveryRecipe? = nil
    ) {
        self.url = url
        self.kind = kind
        self.note = note
        self.content = content
        self.recipe = recipe
    }

    /// Reads a parsed `luna-recovery` header plus the body below it.
    public static func parse(_ header: LunaFileHeader) -> Result<LunaRecoveryFile, LunaFileError> {
        guard header.marker == .recovery else { return .failure(.noHeader) }
        let object: [String: Any]
        switch header.jsonObject() {
        case .success(let value): object = value
        case .failure(let error): return .failure(error)
        }

        guard let api = object["api"] as? Int else {
            return .failure(.missingField(field: "api", line: header.line(of: "api")))
        }
        guard api == supportedAPIVersion else {
            return .failure(.unsupportedAPIVersion(declared: api, supported: supportedAPIVersion))
        }
        guard let rawURL = object["url"] as? String else {
            return .failure(.missingField(field: "url", line: header.line(of: "url")))
        }
        guard let url = URL(string: rawURL), let scheme = url.scheme?.lowercased(),
              PluginModelCaps.allowedURLSchemes.contains(scheme), url.host != nil
        else {
            return .failure(.invalidField(
                field: "url", line: header.line(of: "url"),
                detail: "expected an absolute http or https address"))
        }
        guard let rawKind = object["kind"] as? String else {
            return .failure(.missingField(field: "kind", line: header.line(of: "kind")))
        }
        guard let kind = PluginModelKind(rawValue: rawKind) else {
            return .failure(.invalidField(
                field: "kind", line: header.line(of: "kind"),
                detail: "expected article, media or product"))
        }
        var note = object["note"] as? String
        if let text = note, text.count > noteMaxLength {
            return .failure(.invalidField(
                field: "note", line: header.line(of: "note"),
                detail: "at most \(noteMaxLength) characters"))
        }
        if note?.isEmpty == true { note = nil }

        let body: Body
        do {
            body = try JSONDecoder().decode(Body.self, from: Data(header.body.utf8))
        } catch let error as LunaFileError {
            return .failure(error.atLine(header.bodyStartLine))
        } catch let error as PluginModelValidationError {
            return .failure(.bodyNotJSON(detail: String(describing: error)))
        } catch {
            return .failure(.bodyNotJSON(detail: error.localizedDescription))
        }
        guard body.content.kind == kind else {
            return .failure(.kindMismatch(header: kind, content: body.content.kind))
        }
        return .success(LunaRecoveryFile(
            url: url, kind: kind, note: note, content: body.content, recipe: body.recipe))
    }

    /// The object below the header's `*/`.
    private struct Body: Decodable {
        let content: PluginModel
        let recipe: LunaRecoveryRecipe?

        private enum CodingKeys: String, CodingKey { case content, recipe }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            guard container.contains(.content) else {
                throw LunaFileError.missingField(field: "content", line: 0)
            }
            content = try container.decode(PluginModel.self, forKey: .content)
            recipe = try container.decodeIfPresent(LunaRecoveryRecipe.self, forKey: .recipe)
        }
    }
}

extension LunaRecoveryRecipe: Decodable {
    private enum CodingKeys: String, CodingKey { case url, headers, javascript, returns }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let raw = try container.decodeIfPresent(String.self, forKey: .url) else {
            throw LunaFileError.missingField(field: "recipe.url", line: 0)
        }
        guard let url = URL(string: raw), let scheme = url.scheme?.lowercased(),
              PluginModelCaps.allowedURLSchemes.contains(scheme), url.host != nil
        else {
            throw LunaFileError.invalidField(
                field: "recipe.url", line: 0,
                detail: "expected an absolute http or https address")
        }
        self.url = url

        let declared = try container.decodeIfPresent([String: String].self, forKey: .headers) ?? [:]
        var kept: [String: String] = [:]
        for (name, value) in declared {
            let lowered = name.lowercased()
            guard LunaRecoveryRecipe.allowedHeaderNames.contains(lowered) else { continue }
            guard value.count <= PluginModelCaps.headerValue else {
                throw LunaFileError.invalidField(
                    field: "recipe.headers.\(lowered)", line: 0,
                    detail: "at most \(PluginModelCaps.headerValue) characters")
            }
            kept[lowered] = value
        }
        headers = kept

        if let script = try container.decodeIfPresent(String.self, forKey: .javascript) {
            guard script.utf8.count <= LunaRecoveryRecipe.maxJavaScriptBytes else {
                throw LunaFileError.invalidField(
                    field: "recipe.javascript", line: 0,
                    detail: "at most \(LunaRecoveryRecipe.maxJavaScriptBytes) bytes")
            }
            javascript = script.isEmpty ? nil : script
        } else {
            javascript = nil
        }

        if let raw = try container.decodeIfPresent(String.self, forKey: .returns) {
            guard let value = Returns(rawValue: raw) else {
                throw LunaFileError.invalidField(
                    field: "recipe.returns", line: 0,
                    detail: "expected html, json or mediaURL")
            }
            returns = value
        } else {
            returns = .html
        }
    }
}
