//
//  FirecrawlSearchCooldown.swift
//  LunaFetch
//

import Foundation
import LunaAppConfig

/// How long the device must stop asking Firecrawl for.
///
/// Firecrawl's keyless caps are metered PER IP, so the app, the share extension
/// and the action extension all spend one budget and all learn about a 429 from
/// whichever process happened to hit it. That is why this lives in the shared
/// App Group defaults rather than in a process-local static: a save through the
/// share sheet must not re-discover a daily cap the app already found.
///
/// A 429 that arrives with `Retry-After` is honoured verbatim. Without one, the
/// wait escalates — 60 s, then double per consecutive refusal, capped at four
/// hours, which is short enough that a per-minute cap clears on its own and long
/// enough that a daily cap is not probed all afternoon. A successful search
/// resets the escalation, so the next cap starts at 60 s again.
public final class FirecrawlSearchCooldown {

    /// The instance every production caller uses.
    public static let shared = FirecrawlSearchCooldown()

    /// The wait after the first 429 that names no `Retry-After`.
    public static let firstStep: TimeInterval = 60

    /// The ceiling the doubling stops at.
    public static let maximumStep: TimeInterval = 4 * 60 * 60

    private static let cooldownUntilKey = "firecrawl.search.cooldownUntil"
    private static let cooldownStepKey = "firecrawl.search.cooldownStep"

    private let defaults: UserDefaults
    private let now: () -> Date
    private let lock = NSLock()

    /// `defaults` and `now` are injected so a test asserts the escalation
    /// without waiting for it or writing the user's real App Group.
    public init(defaults: UserDefaults? = nil, now: @escaping () -> Date = Date.init) {
        self.defaults = defaults ?? UserDefaults(suiteName: AppConfig.appGroupID) ?? .standard
        self.now = now
    }

    /// Seconds left before Firecrawl may be asked again, or nil when it may be
    /// asked now.
    public func remaining() -> TimeInterval? {
        lock.lock(); defer { lock.unlock() }
        let until = defaults.double(forKey: Self.cooldownUntilKey)
        guard until > 0 else { return nil }
        let left = until - now().timeIntervalSinceReferenceDate
        return left > 0 ? left : nil
    }

    /// Whether Firecrawl is currently barred.
    public var isCoolingDown: Bool { remaining() != nil }

    /// Records a 429 and returns the wait it applied.
    ///
    /// The escalation step advances on EVERY refusal, including one that carried
    /// a `Retry-After`: consecutive 429s are the thing being counted, and a
    /// server that asked for five seconds twice in a row has still refused
    /// twice. The header decides this wait; the step decides the next one that
    /// arrives bare.
    @discardableResult
    public func recordRateLimit(retryAfter: TimeInterval?) -> TimeInterval {
        lock.lock(); defer { lock.unlock() }
        let previous = defaults.double(forKey: Self.cooldownStepKey)
        let step = previous <= 0
            ? Self.firstStep
            : min(previous * 2, Self.maximumStep)
        defaults.set(step, forKey: Self.cooldownStepKey)
        let wait = retryAfter.map { max(0, $0) } ?? step
        defaults.set(
            now().timeIntervalSinceReferenceDate + wait, forKey: Self.cooldownUntilKey)
        return wait
    }

    /// Records a served search: the escalation starts over, and any expired
    /// cooldown stamp goes with it.
    public func recordSuccess() {
        lock.lock(); defer { lock.unlock() }
        defaults.removeObject(forKey: Self.cooldownStepKey)
        defaults.removeObject(forKey: Self.cooldownUntilKey)
    }
}
