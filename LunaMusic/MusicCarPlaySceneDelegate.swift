import CarPlay
import LunaMusicCore
import MediaPlayer
import UIKit

/// CarPlay uses its own scene and system templates; it never presents the phone UI.
@MainActor
final class MusicCarPlaySceneDelegate: UIResponder, @preconcurrency CPTemplateApplicationSceneDelegate {
    private weak var interfaceController: CPInterfaceController?
    private let library = MusicLibraryController.shared
    private let playback = MusicPlaybackController.shared
    private var libraryObserver: NSObjectProtocol?
    private var rootTemplate: CPListTemplate?

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didConnect interfaceController: CPInterfaceController) {
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
            return CPListTemplate(title: "Library", sections: [CPListSection(items: [row])])
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
        return CPListTemplate(title: "Library", sections: [CPListSection(items: rows)])
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
}
