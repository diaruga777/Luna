import Foundation

public enum PodcastResumeDecision: Equatable {
    case resume(String), start(String), nothing
}
public enum PodcastPolicies {
    public static let refreshInterval: TimeInterval = 6 * 60 * 60

    public static func refreshOrder(_ shows: [PodcastShow]) -> [String] {
        shows.sorted {
            let left = $0.lastRefreshAttempt ?? $0.lastRefresh ?? .distantPast
            let right = $1.lastRefreshAttempt ?? $1.lastRefresh ?? .distantPast
            return left == right ? $0.id < $1.id : left < right
        }.map(\.id)
    }

    public static func ordered(_ episodes: [PodcastEpisode], newestFirst: Bool = false) -> [PodcastEpisode] {
        episodes.sorted {
            if $0.publishedAt == $1.publishedAt { return newestFirst ? $0.id > $1.id : $0.id < $1.id }
            return newestFirst ? $0.publishedAt > $1.publishedAt : $0.publishedAt < $1.publishedAt
        }
    }
    public static func resumeDecision(_ state: PodcastLibraryState, downloadedIDs: Set<String>) -> PodcastResumeDecision {
        guard let lastID = state.lastPlayedEpisodeID, state.episodes[lastID] != nil else { return .nothing }
        if !state.naturallyExhaustedQueue {
            // Completion can stage the next queued episode while paused or on
            // cold restoration, before it has actually earned last-played history.
            if state.progress[lastID]?.listened != true { return .resume(lastID) }
            if let currentID = state.currentEpisodeID, currentID != lastID,
               state.episodes[currentID] != nil, state.progress[currentID]?.listened != true { return .resume(currentID) }
        }
        // Completed history must never be replayed by Resume, even when the
        // queue was emptied manually or its natural-exhaustion flag is stale.
        // Explicit selections still take precedence over subscription fallback.
        if let queued = state.queue.first(where: { state.episodes[$0] != nil }) { return .start(queued) }
        let candidates = state.shows.values.filter(\.followed).compactMap { show -> PodcastEpisode? in
            let cursor = state.cursors[show.id]
            return ordered(state.episodes.values.filter { episode in
                guard episode.showID == show.id, downloadedIDs.contains(episode.id),
                      state.progress[episode.id]?.listened != true else { return false }
                guard let cursor else { return true }
                return episode.publishedAt > cursor.publishedAt ||
                    (episode.publishedAt == cursor.publishedAt && episode.id > cursor.episodeID)
            }).first
        }
        return ordered(candidates).first.map { .start($0.id) } ?? .nothing
    }
    public static func automaticDownloads(_ state: PodcastLibraryState) -> Set<String> {
        var result = Set<String>()
        for show in state.shows.values where show.followed && show.settings.automaticDownloadLimit != 0 {
            let candidates = ordered(state.episodes.values.filter {
                $0.showID == show.id && state.progress[$0.id]?.listened != true && state.progress[$0.id]?.suppressAutomaticDownload != true
            }, newestFirst: true)
            let limit = show.settings.automaticDownloadLimit
            result.formUnion((limit < 0 ? candidates : Array(candidates.prefix(limit))).map(\.id))
        }
        return result
    }
    public static let unstartedDownloadRetention: TimeInterval = 7 * 24 * 60 * 60

    public static func isExpiredAutomaticDownload(episodeID: String, manual: Bool, createdAt: Date, state: PodcastLibraryState, now: Date = Date()) -> Bool {
        let progress = state.progress[episodeID]
        return !manual && progress?.listened != true && progress?.lastPlayedAt == nil &&
            (progress?.position ?? 0) == 0 && now.timeIntervalSince(createdAt) >= unstartedDownloadRetention
    }
    public static func shouldRemoveDownload(episodeID: String, manual: Bool, wanted: Set<String>, state: PodcastLibraryState, now: Date = Date()) -> Bool {
        let progress = state.progress[episodeID]
        if progress?.listened == true {
            guard state.settings.removePlayedDownloads, let completed = progress?.completedAt else { return false }
            return now.timeIntervalSince(completed) >= state.settings.playedRetentionHours * 3600
        }
        return !manual && !wanted.contains(episodeID)
    }
    public static func stationEpisodes(_ station: PodcastStation, state: PodcastLibraryState) -> [PodcastEpisode] {
        let ids = station.allShows ? state.shows.values.filter(\.followed).map(\.id) : station.showIDs
        let episodes = ids.flatMap { id -> [PodcastEpisode] in
            let found = ordered(state.episodes.values.filter {
                $0.showID == id && (!station.unplayedOnly || state.progress[$0.id]?.listened != true) &&
                    (station.media == "all" || (station.media == "video" ? $0.isVideo : !$0.isVideo))
            }, newestFirst: station.newestFirst)
            return station.episodesPerShow > 0 ? Array(found.prefix(station.episodesPerShow)) : found
        }
        return ordered(episodes, newestFirst: station.newestFirst)
    }
}

/// Back applies immediately. A forward may switch for one monotonic second
/// after the caller reports that the backward operation completed successfully.
public struct MediaSkipGesture {
    public enum Direction { case backward, forward }
    public enum Action: Equatable { case backward, forward, switchQueue }
    private var backFinishedAt: TimeInterval?
    public init() {}
    public mutating func receive(_ direction: Direction, at time: TimeInterval, canSwitch: Bool) -> [Action] {
        defer { backFinishedAt = nil }
        if direction == .backward { return [.backward] }
        if let back = backFinishedAt, time >= back, time - back <= 1, canSwitch { return [.switchQueue] }
        return [.forward]
    }
    public mutating func backwardCompleted(at time: TimeInterval) { backFinishedAt = time }
    public mutating func cancel() { backFinishedAt = nil }
}
