import CarPlay
import LunaMusicCore
import LunaPodcastCore
import Combine
import MediaPlayer
import UIKit

/// CarPlay uses its own scene and system templates; it never presents the phone UI.
@MainActor
final class MusicCarPlaySceneDelegate: UIResponder, @preconcurrency CPTemplateApplicationSceneDelegate, @preconcurrency CPNowPlayingTemplateObserver {
    private weak var interfaceController: CPInterfaceController?
    private let library = MusicLibraryController.shared
    private let playback = MusicPlaybackController.shared
    private var libraryObserver: NSObjectProtocol?
    private var podcastObserver: NSObjectProtocol?
    private var rootTemplate: CPListTemplate?

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didConnect interfaceController: CPInterfaceController) {
        MediaPlaybackCoordinator.shared.install()
        CPNowPlayingTemplate.shared.add(self)
        CPNowPlayingTemplate.shared.isUpNextButtonEnabled = true
        CPNowPlayingTemplate.shared.updateNowPlayingButtons([
            CPNowPlayingImageButton(image: UIImage(systemName: "arrow.triangle.swap")!) { _ in Task { await MediaPlaybackCoordinator.shared.switchQueue() } },
            CPNowPlayingPlaybackRateButton { _ in
                if MediaPlaybackCoordinator.shared.active == .podcasts {
                    let player = PodcastPlaybackController.shared
                    player.setRate(player.rate >= 2 ? 1 : player.rate + 0.25)
                }
            }
        ])
        podcastObserver = NotificationCenter.default.addObserver(forName: .lunaPodcastsChanged, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.refreshRoot() } }
        Task { await PodcastLibraryController.shared.refresh() }
        self.interfaceController = interfaceController
        let root = makeRoot()
        rootTemplate = root
        interfaceController.setRootTemplate(root, animated: false, completion: nil)
        libraryObserver = NotificationCenter.default.addObserver(forName: .lunaMusicLibraryChanged,
                                                                  object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refreshRoot() }
        }
        Task {
            // CarPlay can start the app without a phone scene. Never raise a permission
            // sheet on the car display; browsing becomes available after phone approval.
            await library.reload()
            refreshRoot()
        }
    }

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didDisconnectInterfaceController interfaceController: CPInterfaceController) {
        if let libraryObserver { NotificationCenter.default.removeObserver(libraryObserver) }
        libraryObserver = nil
        if let podcastObserver { NotificationCenter.default.removeObserver(podcastObserver) }; podcastObserver = nil
        CPNowPlayingTemplate.shared.remove(self)
        rootTemplate = nil
        self.interfaceController = nil
    }

    private func refreshRoot() {
        rootTemplate?.updateSections(makeRoot().sections)
    }

    private func makeRoot() -> CPListTemplate {
        guard library.authorizationStatus == .authorized || !library.songs.isEmpty else {
            let row = CPListItem(text: "Allow Music Access on iPhone", detailText: "Open Luna Music to enable your library")
            row.isEnabled = false
            return CPListTemplate(title: "Library", sections: [CPListSection(items: [podcastRootRow(), row])])
        }
        let categories: [(String, String, () -> CPListTemplate)] = [
            ("Playlists", "music.note.list", { [weak self] in self?.makePlaylists() ?? CPListTemplate(title: "Playlists", sections: []) }),
            ("Albums", "square.stack", { [weak self] in self?.makeAlbums() ?? CPListTemplate(title: "Albums", sections: []) }),
            ("Artists", "person.2", { [weak self] in self?.makeArtists() ?? CPListTemplate(title: "Artists", sections: []) }),
            ("Songs", "music.note", { [weak self] in self?.makeSongs() ?? CPListTemplate(title: "Songs", sections: []) }),
            ("Downloaded", "arrow.down.circle", { [weak self] in self?.makeSongs(downloadedOnly: true) ?? CPListTemplate(title: "Downloaded", sections: []) })
        ]
        let rows = categories.map { title, symbol, destination in
            let row = CPListItem(text: title, detailText: nil, image: UIImage(systemName: symbol))
            row.handler = { [weak self] _, done in
                self?.interfaceController?.pushTemplate(destination(), animated: true, completion: nil)
                done()
            }
            return row
        }
        return CPListTemplate(title: "Library", sections: [CPListSection(items: [podcastRootRow()] + rows)])
    }

    private func makePlaylists() -> CPListTemplate {
        list(title: "Playlists", collections: library.playlists.map { ($0.name ?? "Playlist", $0.items, $0 as MusicPlaylist?) })
    }

    private func makeAlbums() -> CPListTemplate {
        list(title: "Albums", collections: library.albums.map { ($0.representativeItem?.albumTitle ?? "Album", $0.items, nil) })
    }

    private func makeArtists() -> CPListTemplate {
        list(title: "Artists", collections: library.artists.map { ($0.representativeItem?.artist ?? "Artist", $0.items, nil) })
    }

    private func list(title: String, collections: [(String, [MusicSong], MusicPlaylist?)], offset: Int = 0) -> CPListTemplate {
        let pageSize = max(1, CPListTemplate.maximumItemCount - 1)
        var rows = collections.dropFirst(offset).prefix(pageSize).map { name, songs, playlist in
            let row = CPListItem(text: name, detailText: "\(songs.count) songs")
            row.handler = { [weak self] _, done in
                self?.interfaceController?.pushTemplate(self?.makeSongList(title: name, songs: songs, playlist: playlist) ?? CPListTemplate(title: name, sections: []), animated: true, completion: nil)
                done()
            }
            return row
        }
        if offset + pageSize < collections.count {
            let more = CPListItem(text: "More \(title)", detailText: nil)
            more.handler = { [weak self] _, done in
                self?.interfaceController?.pushTemplate(self?.list(title: title, collections: collections, offset: offset + pageSize) ?? CPListTemplate(title: title, sections: []), animated: true, completion: nil)
                done()
            }
            rows.append(more)
        }
        return CPListTemplate(title: title, sections: [CPListSection(items: rows)])
    }

    private func makeSongs(downloadedOnly: Bool = false) -> CPListTemplate {
        let songs = downloadedOnly ? library.songs.filter { !$0.isCloudItem } : library.songs
        return makeSongList(title: downloadedOnly ? "Downloaded" : "Songs", songs: songs)
    }

    private func makeSongList(title: String, songs: [MusicSong], playlist: MusicPlaylist? = nil,
                              offset: Int = 0) -> CPListTemplate {
        let pageSize = max(1, CPListTemplate.maximumItemCount - 1)
        var rows = songs.dropFirst(offset).prefix(pageSize).map { song in
            let row = CPListItem(text: song.title ?? "Unknown Song", detailText: song.artist)
            row.handler = { [weak self] _, done in
                guard let self else { done(); return }
                Task {
                    defer { done() }
                    do {
                        try await self.playback.playSong(song, in: playlist)
                        self.interfaceController?.pushTemplate(CPNowPlayingTemplate.shared, animated: true, completion: nil)
                    } catch {
                        // Keep the list available if a cloud song is temporarily unplayable.
                    }
                }
            }
            return row
        }
        if offset + pageSize < songs.count {
            let more = CPListItem(text: "More Songs", detailText: nil)
            more.handler = { [weak self] _, done in
                self?.interfaceController?.pushTemplate(self?.makeSongList(title: title, songs: songs, playlist: playlist, offset: offset + pageSize) ?? CPListTemplate(title: title, sections: []), animated: true, completion: nil)
                done()
            }
            rows.append(more)
        }
        let template = CPListTemplate(title: title, sections: [CPListSection(items: rows)])
        template.emptyViewTitleVariants = ["No Songs"]
        return template
    }
    private func podcastRootRow() -> CPListItem {
        let row = CPListItem(text: "Podcasts", detailText: nil, image: UIImage(systemName: "dot.radiowaves.left.and.right"))
        row.handler = { [weak self] _, done in
            guard let self else { done(); return }
            interfaceController?.pushTemplate(podcastRoot(), animated: true, completion: nil); done()
        }; return row
    }
    private func podcastRoot() -> CPListTemplate {
        let state = PodcastLibraryController.shared.state
        var rows: [CPListItem] = []
        let resume = CPListItem(text: "Resume Last Podcast", detailText: state.lastPlayedEpisodeID.flatMap { state.episodes[$0]?.title })
        resume.handler = { [weak self] _, done in Task { @MainActor in
            defer { done() }
            do { try await PodcastPlaybackController.shared.resumeLastPodcast(); self?.interfaceController?.pushTemplate(CPNowPlayingTemplate.shared, animated: true, completion: nil) }
            catch { self?.showPodcastError(error) }
        } }; rows.append(resume)
        let latest = PodcastPolicies.ordered(state.episodes.values.filter { state.shows[$0.showID]?.followed == true && state.progress[$0.id]?.listened != true }, newestFirst: true)
        let groups: [(String, [PodcastEpisode])] = [("Latest Episodes", latest), ("Downloaded", Array(state.episodes.values.filter { PodcastDownloads.shared.localURL($0.id) != nil })), ("Saved", Array(state.episodes.values.filter { state.progress[$0.id]?.saved == true }))]
        for (title, episodes) in groups { rows.append(podcastCollectionRow(title: title, episodes: episodes)) }
        for show in state.shows.values.filter(\.followed).sorted(by: { $0.title < $1.title }) {
            rows.append(podcastCollectionRow(title: show.title, episodes: PodcastLibraryController.shared.episodes(for: show.id)))
        }
        for station in state.stations { rows.append(podcastCollectionRow(title: station.name, episodes: PodcastPolicies.stationEpisodes(station, state: state))) }
        return podcastRows(title: "Podcasts", rows: rows)
    }
    private func podcastCollectionRow(title: String, episodes: [PodcastEpisode]) -> CPListItem {
        let row = CPListItem(text: title, detailText: "\(episodes.count) episodes")
        row.handler = { [weak self] _, done in
            guard let self else { done(); return }
            interfaceController?.pushTemplate(podcastEpisodes(title: title, episodes: episodes), animated: true, completion: nil); done()
        }; return row
    }
    private func podcastEpisodes(title: String, episodes: [PodcastEpisode]) -> CPListTemplate {
        let rows = episodes.map { episode in
            let row = CPListItem(text: episode.title, detailText: PodcastLibraryController.shared.state.shows[episode.showID]?.title)
            row.handler = { [weak self] _, done in Task { @MainActor in
                defer { done() }
                do { try await PodcastPlaybackController.shared.play(episode); self?.interfaceController?.pushTemplate(CPNowPlayingTemplate.shared, animated: true, completion: nil) }
                catch { self?.showPodcastError(error) }
            } }; return row
        }
        return podcastRows(title: title, rows: rows)
    }
    private func podcastRows(title: String, rows: [CPListItem], offset: Int = 0) -> CPListTemplate {
        let pageSize = max(1, CPListTemplate.maximumItemCount - 1)
        var page = Array(rows.dropFirst(offset).prefix(pageSize))
        if rows.count > offset + pageSize {
            let more = CPListItem(text: "More", detailText: nil)
            more.handler = { [weak self] _, done in
                guard let self else { done(); return }
                interfaceController?.pushTemplate(podcastRows(title: title, rows: rows, offset: offset + pageSize), animated: true, completion: nil); done()
            }; page.append(more)
        }
        let template = CPListTemplate(title: title, sections: [CPListSection(items: page)])
        template.emptyViewTitleVariants = ["No Episodes"]; return template
    }
    func nowPlayingTemplateUpNextButtonTapped(_ nowPlayingTemplate: CPNowPlayingTemplate) {
        if MediaPlaybackCoordinator.shared.active == .podcasts {
            let state = PodcastLibraryController.shared.state
            interfaceController?.pushTemplate(podcastEpisodes(title: "Playing Next", episodes: (state.queue + state.continuation).compactMap { state.episodes[$0] }), animated: true, completion: nil)
        } else {
            interfaceController?.pushTemplate(makeSongList(title: "Playing Next", songs: Array(playback.queue.dropFirst(playback.currentIndex + 1))), animated: true, completion: nil)
        }
    }
    private func showPodcastError(_ error: Error) {
        let alert = CPAlertTemplate(titleVariants: [error.localizedDescription], actions: [CPAlertAction(title: "OK", style: .default) { [weak self] _ in self?.interfaceController?.dismissTemplate(animated: true, completion: nil) }])
        interfaceController?.presentTemplate(alert, animated: true, completion: nil)
    }

}
