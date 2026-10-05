//
//  PluginHookPayloads.swift
//  LunaPluginIngest
//
//  The wire shapes of the two ingest hooks. The TypeScript in
//  claudedocs/plans/plugin-platform.md §4 is the contract; these are its Swift
//  half. The runtime encodes an `Encodable` argument to JSON and decodes the
//  settled value, so nothing here touches JavaScriptCore.
//

import Foundation
import LunaModels
import LunaPluginKit

/// The page a caller already has, handed to both hooks so a plugin does not
/// refetch what Safari or the share sheet already read.
public struct PluginPageSnapshot: Encodable, Sendable {
    public static let maxHTMLCharacters = 200_000
    public let url: String
    public let html: String?
    public let title: String?
    /// "safari" | "fetch" | "browser".
    public let source: String
    public let truncated: Bool

    public init(
        url: String, html: String?, title: String? = nil, source: String,
        truncated: Bool = false
    ) {
        self.url = url
        self.html = html.map { String($0.prefix(Self.maxHTMLCharacters)) }
        self.title = title
        self.source = source
        self.truncated = truncated || (html?.count ?? 0) > Self.maxHTMLCharacters
    }
}

public struct PluginClassifyInput: Encodable, Sendable {
    public let url: String
    public let page: PluginPageSnapshot?
    public let context: String
    /// `IngestIntent.rawValue`. Absent from the JSON for an ordinary save, so a
    /// plugin written before intents existed sees the input it always saw.
    public let intent: String?

    public init(
        url: String, page: PluginPageSnapshot?, context: PluginProcessKind,
        intent: String? = nil
    ) {
        self.url = url
        self.page = page
        self.context = context.rawValue
        self.intent = intent
    }
}

/// What a plugin's `classify` returned. `false` declines; an object claims.
public enum PluginClassifyVerdict: Decodable, Equatable, Sendable {
    case declined
    case claimed(kind: PluginModelKind, itemID: String?, confidence: Double?)

    private enum CodingKeys: String, CodingKey {
        case kind, confidence
        case itemID = "itemId"
    }

    public init(from decoder: Decoder) throws {
        // `false` and `null` both decline. A plugin that returns nothing at all
        // has not claimed the URL either.
        if let single = try? decoder.singleValueContainer() {
            if single.decodeNil() { self = .declined; return }
            if let flag = try? single.decode(Bool.self) {
                guard !flag else {
                    // `true` is not a claim — the contract is `false` or an
                    // object naming the kind — so the runtime reports it as a
                    // malformed result rather than guessing a kind.
                    throw PluginModelValidationError.missingField("classify.kind")
                }
                self = .declined
                return
            }
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let raw = try c.decodeIfPresent(String.self, forKey: .kind),
              let kind = PluginModelKind(rawValue: raw)
        else {
            throw PluginModelValidationError.missingField("classify.kind")
        }
        self = .claimed(
            kind: kind,
            itemID: try c.decodeIfPresent(String.self, forKey: .itemID),
            confidence: try c.decodeIfPresent(Double.self, forKey: .confidence))
    }
}

/// Why the core is calling `ingest`. It travels to the plugin verbatim.
public enum PluginIngestReason: String, Encodable, Sendable {
    case save, resume, refresh, reresolve, rescue, compare
}

public struct PluginIngestClaim: Encodable, Sendable {
    public let kind: String
    public let itemID: String?

    private enum CodingKeys: String, CodingKey {
        case kind
        case itemID = "itemId"
    }

    public init(kind: PluginModelKind, itemID: String?) {
        self.kind = kind.rawValue
        self.itemID = itemID
    }
}

public struct PluginIngestHookInput: Encodable, Sendable {
    public let url: String
    public let claim: PluginIngestClaim
    public let page: PluginPageSnapshot?
    public let reason: String
    public let context: String
    public let saveID: String?
    /// `IngestIntent.rawValue`, absent for an ordinary save.
    public let intent: String?

    private enum CodingKeys: String, CodingKey {
        case url, claim, page, reason, context, intent
        case saveID = "saveId"
    }

    public init(
        url: String, claim: PluginIngestClaim, page: PluginPageSnapshot?,
        reason: PluginIngestReason, context: PluginProcessKind, saveID: String? = nil,
        intent: String? = nil
    ) {
        self.url = url
        self.claim = claim
        self.page = page
        self.reason = reason.rawValue
        self.context = context.rawValue
        self.saveID = saveID
        self.intent = intent
    }
}

/// What a plugin's `ingest` returned. `null` is a decline read AFTER the page,
/// so the walk continues with the next plugin rather than failing the save.
///
/// `Optional` at a decoder's top level is not dependable across encoders, so the
/// walk decodes this instead of `PluginModel?`.
public enum PluginIngestAnswer: Decodable {
    case declined
    case model(PluginModel)
    case rewrite(URL)

    private enum CodingKeys: String, CodingKey { case rewriteURL }

    public init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(), single.decodeNil() {
            self = .declined
            return
        }
        if let container = try? decoder.container(keyedBy: CodingKeys.self),
           let raw = try container.decodeIfPresent(String.self, forKey: .rewriteURL),
           let url = URL(string: raw), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
           !(url.host ?? "").isEmpty {
            self = .rewrite(url)
            return
        }
        self = .model(try PluginModel(from: decoder))
    }
}
