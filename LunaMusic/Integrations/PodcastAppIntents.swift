import AppIntents
import CoreSpotlight
import Foundation
import LunaMusicCore
import LunaPodcastCore

struct PodcastEpisodeEntity: IndexedEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Podcast Episode"
    static var defaultQuery = PodcastEpisodeQuery()
    var id: String
    @Property(title: "ID") var identifier: String
    @Property(title: "Title") var title: String
    @Property(title: "Show ID") var showID: String
    @Property(title: "Published Date") var publishedDate: Date
    @Property(title: "Duration") var duration: Double
    @Property(title: "Listened") var listened: Bool
    @Property(title: "Audio URL") var audioURL: URL
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(title)") }
    @MainActor init(_ episode: PodcastEpisode) {
        id = episode.id; identifier = id; title = episode.title; showID = episode.showID; publishedDate = episode.publishedAt
        duration = episode.duration; listened = PodcastLibraryController.shared.state.progress[id]?.listened ?? false; audioURL = episode.mediaURL
    }
}
struct PodcastEpisodeQuery: EntityStringQuery {
    @MainActor func entities(for identifiers: [String]) async throws -> [PodcastEpisodeEntity] {
        let state = try PodcastLibraryController.shared.requireStore().state
        return identifiers.compactMap { state.episodes[$0] }.map(PodcastEpisodeEntity.init)
    }
    @MainActor func entities(matching string: String) async throws -> [PodcastEpisodeEntity] {
        try all().filter { $0.title.localizedStandardContains(string) }
    }
    @MainActor func suggestedEntities() async throws -> [PodcastEpisodeEntity] { Array(try all().prefix(30)) }
    @MainActor func all() throws -> [PodcastEpisodeEntity] {
        try PodcastLibraryController.shared.requireStore().state.episodes.values.sorted { $0.publishedAt == $1.publishedAt ? $0.id < $1.id : $0.publishedAt > $1.publishedAt }.map(PodcastEpisodeEntity.init)
    }
}
struct PodcastShowEntity: IndexedEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Podcast Show or Audio List"
    static var defaultQuery = PodcastShowQuery()
    var id: String
    @Property(title: "ID") var identifier: String
    @Property(title: "Title") var title: String
    @Property(title: "Feed URL") var feedURL: URL
    @Property(title: "Followed") var followed: Bool
    @Property(title: "Local Audio List") var localAudioList: Bool
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(title)") }
    init(_ show: PodcastShow) {
        id = show.id; identifier = id; title = show.title; feedURL = show.feedURL; followed = show.followed
        localAudioList = show.feedURL.scheme == "lunamusic" && show.feedURL.host == "audio-list"
    }
}
struct PodcastShowQuery: EntityStringQuery {
    @MainActor func all() throws -> [PodcastShowEntity] { try PodcastLibraryController.shared.requireStore().state.shows.values.sorted { $0.id < $1.id }.map(PodcastShowEntity.init) }
    @MainActor func entities(for identifiers: [String]) async throws -> [PodcastShowEntity] { let all = try all(); return identifiers.compactMap { id in all.first { $0.id == id } } }
    @MainActor func entities(matching string: String) async throws -> [PodcastShowEntity] { try all().filter { $0.title.localizedStandardContains(string) } }
    @MainActor func suggestedEntities() async throws -> [PodcastShowEntity] { try all() }
}
struct PodcastAudioListOptions: DynamicOptionsProvider {
    @MainActor func results() async throws -> [PodcastShowEntity] { try PodcastShowQuery().all().filter(\.localAudioList) }
}
struct PodcastStationEntity: IndexedEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Podcast Station"
    static var defaultQuery = PodcastStationQuery()
    var id: String
    @Property(title: "ID") var identifier: String
    @Property(title: "Name") var name: String
    @Property(title: "Show IDs") var showIDs: [String]
    @Property(title: "Updated Date") var updatedDate: Date
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
    init(_ station: PodcastStation) { id = station.id; identifier = id; name = station.name; showIDs = station.showIDs; updatedDate = station.updatedAt }
}
struct PodcastStationQuery: EntityStringQuery {
    @MainActor func all() throws -> [PodcastStationEntity] { try PodcastLibraryController.shared.requireStore().state.stations.map(PodcastStationEntity.init) }
    @MainActor func entities(for identifiers: [String]) async throws -> [PodcastStationEntity] { let all = try all(); return identifiers.compactMap { id in all.first { $0.id == id } } }
    @MainActor func entities(matching string: String) async throws -> [PodcastStationEntity] { try all().filter { $0.name.localizedStandardContains(string) } }
    @MainActor func suggestedEntities() async throws -> [PodcastStationEntity] { try all() }
}
struct CreatePodcastAudioListIntent: AppIntent {
    static var title: LocalizedStringResource = "Create Audio List"
    @Parameter(title: "Name") var name: String
    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<PodcastShowEntity> {
        .result(value: PodcastShowEntity(try PodcastAutomation.createAudioList(name: name)))
    }
}
struct ImportPodcastAudioIntent: AppIntent {
    static var title: LocalizedStringResource = "Add Audio to Podcasts"
    static var description = IntentDescription("Copy an audio file into a local podcast list and optionally add it to the queue. Reuse an Import Key to avoid duplicates when retrying a shortcut.")
    @Parameter(title: "Audio File") var file: IntentFile
    @Parameter(title: "Title", default: "") var title: String
    @Parameter(title: "Audio List", optionsProvider: PodcastAudioListOptions()) var list: PodcastShowEntity?
    @Parameter(title: "Add to Queue", default: true) var enqueue: Bool
    @Parameter(title: "Play Next", default: false) var next: Bool
    @Parameter(title: "Import Key") var importKey: String?
    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<PodcastEpisodeEntity> {
        let source: URL
        var temporary: URL?
        if let url = file.fileURL { source = url }
        else {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent((file.filename as NSString).lastPathComponent)
            try file.data.write(to: url); source = url; temporary = directory
        }
        defer { if let temporary { try? FileManager.default.removeItem(at: temporary) } }
        let episode = try await PodcastAutomation.importAudio(at: source, title: title, listID: list?.id, enqueue: enqueue, next: next, importKey: importKey)
        return .result(value: PodcastEpisodeEntity(episode))
    }
}
struct FindPodcastEpisodesIntent: AppIntent {
    static var title: LocalizedStringResource = "Find Podcast Episodes"
    @Parameter(title: "Search") var search: String?
    @Parameter(title: "Episode ID") var episodeID: String?
    @Parameter(title: "Show or Audio List") var show: PodcastShowEntity?
    @Parameter(title: "Published After") var after: Date?
    @Parameter(title: "Unplayed Only", default: false) var unplayed: Bool
    @Parameter(title: "Limit", default: 20, inclusiveRange: (1, 500)) var limit: Int
    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<[PodcastEpisodeEntity]> {
        let episodes = try PodcastEpisodeQuery().all().filter {
            (episodeID == nil || $0.id == episodeID) && (show == nil || $0.showID == show?.id)
                && (after == nil || $0.publishedDate > after!) && (!unplayed || !$0.listened)
                && (search == nil || search?.isEmpty == true || $0.title.localizedStandardContains(search!))
        }
        return .result(value: Array(episodes.prefix(max(1, min(limit, 500)))))
    }
}
struct GetPodcastQueueIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Podcast Queue"
    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<[PodcastEpisodeEntity]> {
        let state = try PodcastLibraryController.shared.requireStore().state
        return .result(value: state.queue.compactMap { state.episodes[$0] }.map(PodcastEpisodeEntity.init))
    }
}
enum PodcastEpisodeAction: String, AppEnum {
    case enqueue, playNext, removeFromQueue, markListened, markUnplayed, download, removeDownload
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Episode Action"
    static var caseDisplayRepresentations: [Self: DisplayRepresentation] = [.enqueue: "Add to Queue", .playNext: "Play Next", .removeFromQueue: "Remove from Queue", .markListened: "Mark Listened", .markUnplayed: "Mark Unplayed", .download: "Download", .removeDownload: "Remove Download"]
}
struct UpdatePodcastEpisodesIntent: AppIntent {
    static var title: LocalizedStringResource = "Update Podcast Episodes"
    @Parameter(title: "Episodes") var episodes: [PodcastEpisodeEntity]
    @Parameter(title: "Action") var action: PodcastEpisodeAction
    @MainActor func perform() async throws -> some IntentResult {
        let library = PodcastLibraryController.shared, store = try library.requireStore()
        let resolved = try episodes.map { entity -> PodcastEpisode in
            guard let episode = store.state.episodes[entity.id] else { throw PodcastError("This episode is no longer available.") }; return episode
        }
        for episode in action == .playNext ? resolved.reversed() : resolved {
            switch action {
            case .enqueue, .playNext: try store.enqueue(episode.id, next: action == .playNext)
            case .markListened, .markUnplayed: try store.markListened(episode.id, action == .markListened)
            case .removeFromQueue: try library.edit { $0.queue.removeAll { $0 == episode.id } }
            case .download: await PodcastDownloads.shared.download(episode)
            case .removeDownload: PodcastDownloads.shared.remove(episode.id)
            }
        }
        library.reloadState(); return .result()
    }
}
struct FollowPodcastIntent: AppIntent {
    static var title: LocalizedStringResource = "Follow Podcast Feed"
    @Parameter(title: "Feed URL") var feedURL: URL
    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<PodcastShowEntity> {
        let library = PodcastLibraryController.shared
        let id = try await library.addFeed(feedURL)
        guard let show = library.state.shows[id] else { throw PodcastError("The podcast could not be saved.") }
        return .result(value: PodcastShowEntity(show))
    }
}
struct SetPodcastFollowedIntent: AppIntent {
    static var title: LocalizedStringResource = "Set Podcast Followed"
    @Parameter(title: "Show") var show: PodcastShowEntity
    @Parameter(title: "Followed", default: true) var followed: Bool
    @MainActor func perform() async throws -> some IntentResult {
        guard try PodcastLibraryController.shared.requireStore().state.shows[show.id] != nil else { throw PodcastError("This show is no longer available.") }
        try PodcastLibraryController.shared.setFollowed(show.id, followed); return .result()
    }
}

struct SavePodcastStationIntent: AppIntent {
    static var title: LocalizedStringResource = "Save Podcast Station"
    @Parameter(title: "Existing Station") var existing: PodcastStationEntity?
    @Parameter(title: "Name") var name: String
    @Parameter(title: "Shows") var shows: [PodcastShowEntity]?
    @Parameter(title: "All Shows", default: false) var allShows: Bool
    @Parameter(title: "Unplayed Only", default: true) var unplayedOnly: Bool
    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<PodcastStationEntity> {
        let library = PodcastLibraryController.shared
        var station: PodcastStation
        if let existing {
            guard let value = library.state.stations.first(where: { $0.id == existing.id }) else { throw PodcastError("This station is no longer available.") }; station = value
        } else { station = PodcastStation(name: name) }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw PodcastError("Give the station a name.") }
        let ids = shows?.map(\.id) ?? []
        guard ids.allSatisfy({ library.state.shows[$0] != nil }) else { throw PodcastError("A selected show is no longer available.") }
        station.name = name; station.showIDs = ids; station.allShows = allShows; station.unplayedOnly = unplayedOnly; station.updatedAt = Date()
        try library.edit { state in
            if let index = state.stations.firstIndex(where: { $0.id == station.id }) { state.stations[index] = station }
            else { state.stations.append(station) }
        }
        return .result(value: PodcastStationEntity(station))
    }
}
struct DeletePodcastStationIntent: AppIntent {
    static var title: LocalizedStringResource = "Delete Podcast Station"
    @Parameter(title: "Station") var station: PodcastStationEntity
    @MainActor func perform() async throws -> some IntentResult {
        try await requestConfirmation(result: .result(dialog: "Delete this podcast station?"))
        try PodcastLibraryController.shared.edit { state in
            state.stations.removeAll { $0.id == station.id }; state.deletedStations[station.id] = Date()
        }
        return .result()
    }
}

struct GetPodcastAudioFileIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Podcast Audio File"
    @Parameter(title: "Episode") var episode: PodcastEpisodeEntity
    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        guard let saved = try PodcastLibraryController.shared.requireStore().state.episodes[episode.id] else { throw PodcastError("This episode is no longer available.") }
        guard let url = saved.mediaURL.isFileURL ? saved.mediaURL : PodcastDownloads.shared.localURL(saved.id),
              FileManager.default.fileExists(atPath: url.path) else { throw PodcastError("Download this episode in Luna Music first.") }
        return .result(value: IntentFile(fileURL: url))
    }
}


struct FindPodcastShowsIntent: AppIntent {
    static var title: LocalizedStringResource = "Find Podcast Shows and Audio Lists"
    @Parameter(title: "Search", default: "") var search: String
    @Parameter(title: "Item ID") var itemID: String?
    @Parameter(title: "Followed Only", default: false) var followedOnly: Bool
    @Parameter(title: "Local Audio Lists Only", default: false) var localOnly: Bool
    @Parameter(title: "Limit", default: 50, inclusiveRange: (1, 500)) var limit: Int
    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<[PodcastShowEntity]> {
        let shows = try PodcastShowQuery().all().filter {
            (search.isEmpty || $0.title.localizedStandardContains(search))
                && (itemID == nil || itemID?.isEmpty == true || $0.id == itemID)
                && (!followedOnly || $0.followed) && (!localOnly || $0.localAudioList)
        }
        return .result(value: Array(shows.prefix(max(1, min(500, limit)))))
    }
}

struct FindPodcastStationsIntent: AppIntent {
    static var title: LocalizedStringResource = "Find Podcast Stations"
    @Parameter(title: "Search", default: "") var search: String
    @Parameter(title: "Item ID") var itemID: String?
    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<[PodcastStationEntity]> {
        .result(value: try PodcastStationQuery().all().filter {
            (search.isEmpty || $0.name.localizedStandardContains(search))
                && (itemID == nil || itemID?.isEmpty == true || $0.id == itemID)
        })
    }
}

struct PlayPodcastEpisodeIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Play Podcast Episode"
    @Parameter(title: "Episode") var episode: PodcastEpisodeEntity
    @MainActor func perform() async throws -> some IntentResult {
        guard let current = try PodcastLibraryController.shared.requireStore().state.episodes[episode.id] else {
            throw PodcastError("This episode is no longer available.")
        }
        MediaPlaybackCoordinator.shared.install()
        try await PodcastPlaybackController.shared.play(current)
        return .result()
    }
}

struct PlayPodcastStationIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Play Podcast Station"
    @Parameter(title: "Station") var station: PodcastStationEntity
    @MainActor func perform() async throws -> some IntentResult {
        let state = try PodcastLibraryController.shared.requireStore().state
        guard let current = state.stations.first(where: { $0.id == station.id }) else {
            throw PodcastError("This station is no longer available.")
        }
        let episodes = PodcastPolicies.stationEpisodes(current, state: state)
        guard !episodes.isEmpty else { throw PodcastError("This station has no episodes to play.") }
        MediaPlaybackCoordinator.shared.install()
        try await PodcastPlaybackController.shared.playEpisodes(episodes)
        return .result()
    }
}
