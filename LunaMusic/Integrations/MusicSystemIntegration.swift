import LunaMusicCore
import LunaPodcastCore
import ActivityKit
import MediaPlayer
import UIKit
import WidgetKit
import OSLog

/// Publishes the app queue without taking ownership of Music's system Now Playing session.
@MainActor final class MusicSystemIntegration {
    static let shared = MusicSystemIntegration()
    private var observers: [NSObjectProtocol] = []
    private var worker: Task<Void, Never>?
    private var needsRefresh = false
    private var lastState: MusicActivityAttributes.ContentState?
    private var lastSongID: MusicID?
    private let log = Logger(subsystem: "LunaMusic", category: "SystemIntegration")

    func start() {
        guard observers.isEmpty else { return }
        for name in [Notification.Name.lunaMusicPlaybackChanged, .lunaPodcastPlaybackChanged, .lunaMediaSurfaceChanged, UIApplication.didBecomeActiveNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.scheduleRefresh() }
            })
        }
        LunaMusicShortcuts.updateAppShortcutParameters()
        Task {
            for existing in Activity<MusicActivityAttributes>.activities {
                await existing.end(nil, dismissalPolicy: .immediate)
            }
        }
        scheduleRefresh()
    }

    private func scheduleRefresh() {
        needsRefresh = true
        guard worker == nil else { return }
        worker = Task { [weak self] in
            guard let self else { return }
            while needsRefresh {
                needsRefresh = false
                await refresh()
            }
            worker = nil
        }
    }

    private func refresh() async {
        if MediaPlaybackCoordinator.shared.active == .podcasts,
           let episode = PodcastPlaybackController.shared.currentEpisode {
            let player = PodcastPlaybackController.shared
            let library = PodcastLibraryController.shared.state
            let state = MusicActivityAttributes.ContentState(title: episode.title, artist: library.shows[episode.showID]?.title ?? "Podcast", nextTitle: (library.queue + library.continuation).first.flatMap { library.episodes[$0]?.title }, playlist: "Podcasts", isPlaying: player.isPlaying, elapsed: player.position, duration: player.duration, updatedAt: Date())
            if let url = MusicWidgetSnapshot.storeURL, let data = try? JSONEncoder().encode(MusicWidgetSnapshot(state: state)) {
                try? data.write(to: url, options: [.atomic]); WidgetCenter.shared.reloadTimelines(ofKind: MusicWidgetSnapshot.kind)
            }
            lastState = state; lastSongID = nil; return
        }
        let player = MusicPlaybackController.shared
        guard let song = player.nowPlaying else {
            lastState = nil
            lastSongID = nil
            if let url = MusicWidgetSnapshot.storeURL { try? FileManager.default.removeItem(at: url) }
            WidgetCenter.shared.reloadTimelines(ofKind: MusicWidgetSnapshot.kind)
            return
        }
        let nextIndex = player.currentIndex + 1
        let next = player.queue.indices.contains(nextIndex) ? player.queue[nextIndex].title : nil
        let state = MusicActivityAttributes.ContentState(
            title: String((song.title ?? "Untitled Song").prefix(200)), artist: String((song.artist ?? "Unknown Artist").prefix(200)),
            nextTitle: next.map { String($0.prefix(200)) }, playlist: player.sourcePlaylistName.map { String($0.prefix(200)) }, isPlaying: player.isPlaying,
            elapsed: max(0, player.playbackTime), duration: max(0, player.duration), updatedAt: Date())
        let metadataChanged = lastSongID != song.persistentID || lastState?.isPlaying != state.isPlaying ||
            lastState?.nextTitle != state.nextTitle || lastState?.playlist != state.playlist
        let expectedElapsed = (lastState?.elapsed ?? 0) + ((lastState?.isPlaying ?? false) ? Date().timeIntervalSince(lastState?.updatedAt ?? Date()) : 0)
        let seeked = abs(state.elapsed - expectedElapsed) > 3
        if metadataChanged || seeked || lastState == nil {
            do {
                if let url = MusicWidgetSnapshot.storeURL {
                    let data = try JSONEncoder().encode(MusicWidgetSnapshot(state: state))
                    try data.write(to: url, options: [.atomic])
                }
                WidgetCenter.shared.reloadTimelines(ofKind: MusicWidgetSnapshot.kind)
            } catch { log.error("Unable to write music widget state: \(error.localizedDescription, privacy: .public)") }
            lastState = state
            lastSongID = song.persistentID
        }
    }
}
