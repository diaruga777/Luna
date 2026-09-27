import ActivityKit
import Foundation

// Retained only to dismiss queue Live Activities created by older releases.
struct MusicActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var title: String
        var artist: String
        var nextTitle: String?
        var playlist: String?
        var isPlaying: Bool
        var elapsed: TimeInterval
        var duration: TimeInterval
        var updatedAt: Date

        var playbackStart: Date { updatedAt.addingTimeInterval(-elapsed) }
    }
    var sessionID: UUID
}

struct MusicWidgetSnapshot: Codable {
    var state: MusicActivityAttributes.ContentState

    var expiresAt: Date {
        state.updatedAt.addingTimeInterval(state.isPlaying ? max(30, state.duration - state.elapsed + 15) : 86_400)
    }

    static let kind = "LunaMusicLibraryWidget"
    static var storeURL: URL? {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "LunaAppGroupID") as? String,
              let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)
        else { return nil }
        return container.appendingPathComponent("music-widget.json")
    }

    static func read() -> MusicWidgetSnapshot? {
        guard let url = storeURL, let data = try? Data(contentsOf: url) else { return nil }
        guard let snapshot = try? JSONDecoder().decode(Self.self, from: data), snapshot.expiresAt > Date() else { return nil }
        return snapshot
    }
}
