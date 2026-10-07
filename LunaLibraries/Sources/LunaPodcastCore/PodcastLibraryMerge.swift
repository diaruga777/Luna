import Foundation

public enum PodcastLibraryMerge {
    public static func merge(local: PodcastLibraryState, remote: PodcastLibraryState) -> PodcastLibraryState {
        guard remote.schemaVersion == local.schemaVersion else { return local }
        var result = local
        for (id, show) in remote.shows where show.updatedAt > (local.shows[id]?.updatedAt ?? .distantPast) { result.shows[id] = show }
        for (id, episode) in remote.episodes where result.episodes[id] == nil { result.episodes[id] = episode }
        for (id, progress) in remote.progress where progress.updatedAt > (local.progress[id]?.updatedAt ?? .distantPast) { result.progress[id] = progress }
        for (id, cursor) in remote.cursors where cursor.updatedAt > (local.cursors[id]?.updatedAt ?? .distantPast) { result.cursors[id] = cursor }
        for (id, date) in remote.deletedStations { result.deletedStations[id] = max(date, result.deletedStations[id] ?? .distantPast) }
        var stations = Dictionary(local.stations.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for station in remote.stations where station.updatedAt > (stations[station.id]?.updatedAt ?? .distantPast) { stations[station.id] = station }
        result.stations = stations.values.filter { $0.updatedAt > (result.deletedStations[$0.id] ?? .distantPast) }.sorted { $0.id < $1.id }
        // Each device retains its active playback and queue. Import last-listened
        // identity only on a device that has never played a podcast.
        if result.lastPlayedEpisodeID == nil {
            result.lastPlayedEpisodeID = remote.lastPlayedEpisodeID
            result.currentEpisodeID = remote.lastPlayedEpisodeID
            result.naturallyExhaustedQueue = remote.naturallyExhaustedQueue
        }
        return result
    }
}
