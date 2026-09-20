//
//  PluginRecoveryHandoffStore.swift
//  LunaPluginKit
//

import Foundation
import LunaAppConfig

/// A single Safari plugin-recovery case waiting for the central Luna app.
///
/// Safari and the containing app are separate processes. Keeping the complete
/// case (rather than putting evidence in a URL query) also means a deep link
/// stays short and a failed app launch does not lose the handoff. The payload
/// is deliberately bounded before it reaches UserDefaults: it is untrusted
/// page/plugin text and may be written by an extension while the app is cold.
public struct PluginRecoveryHandoff: Codable, Equatable, Sendable {
    public let recoveryCase: PluginRecoveryCase
    /// Private local test target. It is never serialized into the prompt or
    /// placed in the deep link, so redacted query credentials stay private.
    public let validationURL: String
    public let recordedAt: Date

    public init(recoveryCase: PluginRecoveryCase, validationURL: URL, recordedAt: Date) {
        self.recoveryCase = recoveryCase
        self.validationURL = validationURL.absoluteString
        self.recordedAt = recordedAt
    }
}

public final class PluginRecoveryHandoffStore: @unchecked Sendable {
    public static let shared = PluginRecoveryHandoffStore()

    public static let key = "lunaPluginRecoveryHandoff"
    /// A recovery prompt is capped at 28,000 characters. Leave room for JSON
    /// keys and escaping while keeping the durable App-Group value modest.
    public static let maxStoredBytes = 96 * 1024
    public static let lifetime: TimeInterval = 60 * 60

    private let defaults: UserDefaults?
    private let lock = NSLock()

    /// `defaults` is injectable so unit tests never touch the real App Group.
    public init(defaults: UserDefaults? = UserDefaults(suiteName: AppConfig.appGroupID)) {
        self.defaults = defaults
    }

    /// Persists one case and returns false when its encoded representation is
    /// unexpectedly over the hard bound. Never stores a partial JSON document.
    @discardableResult
    public func record(
        _ recoveryCase: PluginRecoveryCase, validationURL: URL, at date: Date = Date()
    ) -> Bool {
        let handoff = PluginRecoveryHandoff(
            recoveryCase: recoveryCase, validationURL: validationURL, recordedAt: date)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(handoff), data.count <= Self.maxStoredBytes else {
            return false
        }
        lock.lock()
        defaults?.set(data, forKey: Self.key)
        lock.unlock()
        return defaults != nil
    }

    /// Reads without consuming. Expired handoffs are discarded so an old page
    /// can never become the subject of a later plugin request.
    public func peek(now: Date = Date()) -> PluginRecoveryHandoff? {
        lock.lock()
        defer { lock.unlock() }
        return readLocked(now: now)
    }

    /// Consumes the pending case exactly once.
    public func take(caseID: UUID, now: Date = Date()) -> PluginRecoveryHandoff? {
        lock.lock()
        defer { lock.unlock() }
        guard let value = readLocked(now: now),
              value.recoveryCase.caseID == caseID else { return nil }
        defaults?.removeObject(forKey: Self.key)
        return value
    }

    /// Caller holds `lock`. Corrupt/expired data is removed here rather than
    /// being reconsidered on every launch.
    private func readLocked(now: Date) -> PluginRecoveryHandoff? {
        guard let defaults, let data = defaults.data(forKey: Self.key) else { return nil }
        guard let value = try? JSONDecoder().decode(PluginRecoveryHandoff.self, from: data),
              abs(now.timeIntervalSince(value.recordedAt)) <= Self.lifetime else {
            defaults.removeObject(forKey: Self.key)
            return nil
        }
        return value
    }

    public func clear() {
        lock.lock()
        defaults?.removeObject(forKey: Self.key)
        lock.unlock()
    }
}

/// Compatibility spelling for callers that describe this as a session rather
/// than a handoff. Both names intentionally share the same implementation and
/// App-Group key.
public typealias PluginRecoverySessionStore = PluginRecoveryHandoffStore
