import Foundation

public enum PodcastResumeDecision: Equatable {
    case resume(String), start(String), nothing
}
public enum PodcastPolicies {
    public static func ordered(_ episodes: [PodcastEpisode], newestFirst: Bool = false) -> [PodcastEpisode] {
        episodes.sorted {
            if $0.publishedAt == $1.publishedAt { return newestFirst ? $0.id > $1.id : $0.id < $1.id }
            return newestFirst ? $0.publishedAt > $1.publishedAt : $0.publishedAt < $1.publishedAt
        }
    }
    public static func resumeDecision(_ state: PodcastLibraryState) -> PodcastResumeDecision {
        guard let lastID = state.lastPlayedEpisodeID, state.episodes[lastID] != nil else { return .nothing }
        guard state.naturallyExhaustedQueue else { return .resume(lastID) }
        // Explicitly queued work takes precedence if it was added after exhaustion.
        if let queued = state.queue.first(where: { state.episodes[$0] != nil }) { return .start(queued) }
        let candidates = state.shows.values.filter(\.followed).compactMap { show -> PodcastEpisode? in
            let cursor = state.cursors[show.id]
            return ordered(state.episodes.values.filter { episode in
                guard episode.showID == show.id, state.progress[episode.id]?.listened != true else { return false }
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
        if state.settings.downloadSavedEpisodes {
            result.formUnion(state.progress.filter { $0.value.saved && !$0.value.suppressAutomaticDownload }.map(\.key))
        }
        return result
    }
    public static func shouldRemoveDownload(episodeID: String, manual: Bool, wanted: Set<String>, state: PodcastLibraryState, now: Date = Date()) -> Bool {
        let progress = state.progress[episodeID]
        guard progress?.saved != true else { return false }
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

/// Pure monotonic-time recognizer. The caller schedules expiration and routes
/// actions, including failures, through one serialized media coordinator.
public struct MediaSkipGesture {
    public enum Direction { case backward, forward }
    public enum Action: Equatable { case backward, forward, switchQueue }
    private var pendingBack: TimeInterval?
    public init() {}
    public mutating func receive(_ direction: Direction, at time: TimeInterval, canSwitch: Bool) -> [Action] {
        if direction == .forward, let back = pendingBack, time >= back, time - back <= 2, canSwitch {
            pendingBack = nil; return [.switchQueue]
        }
        var actions: [Action] = []
        if pendingBack != nil { actions.append(.backward); pendingBack = nil }
        if direction == .backward { pendingBack = time } else { actions.append(.forward) }
        return actions
    }
    public mutating func expire(at time: TimeInterval) -> [Action] {
        guard let back = pendingBack, time - back >= 2 else { return [] }
        pendingBack = nil; return [.backward]
    }
    public mutating func cancel() { pendingBack = nil }
}
