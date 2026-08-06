//
//  WeeklySaveStore.swift
//  LunaWeekly
//

import Foundation
import LunaAppConfig
import LunaStorage

/// Everything the util-card row needs to draw itself without touching the
/// network: the signed entry plus the display metadata that was resolved once,
/// when the entry arrived.
public struct WeeklySaveDisplay: Codable, Equatable, Sendable {
    public var save: WeeklySave
    public var title: String
    public var subtitleHost: String
    /// Already downscaled by whatever fetched it — this file is read on every
    /// launch.
    public var imageData: Data?

    public init(save: WeeklySave, title: String, subtitleHost: String, imageData: Data? = nil) {
        self.save = save
        self.title = title
        self.subtitleHost = subtitleHost
        self.imageData = imageData
    }
}

/// The single source of truth for "is there a save of the week, and what does
/// it say". Sidecar JSON in the App Group (`weeklySaves.json`) beside the
/// reading list, same cheap-lock + atomic-write shape as `SaveFailureStore`.
///
/// Expiry is evaluated on READ against the injected clock, so no sweep, no
/// timer, and no migration: a 31-day-old entry simply stops being returned.
public final class WeeklySaveStore {
    public static let shared = WeeklySaveStore()

    /// Posted (main thread) whenever a kind's display changes. `userInfo` carries
    /// the kind's raw value under `WeeklySaveStore.kindKey`.
    public static let didChange = Notification.Name("lunaWeeklySaveStoreDidChange")
    public static let kindKey = "kind"

    private struct Payload: Codable {
        var displays: [String: WeeklySaveDisplay]
        var seenProposalIDs: [String]
    }

    private let fileURL: URL?
    private let now: () -> Date
    private let lock = NSLock()
    private var payload = Payload(displays: [:], seenProposalIDs: [])

    public init(containerURL: URL? = nil, now: @escaping () -> Date = Date.init) {
        self.now = now
        let base = containerURL ?? FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: AppConfig.appGroupID)
        self.fileURL = base?.appendingPathComponent("weeklySaves.json")
        loadFromDisk()
    }

    // MARK: - Displays

    /// The live entry for a kind, or nil when there is none or it has aged out.
    public func display(for kind: WeeklySaveKind) -> WeeklySaveDisplay? {
        lock.lock(); defer { lock.unlock() }
        guard let display = payload.displays[kind.rawValue],
              !display.save.isExpired(now: now())
        else { return nil }
        return display
    }

    /// Every live entry among `kinds`, in the order given — what the central
    /// app's cycle iterates.
    public func liveDisplays(for kinds: [WeeklySaveKind]) -> [WeeklySaveDisplay] {
        kinds.compactMap { display(for: $0) }
    }

    public func setDisplay(_ display: WeeklySaveDisplay, for kind: WeeklySaveKind) {
        lock.lock()
        let changed = payload.displays[kind.rawValue] != display
        payload.displays[kind.rawValue] = display
        if changed { persistLocked() }
        lock.unlock()
        if changed { postChange(kind) }
    }

    public func clear(kind: WeeklySaveKind) {
        lock.lock()
        let changed = payload.displays.removeValue(forKey: kind.rawValue) != nil
        if changed { persistLocked() }
        lock.unlock()
        if changed { postChange(kind) }
    }

    // MARK: - Proposal notification dedup

    /// Record names already announced, so the same proposal is never notified
    /// twice across launches.
    public func seenProposalIDs() -> Set<String> {
        lock.lock(); defer { lock.unlock() }
        return Set(payload.seenProposalIDs)
    }

    /// Marks ONE record name announced, leaving the rest of the set alone —
    /// the proposal this device just wrote, which its own curator does not
    /// need telling about. The next full check prunes it like any other.
    public func markProposalSeen(_ id: String) {
        lock.lock(); defer { lock.unlock() }
        guard !payload.seenProposalIDs.contains(id) else { return }
        payload.seenProposalIDs = (payload.seenProposalIDs + [id]).sorted()
        persistLocked()
    }

    /// Marks these record names announced and forgets any that are no longer
    /// present, so the set can't grow without bound.
    public func markProposalsSeen(_ ids: Set<String>) {
        lock.lock(); defer { lock.unlock() }
        let updated = Array(ids).sorted()
        guard updated != payload.seenProposalIDs else { return }
        payload.seenProposalIDs = updated
        persistLocked()
    }

    // MARK: - Private

    private func postChange(_ kind: WeeklySaveKind) {
        let post = {
            NotificationCenter.default.post(
                name: Self.didChange, object: nil,
                userInfo: [Self.kindKey: kind.rawValue])
        }
        if Thread.isMainThread { post() } else { DispatchQueue.main.async(execute: post) }
    }

    private func loadFromDisk() {
        guard let fileURL, let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder.weekly.decode(Payload.self, from: data)
        else { return }
        payload = decoded
    }

    private func persistLocked() {
        guard let fileURL, let data = try? JSONEncoder.weekly.encode(payload) else { return }
        try? data.write(to: fileURL, options: .atomic)
        BackupPolicy.includeInBackups(fileURL)
    }
}

private extension JSONEncoder {
    static var weekly: JSONEncoder {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; return encoder
    }
}
private extension JSONDecoder {
    static var weekly: JSONDecoder {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601; return decoder
    }
}
