import LunaMusicCore
import AppIntents
import Foundation
import MediaPlayer

struct LibraryMusicEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Library Music"
    static var defaultQuery = LibraryMusicQuery()
    var id: String
    var name: String
    var detail: String
    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(detail)")
    }
}

struct LibraryMusicQuery: EntityStringQuery {
    @MainActor private func library() async -> [LibraryMusicEntity] {
        // Entity suggestions never trigger a permission prompt outside the app.
        let library = MusicLibraryController.shared
        await library.reload()
        return library.playlists.map {
            LibraryMusicEntity(id: "playlist:\($0.persistentID)", name: $0.name ?? "Playlist", detail: "Playlist")
        } + library.albums.compactMap { collection in
            guard let item = collection.representativeItem else { return nil }
            return LibraryMusicEntity(id: "album:\(item.albumPersistentID)", name: item.albumTitle ?? "Untitled Album", detail: "Album · \(item.albumArtist ?? item.artist ?? "Unknown Artist")")
        } + library.artists.compactMap { collection in
            guard let item = collection.representativeItem else { return nil }
            return LibraryMusicEntity(id: "artist:\(item.artistPersistentID)", name: item.artist ?? "Unknown Artist", detail: "Artist")
        } + library.songs.map {
            LibraryMusicEntity(id: "song:\($0.persistentID)", name: $0.title ?? "Untitled Song", detail: $0.artist ?? "Unknown Artist")
        }
    }
    func entities(for identifiers: [String]) async throws -> [LibraryMusicEntity] {
        let requested = Set(identifiers)
        return await library().filter { requested.contains($0.id) }
    }
    func entities(matching string: String) async throws -> [LibraryMusicEntity] {
        await library().filter { $0.name.localizedStandardContains(string) || $0.detail.localizedStandardContains(string) }
    }
    func suggestedEntities() async throws -> [LibraryMusicEntity] {
        Array(await library().prefix(20))
    }
}

private enum MusicIntentError: LocalizedError {
    case permission, missing
    var errorDescription: String? {
        switch self {
        case .permission: return "Allow access to your music library in Luna Music first."
        case .missing: return "This item is no longer in your music library."
        }
    }
}

struct PlayLibraryMusicIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Play Library Music"
    static var description = IntentDescription("Play a song with its shuffled playlist continuation, an album, artist, or playlist from your library.")
    static var openAppWhenRun = true
    @Parameter(title: "Music") var music: LibraryMusicEntity
    static var parameterSummary: some ParameterSummary { Summary("Play \(\.$music)") }

    @MainActor func perform() async throws -> some IntentResult {
        let library = MusicLibraryController.shared
        await library.authorizeAndLoad()
        if music.id.hasPrefix("playlist:"), let item = library.playlists.first(where: { "playlist:\($0.persistentID)" == music.id }) {
            try await MusicPlaybackController.shared.play(item.items, playlist: item, shuffle: true)
        } else if music.id.hasPrefix("album:"), let album = library.albums.first(where: { "album:\($0.representativeItem?.albumPersistentID ?? 0)" == music.id }) {
            try await MusicPlaybackController.shared.play(album.items)
        } else if music.id.hasPrefix("artist:"), let artist = library.artists.first(where: { "artist:\($0.representativeItem?.artistPersistentID ?? 0)" == music.id }) {
            try await MusicPlaybackController.shared.play(artist.items, shuffle: true)
        } else if let item = library.songs.first(where: { "song:\($0.persistentID)" == music.id }) {
            try await MusicPlaybackController.shared.playSong(item)
        } else { throw MusicIntentError.missing }
        return .result()
    }
}

struct PauseMusicIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Pause Music"
    @MainActor func perform() async throws -> some IntentResult {
        let player = MusicPlaybackController.shared
        if player.isPlaying { player.togglePlayPause() }
        return .result()
    }
}

struct ResumeMusicIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Resume Music"
    @MainActor func perform() async throws -> some IntentResult {
        let player = MusicPlaybackController.shared
        if !player.isPlaying { try await player.resume() }
        return .result()
    }
}

extension Notification.Name {
    static let lunaMusicOpenQueue = Notification.Name("lunaMusicOpenQueue")
    static let lunaMusicOpenSearch = Notification.Name("lunaMusicOpenSearch")
}

/// Retains cold-start intent routing until the scene has installed its observer.
@MainActor enum MusicIntentRoute {
    static var pendingURL: URL?
    static func open(_ url: URL) {
        pendingURL = url
        NotificationCenter.default.post(name: url.host == "queue" ? .lunaMusicOpenQueue : .lunaMusicOpenSearch,
                                        object: nil, userInfo: ["url": url])
    }
}

struct OpenMusicQueueIntent: AppIntent {
    static var title: LocalizedStringResource = "Open Playback Queue"
    static var openAppWhenRun = true
    @MainActor func perform() async throws -> some IntentResult {
        MusicIntentRoute.open(URL(string: "lunamusic://queue")!)
        return .result()
    }
}

struct SearchMusicLibraryIntent: AppIntent {
    static var title: LocalizedStringResource = "Search Music Library"
    static var openAppWhenRun = true
    @Parameter(title: "Search", default: "") var query: String
    @MainActor func perform() async throws -> some IntentResult {
        var components = URLComponents(string: "lunamusic://search")!
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        MusicIntentRoute.open(components.url!)
        return .result()
    }
}

struct LunaMusicShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: PlayLibraryMusicIntent(), phrases: ["Play \(\.$music) in \(.applicationName)", "Play music in \(.applicationName)"], shortTitle: "Play Library Music", systemImageName: "music.note")
        AppShortcut(intent: SearchMusicLibraryIntent(), phrases: ["Search my library in \(.applicationName)"], shortTitle: "Search Library", systemImageName: "magnifyingglass")
        AppShortcut(intent: OpenMusicQueueIntent(), phrases: ["Open my queue in \(.applicationName)"], shortTitle: "Playback Queue", systemImageName: "list.bullet")
        AppShortcut(intent: PauseMusicIntent(), phrases: ["Pause \(.applicationName)"], shortTitle: "Pause Music", systemImageName: "pause.fill")
        AppShortcut(intent: ResumeMusicIntent(), phrases: ["Resume \(.applicationName)"], shortTitle: "Resume Music", systemImageName: "play.fill")
        AppShortcut(intent: NextMusicTrackIntent(), phrases: ["Next song in \(.applicationName)"], shortTitle: "Next Song", systemImageName: "forward.fill")
    }
}
