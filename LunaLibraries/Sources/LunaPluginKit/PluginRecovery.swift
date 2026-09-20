//
//  PluginRecovery.swift
//  LunaPluginKit
//

import Foundation
import LunaModels

/// A bounded, safe-to-share record of one URL recovery attempt.  The case is
/// deliberately independent of a saved item: a user can diagnose a URL before
/// deciding to save it, while a failed save can reuse the same shape.
public struct PluginRecoveryCase: Codable, Equatable, Sendable {
    public static let currentSchema = 1
    public static let maxAttempts = 128
    public static let maxMatchingPlugins = 64

    public let schema: Int
    public let caseID: UUID
    public let originalURL: String
    public let canonicalURL: String
    public let host: String
    public let source: CaptureSource
    public let appVersion: String
    public let pluginAPIVersion: Int
    public let locale: String
    public let languages: [String]
    public let outcome: String
    public let failureReason: String?
    public let attempts: [PluginRecoveryAttempt]
    public let attemptsDropped: Int
    public let matchingPlugins: [PluginRecoveryPlugin]
    public let matchingPluginsDropped: Int
    public let pageDigest: String?
    public let redactions: [String]
    public let evidenceTruncated: Bool

    public init(
        caseID: UUID = UUID(), originalURL: String, canonicalURL: String? = nil,
        source: CaptureSource = .manual, appVersion: String = "unknown",
        pluginAPIVersion: Int = 1, locale: String = "en", languages: [String] = [],
        outcome: String, failureReason: String? = nil,
        attempts: [PluginRecoveryAttempt] = [], attemptsDropped: Int = 0,
        matchingPlugins: [PluginRecoveryPlugin] = [], matchingPluginsDropped: Int = 0,
        pageDigest: String? = nil, redactions: [String] = [], evidenceTruncated: Bool = false
    ) {
        let original = PluginRecoveryRedactor.redactURLString(originalURL)
        let canonical = PluginRecoveryRedactor.redactURLString(canonicalURL ?? originalURL)
        var summaries = redactions.map { PluginRecoveryRedactor.redactText($0, limit: 128) }
        if original != originalURL || canonical != (canonicalURL ?? originalURL) {
            summaries.append("URL query credentials redacted")
        }
        let sanitizedDigest = pageDigest.map { PluginRecoveryRedactor.redactEvidence($0, limit: 12_000) }
        if let pageDigest, let sanitizedDigest, sanitizedDigest != pageDigest {
            summaries.append("page evidence redacted")
        }
        self.schema = Self.currentSchema
        self.caseID = caseID
        self.originalURL = original
        self.canonicalURL = canonical
        self.host = URL(string: canonical)?.host?.lowercased() ?? ""
        self.source = source
        self.appVersion = PluginRecoveryRedactor.redactText(appVersion, limit: 128)
        self.pluginAPIVersion = pluginAPIVersion
        self.locale = PluginRecoveryRedactor.redactText(locale, limit: 32)
        self.languages = languages.prefix(16).map { PluginRecoveryRedactor.redactText($0, limit: 32) }
        self.outcome = PluginRecoveryRedactor.redactText(outcome, limit: 128)
        self.failureReason = failureReason.map { PluginRecoveryRedactor.redactText($0, limit: 512) }
        self.attempts = Array(attempts.prefix(Self.maxAttempts))
        self.attemptsDropped = max(0, attemptsDropped) + max(0, attempts.count - Self.maxAttempts)
        self.matchingPlugins = Array(matchingPlugins.prefix(Self.maxMatchingPlugins))
        self.matchingPluginsDropped = max(0, matchingPluginsDropped)
            + max(0, matchingPlugins.count - Self.maxMatchingPlugins)
        self.pageDigest = sanitizedDigest
        self.redactions = Array(Set(summaries).sorted().prefix(32))
        self.evidenceTruncated = evidenceTruncated || pageDigest.map { $0.count > 12_000 } ?? false
    }

    /// Stable JSON is useful when a draft validator or a future app version
    /// needs to retain the case outside the saves database.
    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }
}

public struct PluginRecoveryAttempt: Codable, Equatable, Sendable {
    public let phase: String
    public let strategy: String?
    public let result: String
    public let message: String?
    public let elapsedMilliseconds: Int?

    public init(
        phase: String, strategy: String? = nil, result: String,
        message: String? = nil, elapsedMilliseconds: Int? = nil
    ) {
        self.phase = PluginRecoveryRedactor.redactText(phase, limit: 64)
        self.strategy = strategy.map { PluginRecoveryRedactor.redactText($0, limit: 128) }
        self.result = PluginRecoveryRedactor.redactText(result, limit: 64)
        self.message = message.map { PluginRecoveryRedactor.redactEvidence($0, limit: 512) }
        self.elapsedMilliseconds = elapsedMilliseconds.map { max(0, min($0, 3_600_000)) }
    }
}

/// Parses the durable `[timestamp] [category] message` trace without exposing
/// timestamps or raw transport formatting to UI callers. The same parser is
/// used for a failed saved item and for a fresh native probe.
public struct PluginRecoveryTrace: Equatable, Sendable {
    public let attempts: [PluginRecoveryAttempt]
    public let dropped: Int

    public init(attempts: [PluginRecoveryAttempt], dropped: Int = 0) {
        self.attempts = attempts
        self.dropped = max(0, dropped)
    }
}

public enum PluginRecoveryTraceParser {
    public static func parse(_ lines: [String]) -> PluginRecoveryTrace {
        var dropped = 0
        let parsed = lines.compactMap { line -> PluginRecoveryAttempt? in
            if line.hasPrefix("…("), let count = line.split(separator: "(").dropFirst().first,
               let number = count.split(separator: " ").first.flatMap({ Int($0) }) {
                dropped += max(0, number)
                return nil
            }
            guard let open = line.firstIndex(of: "["),
                  let close = line[open...].firstIndex(of: "]"), close > open else { return nil }
            let category = String(line[line.index(after: open)..<close])
            let message = String(line[line.index(after: close)...]).trimmingCharacters(in: .whitespaces)
            let lower = message.lowercased()
            let result = lower.contains("fail") || lower.contains("error") || lower.contains("timeout")
                ? "failed" : (lower.contains("classified") || lower.contains("entered") ? "observed" : "completed")
            return PluginRecoveryAttempt(
                phase: category, strategy: nil, result: result, message: message)
        }
        let attempts = Array(parsed.prefix(PluginRecoveryCase.maxAttempts))
        dropped += max(0, parsed.count - PluginRecoveryCase.maxAttempts)
        return PluginRecoveryTrace(attempts: attempts, dropped: dropped)
    }
}

public struct PluginRecoveryPlugin: Codable, Equatable, Sendable {
    public let id: String
    public let version: String?
    public let status: String
    public let hooks: [String]
    public let outcome: String?

    public init(
        id: String, version: String? = nil, status: String,
        hooks: [String] = [], outcome: String? = nil
    ) {
        self.id = PluginRecoveryRedactor.redactText(id, limit: 128)
        self.version = version.map { PluginRecoveryRedactor.redactText($0, limit: 64) }
        self.status = PluginRecoveryRedactor.redactText(status, limit: 64)
        self.hooks = hooks.prefix(16).map { PluginRecoveryRedactor.redactText($0, limit: 64) }
        self.outcome = outcome.map { PluginRecoveryRedactor.redactText($0, limit: 256) }
    }
}

/// Redaction at the recovery boundary.  Raw support diagnostics remain raw for
/// local debugging; anything copied to an LLM is filtered here.
public enum PluginRecoveryRedactor {
    private static let sensitiveKeys: Set<String> = [
        "token", "access_token", "refresh_token", "id_token", "api_key", "api-key", "apikey",
        "auth", "authorization", "session", "cookie", "password", "passwd", "secret",
        "signature", "sig", "expires", "oauth", "code", "state"
    ]
    private static let sensitiveQueryPattern = try? NSRegularExpression(
        pattern: #"(?i)([?&](?:token|access_token|refresh_token|id_token|api[_-]?key|auth(?:orization)?|session|cookie|password|passwd|secret|signature|sig|x-amz-[^=&#\s]+|expires|oauth|code|state)=)[^&#\s,]+"#)
    private static let sensitiveHeaderPattern = try? NSRegularExpression(
        pattern: #"(?i)(authorization|cookie|set-cookie)\s*:\s*[^,;\n]+"#)

    public static func redactURLString(_ value: String, limit: Int = 2_048) -> String {
        guard let url = URL(string: value), var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return redactText(value, limit: limit) }
        if let queryItems = components.queryItems, let rawQuery = components.percentEncodedQuery {
            // Use decoded queryItems for exact key matching, but splice only
            // sensitive raw pairs. This leaves ordinary `%2F`/`+` routing
            // bytes exactly as received instead of double-encoding them.
            let rawPairs = rawQuery.split(separator: "&", omittingEmptySubsequences: false)
            if rawPairs.count == queryItems.count {
                components.percentEncodedQuery = zip(rawPairs, queryItems).map { rawPair, item in
                    guard isSensitiveQueryName(item.name) else { return String(rawPair) }
                    let name = rawPair.split(separator: "=", maxSplits: 1,
                                             omittingEmptySubsequences: false).first.map(String.init) ?? item.name
                    // `percentEncodedQuery` rejects raw angle brackets. Keep
                    // the replacement visibly redacted after URL decoding
                    // while preserving every untouched pair byte-for-byte.
                    return "\(name)=%3Credacted%3E"
                }.joined(separator: "&")
            } else {
                components.queryItems = queryItems.map { item in
                    isSensitiveQueryName(item.name)
                        ? URLQueryItem(name: item.name, value: "<redacted>")
                        : item
                }
            }
        }
        return redactText(components.string ?? value, limit: limit)
    }

    private static func isSensitiveQueryName(_ name: String) -> Bool {
        let normalized = (name.removingPercentEncoding ?? name).lowercased()
        return sensitiveKeys.contains(normalized)
            || normalized.hasPrefix("x-amz-")
            || normalized.hasSuffix("_token") || normalized.hasSuffix("-token")
            || normalized.hasSuffix("_key") || normalized.hasSuffix("-key")
    }

    public static func redactText(_ value: String, limit: Int) -> String {
        let text = value
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
        let lowerText = text.lowercased()
        if lowerText.contains("--- begin") || lowerText.contains("--- end") {
            return "[prompt boundary marker removed]"
        }
        let scrubbed = text.split(separator: ",", omittingEmptySubsequences: false).map { part in
            let piece = String(part)
            let lower = piece.lowercased()
            if ["authorization:", "cookie:", "set-cookie:"].contains(where: { lower.contains($0) }) {
                let key = piece.split(separator: ":", maxSplits: 1).first.map(String.init) ?? "header"
                return "\(key): <redacted>"
            }
            return piece
        }.joined(separator: ",")
        return String(redactHeaderSecrets(redactQuerySecrets(scrubbed)).prefix(max(0, limit)))
    }

    public static func redactEvidence(_ value: String, limit: Int) -> String {
        let lines = value.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            redactText(String(line), limit: 1_000)
        }
        return String(lines.joined(separator: "\n").prefix(max(0, limit)))
    }

    private static func redactQuerySecrets(_ value: String) -> String {
        guard let sensitiveQueryPattern else { return value }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return sensitiveQueryPattern.stringByReplacingMatches(
            in: value, options: [], range: range, withTemplate: "$1<redacted>")
    }

    private static func redactHeaderSecrets(_ value: String) -> String {
        guard let sensitiveHeaderPattern else { return value }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return sensitiveHeaderPattern.stringByReplacingMatches(
            in: value, options: [], range: range, withTemplate: "$1: <redacted>")
    }
}

/// The machine-readable result a draft validator feeds into the correction
/// prompt.  Validation itself lives in the UI/runtime work package.
public struct PluginValidationReport: Codable, Equatable, Sendable {
    public static let maxMessages = 64
    public let passed: Bool
    public let errors: [String]
    public let warnings: [String]
    public let errorsDropped: Int
    public let warningsDropped: Int
    public let attempts: [PluginRecoveryAttempt]
    public let attemptsDropped: Int
    public let modelKind: String?
    /// The hooks the draft actually registered, as the load step saw them. The
    /// review screen shows these beside the manifest's required hooks, which is
    /// the only way to tell a declared hook from a present one.
    public let registeredHooks: [PluginHook]

    public init(
        passed: Bool, errors: [String] = [], warnings: [String] = [],
        errorsDropped: Int = 0, warningsDropped: Int = 0,
        attempts: [PluginRecoveryAttempt] = [], attemptsDropped: Int = 0,
        modelKind: String? = nil, registeredHooks: [PluginHook] = []
    ) {
        self.passed = passed
        self.errors = errors.prefix(Self.maxMessages).map {
            PluginRecoveryRedactor.redactEvidence($0, limit: 1_000)
        }
        self.warnings = warnings.prefix(Self.maxMessages).map {
            PluginRecoveryRedactor.redactEvidence($0, limit: 1_000)
        }
        self.errorsDropped = max(0, errorsDropped) + max(0, errors.count - Self.maxMessages)
        self.warningsDropped = max(0, warningsDropped) + max(0, warnings.count - Self.maxMessages)
        self.attempts = Array(attempts.prefix(PluginRecoveryCase.maxAttempts))
        self.attemptsDropped = max(0, attemptsDropped)
            + max(0, attempts.count - PluginRecoveryCase.maxAttempts)
        self.modelKind = modelKind
        self.registeredHooks = registeredHooks
    }
}
