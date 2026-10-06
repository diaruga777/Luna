import Combine
import Foundation
import MediaPlayer
import MusicKit

public extension Notification.Name {
    static let lunaMusicLibraryChanged = Notification.Name("LunaMusic.libraryChanged")
    static let lunaMusicPlaybackChanged = Notification.Name("LunaMusic.playbackChanged")
}

public struct MusicLibrarySearchResults {
    public let songs: [MusicSong]
    public let albums: [MusicCollection]
    public let artists: [MusicCollection]
    public let playlists: [MusicPlaylist]
}

@MainActor
public final class MusicLibraryController: ObservableObject {
    public static let shared = MusicLibraryController()

    @Published public private(set) var songs: [MusicSong] = []
    @Published public private(set) var playlists: [MusicPlaylist] = []
    @Published public private(set) var albums: [MusicCollection] = []
    @Published public private(set) var artists: [MusicCollection] = []
    @Published public private(set) var authorizationStatus = MusicLibraryController.libraryAuthorizationStatus
    @Published public private(set) var isLoading = false
    @Published public private(set) var errorMessage: String?
    private var observer: NSObjectProtocol?
    private var vaultObserver: NSObjectProtocol?
    private var appleSongs: [MusicSong] = []
    private var applePlaylists: [MusicPlaylist] = []
    public private(set) var hasLoaded = false
    private var loadWaiters: [CheckedContinuation<Void, Never>] = []

    private init() {
        vaultObserver = NotificationCenter.default.addObserver(forName: .lunaMusicVaultChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.publish() }
        }
        publish()
        MPMediaLibrary.default().beginGeneratingLibraryChangeNotifications()
        observer = NotificationCenter.default.addObserver(forName: .MPMediaLibraryDidChange,
                                                          object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.reload() }
        }
    }

    public func authorizeAndLoad() async {
        _ = await MusicAuthorization.request()
        if MPMediaLibrary.authorizationStatus() == .notDetermined {
            _ = await withCheckedContinuation { continuation in
                MPMediaLibrary.requestAuthorization { continuation.resume(returning: $0) }
            }
        }
        await reload()
    }

    public func reload(refreshVault: Bool = true) async {
        authorizationStatus = Self.libraryAuthorizationStatus
        guard authorizationStatus == .authorized else {
            appleSongs = []; applePlaylists = []; hasLoaded = true; publish()
            if refreshVault { await VaultMusicController.shared.refresh() }
            NotificationCenter.default.post(name: .lunaMusicLibraryChanged, object: self)
            return
        }
        guard !isLoading else {
            await withCheckedContinuation { loadWaiters.append($0) }
            return
        }
        isLoading = true
        errorMessage = nil
        NotificationCenter.default.post(name: .lunaMusicLibraryChanged, object: self)
        // Queries do synchronous IPC. Run them on a serial background queue; the returned
        // media objects are immutable snapshots and published together on the main actor.
        let snapshot = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let snapshot = LibrarySnapshot(
                    songs: (MPMediaQuery.songs().items ?? []).map(MusicSong.init),
                    playlists: (MPMediaQuery.playlists().collections ?? []).compactMap { $0 as? MPMediaPlaylist }.map(MusicPlaylist.init))
                continuation.resume(returning: snapshot)
            }
        }
        guard Self.libraryAuthorizationStatus == .authorized else {
            isLoading = false
            finishLoadWaiters()
            await reload()
            return
        }
        appleSongs = snapshot.songs
        applePlaylists = snapshot.playlists
        publish()
        isLoading = false
        hasLoaded = true
        finishLoadWaiters()
        if refreshVault { await VaultMusicController.shared.refresh() }
        NotificationCenter.default.post(name: .lunaMusicLibraryChanged, object: self)
    }

    private func publish() {
        songs = (appleSongs + VaultMusicController.shared.songs).sorted {
            ($0.title ?? "").localizedStandardCompare($1.title ?? "") == .orderedAscending
        }
        playlists = (applePlaylists + VaultMusicController.shared.playlists).sorted {
            ($0.name ?? "").localizedStandardCompare($1.name ?? "") == .orderedAscending
        }
        albums = Dictionary(grouping: songs, by: \.albumPersistentID).values.map { items in
            MusicCollection(items: items.sorted {
                if $0.discNumber != $1.discNumber { return $0.discNumber < $1.discNumber }
                if $0.albumTrackNumber != $1.albumTrackNumber { return $0.albumTrackNumber < $1.albumTrackNumber }
                return ($0.title ?? "") < ($1.title ?? "")
            })
        }.sorted { ($0.representativeItem?.albumTitle ?? "") < ($1.representativeItem?.albumTitle ?? "") }
        artists = Dictionary(grouping: songs, by: \.artistPersistentID).values.map { MusicCollection(items: $0) }
            .sorted { ($0.representativeItem?.artist ?? "") < ($1.representativeItem?.artist ?? "") }
        NotificationCenter.default.post(name: .lunaMusicLibraryChanged, object: self)
    }

    private func finishLoadWaiters() {
        let waiting = loadWaiters
        loadWaiters.removeAll()
        waiting.forEach { $0.resume() }
    }

    @discardableResult
    public func createPlaylist(name: String, items: [MusicSong] = [], source: MusicSource = .apple) async throws -> MusicPlaylist {
        let source = items.first?.source ?? source
        guard items.allSatisfy({ $0.source == source }) else { throw MusicFileError("A playlist can contain Apple Music songs or Vault songs, but not both.") }
        if source == .vault { return try VaultMusicController.shared.createPlaylist(name: name, songs: items) }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw MusicLibraryError.missingPlaylistName }
        guard Self.libraryAuthorizationStatus == .authorized else { throw MusicLibraryError.notAuthorized }
        let playlist: MPMediaPlaylist = try await withCheckedThrowingContinuation { continuation in
            MPMediaLibrary.default().getPlaylist(with: UUID(), creationMetadata: MPMediaPlaylistCreationMetadata(name: name)) { playlist, error in
                if let error { continuation.resume(throwing: error) }
                else if let playlist { continuation.resume(returning: playlist) }
                else { continuation.resume(throwing: MusicLibraryError.playlistCreationFailed) }
            }
        }
        if !items.isEmpty { try await add(items, to: MusicPlaylist(playlist)) }
        else { await reload() }
        return MusicPlaylist(playlist)
    }

    public func add(_ items: [MusicSong], to playlist: MusicPlaylist) async throws {
        guard items.allSatisfy({ $0.source == playlist.source }) else { throw MusicFileError("A playlist can contain only songs from its own source.") }
        if playlist.source == .vault { try VaultMusicController.shared.add(items, to: playlist); return }
        guard let mediaPlaylist = playlist.mediaPlaylist else { throw MusicLibraryError.playlistCreationFailed }
        guard Self.libraryAuthorizationStatus == .authorized else { throw MusicLibraryError.notAuthorized }
        guard !items.isEmpty else { return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            mediaPlaylist.add(items.compactMap(\.mediaItem)) { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
        await reload()
    }

    private static var libraryAuthorizationStatus: MusicAuthorization.Status {
        switch MPMediaLibrary.authorizationStatus() {
        case .authorized: return .authorized
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notDetermined
        @unknown default: return .denied
        }
    }

    public func search(_ text: String) -> MusicLibrarySearchResults {
        let terms = text.split(whereSeparator: \.isWhitespace).map(String.init)
        func matches(_ values: String?...) -> Bool {
            let joined = values.compactMap { $0 }.joined(separator: " ")
            return terms.allSatisfy { joined.localizedStandardContains($0) }
        }
        return MusicLibrarySearchResults(
            songs: songs.filter { matches($0.title, $0.albumTitle, $0.artist) },
            albums: albums.filter { matches($0.representativeItem?.albumTitle, $0.representativeItem?.albumArtist) },
            artists: artists.filter { matches($0.representativeItem?.artist) },
            playlists: playlists.filter { matches($0.name) })
    }
}

private struct LibrarySnapshot: @unchecked Sendable {
    let songs: [MusicSong]
    let playlists: [MusicPlaylist]
}

public enum MusicLibraryError: LocalizedError {
    case missingPlaylistName, notAuthorized, playlistCreationFailed
    public var errorDescription: String? {
        switch self {
        case .missingPlaylistName: return "Enter a playlist name."
        case .notAuthorized: return "Allow Luna Music to access your music library in Settings."
        case .playlistCreationFailed: return "The music library could not create the playlist."
        }
    }
}
