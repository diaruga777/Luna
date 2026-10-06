import Foundation

/// Pure selection policy, independent of authorization and the media-library service.
public enum MusicQueuePlanner {
    public struct Playlist: Equatable, Sendable {
        public let id: MusicID
        public let songIDs: [MusicID]
        public let lastPlayed: Date?
        public let isAutomatic: Bool

        public init(id: MusicID, songIDs: [MusicID], lastPlayed: Date? = nil, isAutomatic: Bool = false) {
            self.id = id
            self.songIDs = songIDs
            self.lastPlayed = lastPlayed
            self.isAutomatic = isAutomatic
        }
    }

    public static func playlist(containing songID: MusicID, in playlists: [Playlist]) -> Playlist? {
        playlists.filter { !$0.isAutomatic && $0.songIDs.contains(songID) }.sorted { lhs, rhs in
            if lhs.lastPlayed != rhs.lastPlayed {
                return (lhs.lastPlayed ?? .distantPast) > (rhs.lastPlayed ?? .distantPast)
            }
            let lhsCount = Set(lhs.songIDs).count
            let rhsCount = Set(rhs.songIDs).count
            if lhsCount != rhsCount { return lhsCount > rhsCount }
            return lhs.id < rhs.id
        }.first
    }

    public static func songIDs<R: RandomNumberGenerator>(startingWith selected: MusicID,
                                                         playlist: Playlist?,
                                                         using generator: inout R) -> [MusicID] {
        var seen: Set<MusicID> = [selected]
        var remaining = (playlist?.songIDs ?? []).filter { seen.insert($0).inserted }
        remaining.shuffle(using: &generator)
        return [selected] + remaining
    }
}
