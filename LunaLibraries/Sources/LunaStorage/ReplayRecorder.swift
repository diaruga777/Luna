//
//  ReplayRecorder.swift
//  ReaderKit
//

import LunaModels
import Foundation

/// Records a `Replay` for one save: started with `begin`, fed events as the
/// pipeline runs, and `terminate`d when the save fails or reaches its terminal
/// readable state. On termination the replay is serialized to pretty JSON, zipped,
/// and stored in the app sandbox Documents folder. The viewer/row can later look
/// up a terminated replay by item URL (for the bug-report affordances).
///
/// A no-op implementation (`NoopReplayRecorder`) lets a save run with no recording
/// (e.g. unit tests of the pipeline), so recording is never load-bearing.
public protocol ReplayRecording: Sendable {
    /// Opens a new in-progress replay for `urlString` captured from `source`.
    /// Returns the replay id used to address subsequent events; nil if recording
    /// is disabled (the caller then records nothing).
    func begin(urlString: String, source: ReplaySource) async -> UUID?

    /// Appends one event to the in-progress replay `id`. No-ops for an unknown id.
    func record(_ kind: EventKind, for id: UUID) async

    /// Associates the produced reading-list item id with the replay (for lookup).
    func attachItemID(_ itemID: UUID, to id: UUID) async

    /// Repoints the replay's item URL (e.g. after a news-aggregator unwrap), so it
    /// lists/looks up under the real publisher URL.
    func updateItemURL(_ urlString: String, for id: UUID) async

    /// Terminates the in-progress replay `id`: sets its terminal `state` and
    /// optional `finalContent`, serializes + zips it to Documents, and drops it
    /// from memory. No-ops for an unknown id.
    func terminate(_ id: UUID, state: Replay.ReplayState, finalContent: ArticleContent?) async

    /// The most recent TERMINATED replay for `itemURLString`, decoded from disk, or
    /// nil. Used by the bug-report affordances to find the replay for an item.
    func terminatedReplay(forItemURLString itemURLString: String) async -> Replay?

    /// Marks the most recent terminated replay for `itemURLString` as
    /// `.userReported`, rewrites its export, and returns the export zip URL (for the
    /// share sheet), or nil if none exists.
    func markUserReported(forItemURLString itemURLString: String) async -> URL?

    /// All stored replays, newest first (for the Replays settings list).
    func storedReplays() async -> [StoredReplay]
}

/// A stored replay's listing metadata + its export location. Lightweight (no
/// events) so the list screen never loads full replays.
public struct StoredReplay: Equatable, Sendable {
    public var id: UUID
    public var itemURLString: String
    public var state: Replay.ReplayState
    public var createdAt: Date
    /// The export zip in the Documents/Replays folder.
    public var zipURL: URL

    public init(id: UUID, itemURLString: String, state: Replay.ReplayState,
                createdAt: Date, zipURL: URL) {
        self.id = id
        self.itemURLString = itemURLString
        self.state = state
        self.createdAt = createdAt
        self.zipURL = zipURL
    }
}

/// A recorder that does nothing — the default for code paths (and tests) that
/// don't want to record. Every method is a no-op returning empties.
public struct NoopReplayRecorder: ReplayRecording {
    public init() {}
    public func begin(urlString: String, source: ReplaySource) async -> UUID? { nil }
    public func record(_ kind: EventKind, for id: UUID) async {}
    public func attachItemID(_ itemID: UUID, to id: UUID) async {}
    public func updateItemURL(_ urlString: String, for id: UUID) async {}
    public func terminate(_ id: UUID, state: Replay.ReplayState, finalContent: ArticleContent?) async {}
    public func terminatedReplay(forItemURLString itemURLString: String) async -> Replay? { nil }
    public func markUserReported(forItemURLString itemURLString: String) async -> URL? { nil }
    public func storedReplays() async -> [StoredReplay] { [] }
}

/// The live recorder: an actor (thread-safe by isolation) holding in-progress
/// replays in memory and delegating disk I/O to a `ReplayStoring`.
///
/// Memory: only IN-PROGRESS replays are held, with their event list growing for
/// the duration of one save. Body text is capped per event by the recorder before
/// it's stored. On termination the replay is written to disk and dropped from
/// memory — nothing accumulates across saves.
public actor ReplayRecorder: ReplayRecording {
    public static let shared = ReplayRecorder(store: ReplayDiskStore())

    /// Largest text body retained verbatim per event; longer bodies are truncated
    /// (with the dropped byte count recorded) so a huge page can't bloat the export.
    public static let maxBodyBytes = 2 * 1024 * 1024

    private let store: ReplayStoring
    private var inProgress: [UUID: Replay] = [:]
    private var nextIndex: [UUID: Int] = [:]

    public init(store: ReplayStoring) {
        self.store = store
    }

    public func begin(urlString: String, source: ReplaySource) async -> UUID? {
        let id = UUID()
        let replay = Replay(
            metadata: Replay.Metadata(
                id: id, state: .inProgress, createdAt: Date(), terminatedAt: nil,
                itemURLString: urlString, itemID: nil),
            input: Replay.Input(initialURLString: urlString, source: source))
        inProgress[id] = replay
        nextIndex[id] = 0
        return id
    }

    public func record(_ kind: EventKind, for id: UUID) async {
        guard var replay = inProgress[id] else { return }
        let index = nextIndex[id] ?? replay.events.count
        replay.events.append(Replay.Event(index: index, timestamp: Date(), kind: capped(kind)))
        nextIndex[id] = index + 1
        inProgress[id] = replay
    }

    public func attachItemID(_ itemID: UUID, to id: UUID) async {
        inProgress[id]?.metadata.itemID = itemID
    }

    public func updateItemURL(_ urlString: String, for id: UUID) async {
        inProgress[id]?.metadata.itemURLString = urlString
    }

    public func terminate(_ id: UUID, state: Replay.ReplayState, finalContent: ArticleContent?) async {
        guard var replay = inProgress.removeValue(forKey: id) else { return }
        nextIndex[id] = nil
        let index = replay.events.count
        replay.events.append(
            Replay.Event(index: index, timestamp: Date(), kind: .stateChange(state)))
        replay.metadata.state = state
        replay.metadata.terminatedAt = Date()
        replay.finalContent = finalContent
        store.write(replay)
    }

    public func terminatedReplay(forItemURLString itemURLString: String) async -> Replay? {
        store.newestReplay(forItemURLString: itemURLString)
    }

    public func markUserReported(forItemURLString itemURLString: String) async -> URL? {
        guard var replay = store.newestReplay(forItemURLString: itemURLString) else { return nil }
        let index = replay.events.count
        replay.events.append(
            Replay.Event(index: index, timestamp: Date(), kind: .stateChange(.userReported)))
        replay.metadata.state = .userReported
        store.write(replay)
        return store.zipURL(for: replay.metadata.id)
    }

    public func storedReplays() async -> [StoredReplay] {
        store.storedReplays()
    }

    /// Truncates oversized text bodies inside a network event so memory/disk stay
    /// bounded. Other event kinds pass through unchanged.
    private func capped(_ kind: EventKind) -> EventKind {
        switch kind {
        case let .networkRequest(request):
            var request = request
            request.body = request.body.map(Self.capBody)
            return .networkRequest(request)
        case let .networkResponse(response):
            var response = response
            response.body = response.body.map(Self.capBody)
            return .networkResponse(response)
        default:
            return kind
        }
    }

    private static func capBody(_ body: HTTPBody) -> HTTPBody {
        guard case let .text(value, alreadyTruncated) = body else { return body }
        let utf8Count = value.utf8.count
        guard utf8Count > maxBodyBytes else { return body }
        let prefix = String(decoding: Array(value.utf8.prefix(maxBodyBytes)), as: UTF8.self)
        return .text(prefix, truncatedBytes: alreadyTruncated + (utf8Count - prefix.utf8.count))
    }
}
