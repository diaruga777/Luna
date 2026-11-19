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
    @Property(title: "Duration (Seconds)") var duration: Double
    var artistName: String?
    var albumName: String?
    init(id: String, name: String, detail: String, artist: String? = nil, album: String? = nil, savedDate: Date = .distantPast, duration: Double = 0) {
        self.id = id
        self.identifier = id
        self.name = name
        self.artistName = artist
        self.albumName = album
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
    @MainActor static func entities(in library: MusicLibraryController) -> [LibraryMusicEntity] {
        var entities: [LibraryMusicEntity] = []
        entities.reserveCapacity(library.playlists.count + library.albums.count + library.artists.count + library.songs.count)
        for playlist in library.playlists {
            entities.append(LibraryMusicEntity(id: "playlist:\(playlist.persistentID)", name: playlist.name ?? "Playlist", detail: "Playlist"))
        }
        for collection in library.albums {
            guard let item = collection.representativeItem else { continue }
            entities.append(LibraryMusicEntity(id: "album:\(item.albumPersistentID)", name: item.albumTitle ?? "Untitled Album", detail: "Album · \(item.albumArtist ?? item.artist ?? "Unknown Artist")", artist: item.albumArtist ?? item.artist, album: item.albumTitle))
        }
        for collection in library.artists {
            guard let item = collection.representativeItem else { continue }
            entities.append(LibraryMusicEntity(id: "artist:\(item.artistPersistentID)", name: item.artist ?? "Unknown Artist", detail: "Artist", artist: item.artist))
        }
        for song in library.songs {
            entities.append(LibraryMusicEntity(id: "song:\(song.persistentID)", name: song.title ?? "Untitled Song", detail: song.artist ?? "Unknown Artist", artist: song.artist, album: song.albumTitle, savedDate: song.dateAdded, duration: song.playbackDuration))
        }
        return entities
    }
    func entities(for identifiers: [String]) async throws -> [LibraryMusicEntity] {
        let entities = Dictionary(uniqueKeysWithValues: await library().map { ($0.id, $0) })
        return identifiers.compactMap { entities[$0] }
    }
    func entities(matching string: String) async throws -> [LibraryMusicEntity] {
        let items = await library()
        let exact = items.filter { $0.name.localizedStandardCompare(string) == .orderedSame }
        if !exact.isEmpty { return exact }
        return items.filter { $0.name.localizedStandardContains(string) || $0.detail.localizedStandardContains(string) }
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

@MainActor enum LibraryMusicPlayback {
    static func library() async -> MusicLibraryController {
        let library = MusicLibraryController.shared
        if !library.hasLoaded || library.isLoading {
            await library.reload(refreshVault: false)
        }
        return library
    }

    static func play(id: String, in library: MusicLibraryController, shuffle: Bool? = nil) async throws {
        if id.hasPrefix("playlist:"), let item = library.playlists.first(where: { "playlist:\($0.persistentID)" == id }) {
            try await MusicPlaybackController.shared.play(item.items, playlist: item, shuffle: shuffle ?? true)
        } else if id.hasPrefix("album:"), let album = library.albums.first(where: { "album:\($0.representativeItem?.albumPersistentID ?? 0)" == id }) {
            try await MusicPlaybackController.shared.play(album.items, shuffle: shuffle ?? false)
        } else if id.hasPrefix("artist:"), let artist = library.artists.first(where: { "artist:\($0.representativeItem?.artistPersistentID ?? 0)" == id }) {
            try await MusicPlaybackController.shared.play(artist.items, shuffle: shuffle ?? true)
        } else if let item = library.songs.first(where: { "song:\($0.persistentID)" == id }) {
            try await MusicPlaybackController.shared.playSong(item)
        } else if id.contains(":apple:"), library.authorizationStatus != .authorized {
            throw MusicIntentError.permission
        } else { throw MusicIntentError.missing }
    }
}

struct PlayLibraryMusicIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Play Library Music"
    static var description = IntentDescription("Play a song, album, artist, or playlist from your library.")
    static var openAppWhenRun = false
    @Parameter(title: "Music") var music: LibraryMusicEntity
    static var parameterSummary: some ParameterSummary { Summary("Play \(\.$music)") }

    @MainActor func perform() async throws -> some IntentResult {
        let library = await LibraryMusicPlayback.library()
        try await LibraryMusicPlayback.play(id: music.id, in: library)
        return .result()
    }
}

struct ResumeMusicIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Resume Music"
    static var description = IntentDescription("Resume the music queue in Luna Music.")
    @MainActor func perform() async throws -> some IntentResult {
        let player = MusicPlaybackController.shared
        if !player.isPlaying { try await player.resume() }
        return .result()
    }
}

struct PauseMusicIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Pause Playback"
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
    static var title: LocalizedStringResource = "Skip Forward or Backward"
    static var description = IntentDescription("Move forward or backward in the current music or podcast.")
    static var openAppWhenRun = false
    @Parameter(title: "Direction", default: .backward) var direction: MusicSeekDirection
    @Parameter(title: "Seconds", description: "How far to move within the current track or episode. Enter a positive number of seconds.", default: 1, inclusiveRange: (0, 86400)) var seconds: Double
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
    static var description = IntentDescription("Open Luna Music’s library search with the words you enter.")
    static var openAppWhenRun = true
    @Parameter(title: "Search", default: "") var query: String
    static var parameterSummary: some ParameterSummary {
        Summary("Search Music Library") {
            \.$query
        }
    }
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
        AppShortcut(intent: PauseMusicIntent(), phrases: ["Pause \(.applicationName)"], shortTitle: "Pause Playback", systemImageName: "pause.fill")
        AppShortcut(intent: SeekMusicIntent(), phrases: ["Seek in \(.applicationName)"], shortTitle: "Skip Forward or Back", systemImageName: "gobackward")
        AppShortcut(intent: NextMusicTrackIntent(), phrases: ["Next song in \(.applicationName)"], shortTitle: "Next Song", systemImageName: "forward.fill")
    }
}


struct ResumeLastPodcastIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Resume Podcast Queue"
    static var description = IntentDescription("Pick up where you left off, then continue with unplayed episodes from the shows you follow.")
    static var openAppWhenRun = false
    @Parameter(title: "Replace Other Audio", description: "Start the podcast queue even if another app is playing audio.", default: true) var overrideOtherAudio: Bool
    @Parameter(title: "Start Paused", description: "Prepare the podcast queue without starting playback.", default: false) var pauseImmediately: Bool
    static var parameterSummary: some ParameterSummary {
        Summary("Resume Podcast Queue") {
            \.$overrideOtherAudio
            \.$pauseImmediately
        }
    }
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
    static var description = IntentDescription("Switch playback between your music queue and podcast queue.")
    static var openAppWhenRun = false
    @MainActor func perform() async throws -> some IntentResult {
        MediaPlaybackCoordinator.shared.install()
        await MediaPlaybackCoordinator.shared.switchQueue()
        return .result()
    }
}

enum LibraryMusicKind: String, AppEnum {
    case song, album, artist, playlist
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Music Type"
    static var caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .song: "Songs", .album: "Albums", .artist: "Artists", .playlist: "Playlists"
    ]
}

struct FindLibraryMusicIntent: AppIntent {
    static var title: LocalizedStringResource = "Find Library Music"
    static var description = IntentDescription("Find songs, albums, artists and playlists already in your library. Searches names and artist or album details. Allow library access in Luna Music first.")
    @Parameter(title: "Search", default: "") var search: String
    @Parameter(title: "Music Type", description: "Choose songs, albums, artists or playlists. Leave blank for all types.") var kind: LibraryMusicKind?
    @Parameter(title: "Item ID", description: "The exact ID property from an item or data change. Leave blank to search instead.") var itemID: String?
    @Parameter(title: "Maximum Results", description: "The most items to return, from 1 to 500.", default: 50, inclusiveRange: (1, 500)) var limit: Int
    static var parameterSummary: some ParameterSummary {
        Summary("Find Library Music") {
            \.$search
            \.$kind
            \.$itemID
            \.$limit
        }
    }
    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<[LibraryMusicEntity]> {
        await MusicLibraryController.shared.reload(refreshVault: false)
        let entities = await LibraryMusicQuery().allEntities().filter {
            (search.isEmpty || $0.name.localizedStandardContains(search) || $0.detail.localizedStandardContains(search))
                && (kind == nil || $0.kind == kind?.rawValue)
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
    static var description = IntentDescription("Create a playlist and optionally fill it with songs from Find Library Music. Songs must come from the same source. Music Source is used only when no songs are supplied.")
    @Parameter(title: "Name") var name: String
    @Parameter(title: "Songs") var songs: [LibraryMusicEntity]?
    @Parameter(title: "Music Source", description: "Where to create the playlist when Songs is empty. Otherwise the songs determine its source.", default: .musicLibrary) var source: MusicPlaylistSource
    static var parameterSummary: some ParameterSummary {
        Summary("Create Music Playlist") {
            \.$name
            \.$songs
            \.$source
        }
    }
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
    static var description = IntentDescription("Add songs from Find Library Music to an existing playlist. Select Playlists as the destination’s Music Type and Songs for the tracks.")
    @Parameter(title: "Songs") var songs: [LibraryMusicEntity]
    @Parameter(title: "Playlist") var playlist: LibraryMusicEntity
    static var parameterSummary: some ParameterSummary {
        Summary("Add Songs to Playlist") {
            \.$songs
            \.$playlist
        }
    }
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
    static var description = IntentDescription("Add songs to the music queue in the order supplied. Turn on Play Next to put them before the remaining queue.")
    @Parameter(title: "Songs") var songs: [LibraryMusicEntity]
    @Parameter(title: "Play Next", default: false) var next: Bool
    static var parameterSummary: some ParameterSummary {
        Summary("Add Songs to Music Queue") {
            \.$songs
            \.$next
        }
    }
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
