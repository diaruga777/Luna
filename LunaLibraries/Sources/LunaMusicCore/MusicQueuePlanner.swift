import Foundation

/// Pure selection policy, independent of authorization and the media-library service.
public enum MusicQueuePlanner {
    public struct Playlist: Equatable, Sendable {
        public let id: UInt64
        public let songIDs: [UInt64]
        public let lastPlayed: Date?

        public init(id: UInt64, songIDs: [UInt64], lastPlayed: Date? = nil) {
            self.id = id
            self.songIDs = songIDs
            self.lastPlayed = lastPlayed
        }
    }

    public static func playlist(containing songID: UInt64, in playlists: [Playlist]) -> Playlist? {
        playlists.filter { $0.songIDs.contains(songID) }.sorted { lhs, rhs in
            if lhs.lastPlayed != rhs.lastPlayed {
                return (lhs.lastPlayed ?? .distantPast) > (rhs.lastPlayed ?? .distantPast)
            }
            let lhsCount = Set(lhs.songIDs).count
            let rhsCount = Set(rhs.songIDs).count
            if lhsCount != rhsCount { return lhsCount > rhsCount }
            return lhs.id < rhs.id
        }.first
    }

    public static func songIDs<R: RandomNumberGenerator>(startingWith selected: UInt64,
                                                         playlist: Playlist?,
                                                         using generator: inout R) -> [UInt64] {
        var seen: Set<UInt64> = [selected]
        var remaining = (playlist?.songIDs ?? []).filter { seen.insert($0).inserted }
        remaining.shuffle(using: &generator)
        return [selected] + remaining
    }
}
