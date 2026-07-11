//
//  AudioPlaybackPositionStore.swift
//  LunaAudioPlayback
//

import LunaAppConfig
import Foundation

/// One playback session's resume state, persisted cheaply (App-Group
/// `UserDefaults`, NOT the reading-list store) roughly every 5s while playing,
/// plus on every pause/seek/finish — so a cold relaunch, or a remote "play"
/// command arriving while `AudioPlaybackCenter` is idle, can restore without
/// re-deriving anything from the reading list (see
/// `claudedocs/audio-playback-plan.md`).
///
/// This is DELIBERATELY separate from `ReadingListItem.lastSpokenWordIndex`
/// (mirrored into the store far less often — see `AudioPlaybackCenter`) and
/// from `AudioSettings` (a plain App-Group-singleton enum with no test seam):
/// position persistence needs an injectable `UserDefaults` suite so its
/// round-trip is unit-testable without touching the real App Group, the same
/// pattern `LunaStorage.SafariExtensionStatusStore` already uses.
public final class AudioPlaybackPositionStore {
    public struct Position: Equatable {
        public var itemID: UUID
        public var wordIndex: Int
        public var elapsed: TimeInterval
        public var title: String
        /// When this position was saved — the input to the Phase 6
        /// extension-handoff recency check (`AudioPlaybackCenter.
        /// restorableHandoffIfAvailable`/`handoffRecencyWindow`). Defaults to
        /// "now" so every existing call site (which never passed a
        /// timestamp) keeps compiling and behaving exactly as before.
        public var savedAt: Date

        public init(itemID: UUID, wordIndex: Int, elapsed: TimeInterval, title: String, savedAt: Date = Date()) {
            self.itemID = itemID
            self.wordIndex = wordIndex
            self.elapsed = elapsed
            self.title = title
            self.savedAt = savedAt
        }
    }

    private let defaults: UserDefaults
    private static let key = "audioPlaybackPosition.v1"

    /// - Parameter defaults: defaults to the shared App Group suite; tests
    ///   pass a scratch `UserDefaults(suiteName:)` instead.
    public init(defaults: UserDefaults = UserDefaults(suiteName: AppConfig.appGroupID) ?? .standard) {
        self.defaults = defaults
    }

    public func save(_ position: Position) {
        let dict: [String: Any] = [
            "itemID": position.itemID.uuidString,
            "wordIndex": position.wordIndex,
            "elapsed": position.elapsed,
            "title": position.title,
            // Date's native representation — timeIntervalSince1970 round-trips
            // with sub-second precision loss, which breaks exact equality and
            // the handoff recency-window boundary.
            "savedAtRef": position.savedAt.timeIntervalSinceReferenceDate,
        ]
        defaults.set(dict, forKey: Self.key)
    }

    public func load() -> Position? {
        guard let dict = defaults.dictionary(forKey: Self.key),
              let idString = dict["itemID"] as? String,
              let itemID = UUID(uuidString: idString),
              let wordIndex = dict["wordIndex"] as? Int,
              let elapsed = dict["elapsed"] as? Double,
              let title = dict["title"] as? String
        else { return nil }
        // Older saves (pre-Phase-6 wrote no timestamp; early Phase 6 wrote
        // "savedAt" as timeIntervalSince1970) — treat those as saved right
        // now rather than failing the whole load, since a missing timestamp
        // must never crash the existing cold-relaunch restore path.
        let savedAt = (dict["savedAtRef"] as? Double).map(Date.init(timeIntervalSinceReferenceDate:))
            ?? (dict["savedAt"] as? Double).map(Date.init(timeIntervalSince1970:))
            ?? Date()
        return Position(itemID: itemID, wordIndex: wordIndex, elapsed: elapsed, title: title, savedAt: savedAt)
    }

    public func clear() {
        defaults.removeObject(forKey: Self.key)
    }
}
