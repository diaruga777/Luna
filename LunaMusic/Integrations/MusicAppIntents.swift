import LunaMusicCore
import AppIntents
import AVFAudio
import Foundation
import MediaPlayer
import CoreSpotlight

struct LibraryMusicEntity: IndexedEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Library Music"
    static var defaultQuery = LibraryMusicQuery()
    var id: String
    @Property(title: "ID") var identifier: String
    @Property(title: "Name") var name: String
    @Property(title: "Details") var detail: String
    @Property(title: "Kind") var kind: String
    @Property(title: "Saved Date") var savedDate: Date
    @Property(title: "Duration") var duration: Double
    init(id: String, name: String, detail: String, savedDate: Date = .distantPast, duration: Double = 0) {
        self.id = id
        self.identifier = id
        self.name = name
        self.detail = detail
        self.kind = String(id.prefix { $0 != ":" }); self.savedDate = savedDate; self.duration = duration
    }
    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(detail)")
    }
}

struct LibraryMusicQuery: EntityStringQuery {
    @MainActor private func library() async -> [LibraryMusicEntity] {
        // Entity suggestions never trigger a permission prompt outside the app.
        let library = MusicLibraryController.shared
        await library.reload(refreshVault: false)
        return Self.entities(in: library)
    }
    @MainActor private static func entities(in library: MusicLibraryController) -> [LibraryMusicEntity] {
        var entities: [LibraryMusicEntity] = []
        entities.reserveCapacity(library.playlists.count + library.albums.count + library.artists.count + library.songs.count)
        for playlist in library.playlists {
            entities.append(LibraryMusicEntity(id: "playlist:\(playlist.persistentID)", name: playlist.name ?? "Playlist", detail: "Playlist"))
        }
        for collection in library.albums {
            guard let item = collection.representativeItem else { continue }
            entities.append(LibraryMusicEntity(id: "album:\(item.albumPersistentID)", name: item.albumTitle ?? "Untitled Album", detail: "Album · \(item.albumArtist ?? item.artist ?? "Unknown Artist")"))
        }
        for collection in library.artists {
            guard let item = collection.representativeItem else { continue }
            entities.append(LibraryMusicEntity(id: "artist:\(item.artistPersistentID)", name: item.artist ?? "Unknown Artist", detail: "Artist"))
        }
        for song in library.songs {
            entities.append(LibraryMusicEntity(id: "song:\(song.persistentID)", name: song.title ?? "Untitled Song", detail: song.artist ?? "Unknown Artist", savedDate: song.dateAdded, duration: song.playbackDuration))
        }
        return entities
    }
    func entities(for identifiers: [String]) async throws -> [LibraryMusicEntity] {
        let entities = Dictionary(uniqueKeysWithValues: await library().map { ($0.id, $0) })
        return identifiers.compactMap { entities[$0] }
    }
    func entities(matching string: String) async throws -> [LibraryMusicEntity] {
        await library().filter { $0.name.localizedStandardContains(string) || $0.detail.localizedStandardContains(string) }
    }
    func suggestedEntities() async throws -> [LibraryMusicEntity] {
        Array(await library().prefix(20))
    }
    @MainActor func allEntities() async -> [LibraryMusicEntity] {
        Self.entities(in: MusicLibraryController.shared)
    }
}

@MainActor enum MusicEntityIndexing {
    private static let index = CSSearchableIndex(name: "LunaMusic.Library")
    private static var isRefreshing = false
    private static var needsRefresh = false

    static func refresh() async {
        let library = MusicLibraryController.shared
        guard library.hasLoaded else { return }
        guard !isRefreshing else { needsRefresh = true; return }
        isRefreshing = true
        repeat {
            needsRefresh = false
            let entities = await LibraryMusicQuery().allEntities()
            do {
                try await index.deleteAppEntities(ofType: LibraryMusicEntity.self)
                try await index.indexAppEntities(entities, priority: 10)
            } catch {
                // Siri can still resolve entities through LibraryMusicQuery if indexing is unavailable.
            }
        } while needsRefresh
        isRefreshing = false
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
    static var description = IntentDescription("Play a song, album, artist, or playlist from your library.")
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

struct ResumeMusicIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Resume Music"
    @MainActor func perform() async throws -> some IntentResult {
        let player = MusicPlaybackController.shared
        if !player.isPlaying { try await player.resume() }
        return .result()
    }
}

struct PauseMusicIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Pause If Playing"
    static var description = IntentDescription("Pause music or podcasts playing in Luna Music.")
    static var openAppWhenRun = false
    @MainActor func perform() async throws -> some IntentResult {
        MediaPlaybackCoordinator.shared.install()
        MediaPlaybackCoordinator.shared.pause()
        return .result()
    }
}

enum MusicSeekDirection: String, AppEnum {
    case forward, backward
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Direction"
    static var caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .forward: "Forward", .backward: "Backward"
    ]
}

struct SeekMusicIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Seek"
    static var description = IntentDescription("Move forward or backward in the current music or podcast.")
    static var openAppWhenRun = false
    @Parameter(title: "Direction", default: .backward) var direction: MusicSeekDirection
    @Parameter(title: "Seconds", default: 1) var seconds: Double
    static var parameterSummary: some ParameterSummary {
        Summary("Seek \(\.$direction) by \(\.$seconds) seconds")
    }
    @MainActor func perform() async throws -> some IntentResult {
        MediaPlaybackCoordinator.shared.install()
        try await MediaPlaybackCoordinator.shared.seek(by: seconds, backward: direction == .backward)
        return .result()
    }
}

extension Notification.Name {
    static let lunaPodcastOpenEpisode = Notification.Name("lunaPodcastOpenEpisode")
    static let lunaMusicOpenQueue = Notification.Name("lunaMusicOpenQueue")
    static let lunaMusicOpenSearch = Notification.Name("lunaMusicOpenSearch")
}

/// Retains cold-start intent routing until the scene has installed its observer.
@MainActor enum MusicIntentRoute {
    static var pendingPodcastEpisodeID: String?
    static var pendingURL: URL?
    static func open(_ url: URL) {
        pendingURL = url
        NotificationCenter.default.post(name: url.host == "queue" ? .lunaMusicOpenQueue : .lunaMusicOpenSearch,
                                        object: nil, userInfo: ["url": url])
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
        AppShortcut(intent: ImportPodcastAudioIntent(), phrases: ["Add audio to \(.applicationName)"], shortTitle: "Add Audio to Podcasts", systemImageName: "waveform.badge.plus")
        AppShortcut(intent: CreatePodcastAudioListIntent(), phrases: ["Create an audio list in \(.applicationName)"], shortTitle: "Create Audio List", systemImageName: "text.badge.plus")
        AppShortcut(intent: ResumeLastPodcastIntent(), phrases: ["Resume my podcast queue in \(.applicationName)"], shortTitle: "Resume Podcast Queue", systemImageName: "dot.radiowaves.left.and.right")
        AppShortcut(intent: SwitchMediaQueueIntent(), phrases: ["Switch queues in \(.applicationName)"], shortTitle: "Switch Music and Podcasts", systemImageName: "arrow.triangle.swap")
        AppShortcut(intent: PlayLibraryMusicIntent(), phrases: ["Play \(\.$music) in \(.applicationName)", "Play music in \(.applicationName)"], shortTitle: "Play Library Music", systemImageName: "music.note")
        AppShortcut(intent: SearchMusicLibraryIntent(), phrases: ["Search my library in \(.applicationName)"], shortTitle: "Search Library", systemImageName: "magnifyingglass")
        AppShortcut(intent: ResumeMusicIntent(), phrases: ["Resume \(.applicationName)"], shortTitle: "Resume Music", systemImageName: "play.fill")
        AppShortcut(intent: PauseMusicIntent(), phrases: ["Pause \(.applicationName)"], shortTitle: "Pause If Playing", systemImageName: "pause.fill")
        AppShortcut(intent: SeekMusicIntent(), phrases: ["Seek in \(.applicationName)"], shortTitle: "Seek", systemImageName: "gobackward")
        AppShortcut(intent: NextMusicTrackIntent(), phrases: ["Next song in \(.applicationName)"], shortTitle: "Next Song", systemImageName: "forward.fill")
    }
}


struct ResumeLastPodcastIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Resume Podcast Queue"
    static var description = IntentDescription("Pick up where you left off, then continue with unplayed episodes from the shows you follow.")
    static var openAppWhenRun = false
    @Parameter(title: "Override Other Audio", default: true) var overrideOtherAudio: Bool
    @Parameter(title: "Pause Immediately", default: false) var pauseImmediately: Bool
    @MainActor func perform() async throws -> some IntentResult {
        guard overrideOtherAudio || !AVAudioSession.sharedInstance().isOtherAudioPlaying else {
            return .result()
        }
        MediaPlaybackCoordinator.shared.install()
        try await PodcastPlaybackController.shared.resumeLastPodcast(pauseImmediately: pauseImmediately)
        return .result()
    }
}
struct SwitchMediaQueueIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Switch Music and Podcasts"
    static var openAppWhenRun = false
    @MainActor func perform() async throws -> some IntentResult {
        MediaPlaybackCoordinator.shared.install()
        await MediaPlaybackCoordinator.shared.switchQueue()
        return .result()
    }
}

struct FindLibraryMusicIntent: AppIntent {
    static var title: LocalizedStringResource = "Find Library Music"
    @Parameter(title: "Search", default: "") var search: String
    @Parameter(title: "Kind") var kind: String?
    @Parameter(title: "Item ID") var itemID: String?
    @Parameter(title: "Limit", default: 50, inclusiveRange: (1, 500)) var limit: Int
    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<[LibraryMusicEntity]> {
        await MusicLibraryController.shared.reload(refreshVault: false)
        let entities = await LibraryMusicQuery().allEntities().filter {
            (search.isEmpty || $0.name.localizedStandardContains(search) || $0.detail.localizedStandardContains(search))
                && (kind == nil || kind?.isEmpty == true || $0.kind == kind)
                && (itemID == nil || itemID?.isEmpty == true || $0.id == itemID)
        }
        return .result(value: Array(entities.prefix(max(1, min(500, limit)))))
    }
}
enum MusicPlaylistSource: String, AppEnum {
    case musicLibrary, vault
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Music Source"
    static var caseDisplayRepresentations: [Self: DisplayRepresentation] = [.musicLibrary: "Music Library", .vault: "Vault"]
}
struct CreateMusicPlaylistIntent: AppIntent {
    static var title: LocalizedStringResource = "Create Music Playlist"
    @Parameter(title: "Name") var name: String
    @Parameter(title: "Songs") var songs: [LibraryMusicEntity]?
    @Parameter(title: "Source for Empty Playlist", default: .musicLibrary) var source: MusicPlaylistSource
    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<LibraryMusicEntity> {
        let library = MusicLibraryController.shared
        await library.reload(refreshVault: false)
        let resolved = try (songs ?? []).map { entity -> MusicSong in
            guard let song = library.songs.first(where: { "song:\($0.persistentID)" == entity.id }) else { throw MusicIntentError.missing }; return song
        }
        let playlist = try await library.createPlaylist(name: name, items: resolved, source: source == .vault ? .vault : .apple)
        return .result(value: LibraryMusicEntity(id: "playlist:\(playlist.persistentID)", name: playlist.name ?? name, detail: "Playlist"))
    }
}
struct AddSongsToMusicPlaylistIntent: AppIntent {
    static var title: LocalizedStringResource = "Add Songs to Playlist"
    @Parameter(title: "Songs") var songs: [LibraryMusicEntity]
    @Parameter(title: "Playlist") var playlist: LibraryMusicEntity
    @MainActor func perform() async throws -> some IntentResult {
        let library = MusicLibraryController.shared
        await library.reload(refreshVault: false)
        guard let destination = library.playlists.first(where: { "playlist:\($0.persistentID)" == playlist.id }) else { throw MusicIntentError.missing }
        let resolved = try songs.map { entity -> MusicSong in
            guard let song = library.songs.first(where: { "song:\($0.persistentID)" == entity.id }) else { throw MusicIntentError.missing }; return song
        }
        try await library.add(resolved, to: destination)
        return .result()
    }
}
struct QueueLibraryMusicIntent: AppIntent {
    static var title: LocalizedStringResource = "Add Songs to Music Queue"
    @Parameter(title: "Songs") var songs: [LibraryMusicEntity]
    @Parameter(title: "Play Next", default: false) var next: Bool
    @MainActor func perform() async throws -> some IntentResult {
        let library = MusicLibraryController.shared
        await library.reload(refreshVault: false)
        let resolved = try songs.map { entity -> MusicSong in
            guard let song = library.songs.first(where: { "song:\($0.persistentID)" == entity.id }) else { throw MusicIntentError.missing }; return song
        }
        for song in next ? Array(resolved.reversed()) : resolved {
            if next { MusicPlaybackController.shared.playNext(song) } else { MusicPlaybackController.shared.playLater(song) }
        }
        return .result()
    }
}
