//
//  RescueRuleStore.swift
//  LunaURLRescue
//

import Foundation
import LunaModels
import LunaAppConfig
import LunaURLClassification

/// A learned per-host rescue rule: a directive shape that WORKED for a host, so
/// the next failure for that host can be replayed deterministically before
/// spending an LLM call. Only URL diffs that generalize are stored.
public struct RescueLearnedRule: Codable, Equatable {
    /// How to derive the rescue URL from a future failing URL on this host. Only
    /// shapes obtainable by diffing the original vs the applied URL.
    public enum URLRewrite: Codable, Equatable {
        case none                    // JS-only rule; keep the original URL
        case hostReplace(String)     // swap the host, keep path/query
        case pathSuffix(String)      // append to the path
        case queryAppend(String)     // append a query item ("key=value")
    }

    public let host: String          // HostMatching.normalizedHost
    public let hint: String          // RescueHint.rawValue, or "auto"
    public let rewrite: URLRewrite
    public let userAgentToken: String?
    public let refererString: String?
    public let acceptLanguage: String?
    public let xForwardedFor: String?
    public let javascript: String?
    public let scriptResultKind: String?
    public let createdAt: Date
    public var lastSuccessAt: Date
    public var successCount: Int
    public var consecutiveFailures: Int

    public static let schemaVersion = 1

    public init(
        host: String, hint: String, rewrite: URLRewrite,
        userAgentToken: String? = nil, refererString: String? = nil,
        acceptLanguage: String? = nil, xForwardedFor: String? = nil,
        javascript: String? = nil, scriptResultKind: String? = nil,
        createdAt: Date, lastSuccessAt: Date, successCount: Int = 1, consecutiveFailures: Int = 0
    ) {
        self.host = host
        self.hint = hint
        self.rewrite = rewrite
        self.userAgentToken = userAgentToken
        self.refererString = refererString
        self.acceptLanguage = acceptLanguage
        self.xForwardedFor = xForwardedFor
        self.javascript = javascript
        self.scriptResultKind = scriptResultKind
        self.createdAt = createdAt
        self.lastSuccessAt = lastSuccessAt
        self.successCount = successCount
        self.consecutiveFailures = consecutiveFailures
    }
}

public protocol RescueRuleStoring: AnyObject {
    var isEnabled: Bool { get set }
    func rule(forHost host: String, hint: RescueHint?) -> RescueLearnedRule?
    func recordSuccess(_ rule: RescueLearnedRule)
    func recordFailure(forHost host: String, hint: RescueHint?)
    func store(_ rule: RescueLearnedRule)
}

/// An in-memory store — the test double, and the base logic the file store wraps.
public final class InMemoryRescueRuleStore: RescueRuleStoring {
    private let lock = NSLock()
    private var rules: [String: RescueLearnedRule] = [:]   // key = host|hint
    private let now: () -> Date
    public var isEnabled: Bool

    public init(isEnabled: Bool = true, now: @escaping () -> Date = Date.init) {
        self.isEnabled = isEnabled
        self.now = now
    }

    public static func key(host: String, hint: String) -> String { "\(host)|\(hint)" }

    public func rule(forHost host: String, hint: RescueHint?) -> RescueLearnedRule? {
        lock.lock(); defer { lock.unlock() }
        let key = Self.key(host: HostMatching.normalizedHost(host), hint: hint?.rawValue ?? "auto")
        guard let rule = rules[key] else { return nil }
        if now().timeIntervalSince(rule.lastSuccessAt) > RescueRuleStore.expiry {
            rules[key] = nil
            return nil
        }
        return rule
    }

    public func recordSuccess(_ rule: RescueLearnedRule) {
        lock.lock(); defer { lock.unlock() }
        var updated = rule
        updated.lastSuccessAt = now()
        updated.successCount += 1
        updated.consecutiveFailures = 0
        rules[Self.key(host: rule.host, hint: rule.hint)] = updated
    }

    public func recordFailure(forHost host: String, hint: RescueHint?) {
        lock.lock(); defer { lock.unlock() }
        let key = Self.key(host: HostMatching.normalizedHost(host), hint: hint?.rawValue ?? "auto")
        guard var rule = rules[key] else { return }
        rule.consecutiveFailures += 1
        if rule.consecutiveFailures >= RescueRuleStore.maxConsecutiveFailures {
            rules[key] = nil
        } else {
            rules[key] = rule
        }
    }

    public func store(_ rule: RescueLearnedRule) {
        lock.lock(); defer { lock.unlock() }
        rules[Self.key(host: rule.host, hint: rule.hint)] = rule
        evictIfNeededLocked()
    }

    func snapshot() -> [RescueLearnedRule] {
        lock.lock(); defer { lock.unlock() }
        return Array(rules.values)
    }

    func load(_ loaded: [RescueLearnedRule]) {
        lock.lock(); defer { lock.unlock() }
        for rule in loaded where now().timeIntervalSince(rule.lastSuccessAt) <= RescueRuleStore.expiry {
            rules[Self.key(host: rule.host, hint: rule.hint)] = rule
        }
    }

    private func evictIfNeededLocked() {
        guard rules.count > RescueRuleStore.maxEntries else { return }
        // LRU by lastSuccessAt.
        let sorted = rules.sorted { $0.value.lastSuccessAt < $1.value.lastSuccessAt }
        for (key, _) in sorted.prefix(rules.count - RescueRuleStore.maxEntries) {
            rules[key] = nil
        }
    }
}

/// The App-Group-backed store. Persists `url-rescue-rules.json` next to the
/// saves list. Main app is the only writer (this module never links into
/// extensions), so a simple lock + atomic write suffices.
public final class RescueRuleStore: RescueRuleStoring {
    public static let shared = RescueRuleStore()

    public static let expiry: TimeInterval = 30 * 24 * 60 * 60
    public static let maxConsecutiveFailures = 3
    public static let maxEntries = 200
    static let killSwitchKey = "urlRescue.rulesEnabled"

    private let memory: InMemoryRescueRuleStore
    private let fileURL: URL?
    private let defaults: UserDefaults
    private let ioLock = NSLock()

    public init(containerURL: URL? = nil, now: @escaping () -> Date = Date.init) {
        self.memory = InMemoryRescueRuleStore(now: now)
        self.defaults = UserDefaults(suiteName: AppConfig.appGroupID) ?? .standard
        let base = containerURL ?? AppConfig.sharedContainerURL()
        self.fileURL = base?.appendingPathComponent("url-rescue-rules.json")
        loadFromDisk()
    }

    public var isEnabled: Bool {
        get { (defaults.object(forKey: Self.killSwitchKey) as? Bool) ?? true }
        set { defaults.set(newValue, forKey: Self.killSwitchKey) }
    }

    public func rule(forHost host: String, hint: RescueHint?) -> RescueLearnedRule? {
        guard isEnabled else { return nil }
        return memory.rule(forHost: host, hint: hint)
    }

    public func recordSuccess(_ rule: RescueLearnedRule) {
        memory.recordSuccess(rule)
        persist()
    }

    public func recordFailure(forHost host: String, hint: RescueHint?) {
        memory.recordFailure(forHost: host, hint: hint)
        persist()
    }

    public func store(_ rule: RescueLearnedRule) {
        memory.store(rule)
        persist()
    }

    // MARK: - Disk

    private struct Envelope: Codable {
        var schemaVersion: Int
        var rules: [RescueLearnedRule]
    }

    private func loadFromDisk() {
        guard let fileURL else { return }
        ioLock.lock(); defer { ioLock.unlock() }
        guard let data = try? Data(contentsOf: fileURL),
              let envelope = try? JSONDecoder.rescue.decode(Envelope.self, from: data),
              envelope.schemaVersion == RescueLearnedRule.schemaVersion else { return }
        memory.load(envelope.rules)
    }

    private func persist() {
        guard let fileURL else { return }
        let envelope = Envelope(schemaVersion: RescueLearnedRule.schemaVersion, rules: memory.snapshot())
        ioLock.lock(); defer { ioLock.unlock() }
        guard let data = try? JSONEncoder.rescue.encode(envelope) else { return }
        try? data.write(to: fileURL, options: .atomic)
        var url = fileURL
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }
}

extension JSONEncoder {
    static var rescue: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}
extension JSONDecoder {
    static var rescue: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
