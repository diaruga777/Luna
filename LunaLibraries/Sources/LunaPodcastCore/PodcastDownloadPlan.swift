import Foundation

/// A single ordered budget shared by queued, manual and subscription downloads.
public struct PodcastDownloadPlan: Equatable {
    public var episodeIDs: [String]
    public var reservedBytes: [String: Int64]
    public init(state: PodcastLibraryState, sizes: [String: Int64], manualIDs: [String] = [], protectedID: String? = nil) {
        var ordered: [String] = []
        var seen = Set<String>()
        let current = state.currentEpisodeID ?? (state.naturallyExhaustedQueue ? nil : state.lastPlayedEpisodeID)
        let currentIDs = current.flatMap { state.progress[$0]?.listened == true ? nil : [$0] } ?? []
        let automatic = PodcastPolicies.ordered(PodcastPolicies.automaticDownloads(state).compactMap { state.episodes[$0] }, newestFirst: true).map(\.id)
        for id in currentIDs + state.queue + manualIDs + automatic {
            guard state.episodes[id] != nil, seen.insert(id).inserted,
                  state.progress[id]?.suppressAutomaticDownload != true else { continue }
            ordered.append(id)
        }
        episodeIDs = []; reservedBytes = [:]
        var remaining = state.settings.maximumDownloadBytes
        // An open AVPlayer asset cannot be evicted if the cap is lowered mid-play.
        if let protectedID, let bytes = sizes[protectedID], bytes > 0 {
            episodeIDs.append(protectedID); reservedBytes[protectedID] = bytes
            remaining = max(0, remaining - bytes)
        }
        for id in ordered where id != protectedID {
            let measured = sizes[id] ?? 0
            let size = max(0, measured > 0 ? measured : state.episodes[id]?.byteCount ?? 0)
            guard remaining > 0, size <= remaining else { break }
            // Unknown enclosures reserve the remaining budget until measured;
            // lower-priority tasks cannot race them and overcommit the cap.
            let reservation = size > 0 ? size : remaining
            episodeIDs.append(id); reservedBytes[id] = reservation
            remaining -= reservation
        }
    }
}
