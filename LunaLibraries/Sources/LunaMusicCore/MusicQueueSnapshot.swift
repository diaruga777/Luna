import Foundation

/// A paused queue can be shown after relaunch without claiming the system audio session.
struct MusicQueueSnapshot: Codable, Equatable {
    var songIDs: [MusicID]
    var currentIndex: Int
    var playbackTime: TimeInterval
    var originalSongIDs: [MusicID]
    var shuffleEnabled: Bool
    var repeatMode: Int
    var sourcePlaylistName: String?
    var sourcePlaylistID: MusicID?

    func resolving(availableIDs: Set<MusicID>) -> MusicQueueSnapshot? {
        let indexed = songIDs.enumerated().filter { availableIDs.contains($0.element) }
        guard !indexed.isEmpty else { return nil }
        var result = self
        result.songIDs = indexed.map(\.element)
        // If the current song was removed, continue at its next surviving neighbour.
        let chosen = indexed.firstIndex { $0.offset >= currentIndex } ?? indexed.count - 1
        result.currentIndex = chosen
        result.playbackTime = indexed[chosen].offset == currentIndex && playbackTime.isFinite ? max(0, playbackTime) : 0
        result.originalSongIDs = originalSongIDs.filter { availableIDs.contains($0) }
        return result
    }
}
