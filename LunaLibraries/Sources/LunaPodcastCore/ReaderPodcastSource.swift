import Foundation

/// Reader readouts are device-local episodes, never an RSS subscription or cloud asset.
public enum ReaderPodcastSource {
    public static let showID = "luna-reader-readouts"
    public static func episodeID(_ saveID: UUID) -> String {
        PodcastIdentity.episode(showID: showID, guid: saveID.uuidString)
    }
    public static func cloudState(_ state: PodcastLibraryState) -> PodcastLibraryState {
        var result = state
        let ids = Set(result.episodes.values.filter { $0.showID == showID }.map(\.id))
        result.shows.removeValue(forKey: showID)
        result.episodes = result.episodes.filter { !ids.contains($0.key) }
        result.progress = result.progress.filter { !ids.contains($0.key) }
        result.cursors.removeValue(forKey: showID)
        result.queue.removeAll { ids.contains($0) }; result.continuation.removeAll { ids.contains($0) }
        result.pendingNotificationEpisodeIDs?.removeAll { ids.contains($0) }
        if let id = result.currentEpisodeID, ids.contains(id) { result.currentEpisodeID = nil }
        if let id = result.lastPlayedEpisodeID, ids.contains(id) { result.lastPlayedEpisodeID = nil }
        for index in result.stations.indices { result.stations[index].showIDs.removeAll { $0 == showID } }
        return result
    }
}
