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
    /// Whether `title`/`imageData` came from a metadata read that actually
    /// SUCCEEDED, rather than from the host fallback a failed read leaves
    /// behind.
    ///
    /// Load-bearing, because the refresher skips an entry whose signed value it
    /// already holds: without this, ONE failed read (offline at launch, a
    /// timeout, a transient 5xx) parked the row on "www.example.com" plus the
    /// generic glyph for the entry's whole 30-day life, and every later launch
    /// looked at the matching URL/date and moved on. A `false` here is the
    /// refresher's cue to try again next launch.
    public var hasResolvedMetadata: Bool

    public init(
        save: WeeklySave, title: String, subtitleHost: String, imageData: Data? = nil,
        hasResolvedMetadata: Bool = true
    ) {
        self.save = save
        self.title = title
        self.subtitleHost = subtitleHost
        self.imageData = imageData
        self.hasResolvedMetadata = hasResolvedMetadata
    }

    /// Hand-written so a `weeklySaves.json` from a build that predates
    /// `hasResolvedMetadata` still decodes — as UNRESOLVED, which is what
    /// re-resolves the rows this flag was added for. (`encode(to:)` stays
    /// synthesized.)
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        save = try container.decode(WeeklySave.self, forKey: .save)
        title = try container.decode(String.self, forKey: .title)
        subtitleHost = try container.decode(String.self, forKey: .subtitleHost)
        imageData = try container.decodeIfPresent(Data.self, forKey: .imageData)
        hasResolvedMetadata =
            try container.decodeIfPresent(Bool.self, forKey: .hasResolvedMetadata) ?? false
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
        var displays: [WeeklySaveKind: WeeklySaveDisplay]
        var seenProposalIDs: [String]

        private enum CodingKeys: String, CodingKey {
            case displays, seenProposalIDs
        }

        init(displays: [WeeklySaveKind: WeeklySaveDisplay], seenProposalIDs: [String]) {
            self.displays = displays
            self.seenProposalIDs = seenProposalIDs
        }

        /// `displays` round-trips through a plain `[String: WeeklySaveDisplay]`
        /// on the wire. `Dictionary`'s synthesized `Codable` only special-cases
        /// `String`/`Int` keys as a JSON object — any other key type, including
        /// a `String`-backed enum, falls back to encoding as an alternating
        /// key/value ARRAY. Coding through the raw form here keeps
        /// `weeklySaves.json` byte-identical to before `displays` was keyed by
        /// `WeeklySaveKind` instead of its raw value. A key this build doesn't
        /// recognize (already-garbled JSON, or a kind a newer build added) is
        /// dropped rather than failing the whole decode.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let rawDisplays = try container.decode([String: WeeklySaveDisplay].self, forKey: .displays)
            displays = rawDisplays.reduce(into: [:]) { result, entry in
                guard let kind = WeeklySaveKind(rawValue: entry.key) else { return }
                result[kind] = entry.value
            }
            seenProposalIDs = try container.decode([String].self, forKey: .seenProposalIDs)
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            let rawDisplays = Dictionary(uniqueKeysWithValues: displays.map { ($0.key.rawValue, $0.value) })
            try container.encode(rawDisplays, forKey: .displays)
            try container.encode(seenProposalIDs, forKey: .seenProposalIDs)
        }
    }

    private let fileURL: URL?
    private let now: () -> Date
    private let lock = NSLock()
    private var payload = Payload(displays: [:], seenProposalIDs: [])

    public init(containerURL: URL? = nil, now: @escaping () -> Date = Date.init) {
        self.now = now
        let base = containerURL ?? AppConfig.sharedContainerURL()
        self.fileURL = base?.appendingPathComponent("weeklySaves.json")
        loadFromDisk()
    }

    // MARK: - Displays

    /// The live entry for a kind, or nil when there is none or it has aged out.
    public func display(for kind: WeeklySaveKind) -> WeeklySaveDisplay? {
        lock.lock(); defer { lock.unlock() }
        guard let display = payload.displays[kind],
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
        let changed = payload.displays[kind] != display
        payload.displays[kind] = display
        if changed { persistLocked() }
        lock.unlock()
        if changed { postChange(kind) }
    }

    public func clear(kind: WeeklySaveKind) {
        lock.lock()
        let changed = payload.displays.removeValue(forKey: kind) != nil
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
