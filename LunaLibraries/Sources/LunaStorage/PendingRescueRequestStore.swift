//
//  PendingRescueRequestStore.swift
//  LunaStorage
//

import Foundation
import LunaAppConfig
import LunaModels

/// One pending extension→app rescue hand-off: the user tapped "Finish in Luna"
/// on a failed share, so the main app should rescue this URL (with this hint)
/// next time it's foregrounded.
public struct PendingRescueRequest: Codable, Equatable {
    public let urlString: String
    public let hint: RescueHint?
    public let dateWritten: Date
    /// The originating surface's storage identifier, for diagnostics.
    public let sourceSurface: String?

    public init(urlString: String, hint: RescueHint?, dateWritten: Date, sourceSurface: String? = nil) {
        self.urlString = urlString
        self.hint = hint
        self.dateWritten = dateWritten
        self.sourceSurface = sourceSurface
    }
}

/// App-Group-backed queue of pending rescue hand-offs. Modeled on
/// `DoubleSaveActionStore`'s take-semantics + expiry, but holds an ARRAY —
/// several failed shares can queue before the app opens. The main app drains it
/// on launch / foreground / the `<scheme>://rescue` deep link.
public final class PendingRescueRequestStore {
    public static let shared = PendingRescueRequestStore()

    /// A share-sheet failure the user opens Luna for the next morning must
    /// survive — 3 days (vs DoubleSave's 5-minute intent hand-off).
    public static let lifetime: TimeInterval = 3 * 24 * 60 * 60

    private static let key = "rescue.pendingRequests"

    private let defaults: UserDefaults
    private let now: () -> Date
    private let lock = NSLock()

    public init(defaults: UserDefaults? = nil, now: @escaping () -> Date = Date.init) {
        self.defaults = defaults ?? UserDefaults(suiteName: AppConfig.appGroupID) ?? .standard
        self.now = now
    }

    /// Appends a request, replacing any existing one for the same URL (keeping
    /// the newest hint/date). Drops expired entries in passing.
    public func append(_ request: PendingRescueRequest) {
        lock.lock(); defer { lock.unlock() }
        var current = loadLocked().filter { $0.urlString != request.urlString }
        current.append(request)
        saveLocked(current)
    }

    /// One-shot: returns all non-expired pending requests and clears the queue.
    public func takeAll() -> [PendingRescueRequest] {
        lock.lock(); defer { lock.unlock() }
        let fresh = loadLocked()
        defaults.removeObject(forKey: Self.key)
        return fresh
    }

    /// Non-destructive peek (for diagnostics / tests).
    public func peek() -> [PendingRescueRequest] {
        lock.lock(); defer { lock.unlock() }
        return loadLocked()
    }

    // MARK: - Private

    private func loadLocked() -> [PendingRescueRequest] {
        guard let data = defaults.data(forKey: Self.key),
              let all = try? JSONDecoder().decode([PendingRescueRequest].self, from: data) else { return [] }
        return all.filter { now().timeIntervalSince($0.dateWritten) < Self.lifetime }
    }

    private func saveLocked(_ requests: [PendingRescueRequest]) {
        guard let data = try? JSONEncoder().encode(requests) else { return }
        defaults.set(data, forKey: Self.key)
    }
}
