import LunaMusicCore
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
    private var lastSongID: MPMediaEntityPersistentID?
    private var activity: Activity<MusicActivityAttributes>?
    private let log = Logger(subsystem: "LunaMusic", category: "SystemIntegration")

    func start() {
        guard observers.isEmpty else { return }
        for name in [Notification.Name.lunaMusicPlaybackChanged, UIApplication.didBecomeActiveNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.scheduleRefresh() }
            })
        }
        LunaMusicShortcuts.updateAppShortcutParameters()
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
        let player = MusicPlaybackController.shared
        guard let song = player.nowPlaying else {
            for existing in Activity<MusicActivityAttributes>.activities {
                await existing.end(nil, dismissalPolicy: .immediate)
            }
            activity = nil
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
        let content = ActivityContent(state: state, staleDate: Date().addingTimeInterval(state.isPlaying ? max(30, state.duration - state.elapsed + 15) : 300))

        if activity == nil {
            // A terminated app's old activity may refer to an obsolete queue.
            for existing in Activity<MusicActivityAttributes>.activities {
                await existing.end(nil, dismissalPolicy: .immediate)
            }
            if state.isPlaying, UIApplication.shared.applicationState == .active,
               ActivityAuthorizationInfo().areActivitiesEnabled {
                do { activity = try Activity.request(attributes: MusicActivityAttributes(sessionID: UUID()), content: content) }
                catch { log.error("Unable to start queue activity: \(error.localizedDescription, privacy: .public)") }
            }
        } else if metadataChanged || seeked {
            await activity?.update(content)
        }
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
