import Combine
import Foundation
import MediaPlayer
import MusicKit

public extension Notification.Name {
    static let lunaMusicLibraryChanged = Notification.Name("LunaMusic.libraryChanged")
    static let lunaMusicPlaybackChanged = Notification.Name("LunaMusic.playbackChanged")
}

public struct MusicLibrarySearchResults {
    public let songs: [MPMediaItem]
    public let albums: [MPMediaItemCollection]
    public let artists: [MPMediaItemCollection]
    public let playlists: [MPMediaPlaylist]
}

@MainActor
public final class MusicLibraryController: ObservableObject {
    public static let shared = MusicLibraryController()

    @Published public private(set) var songs: [MPMediaItem] = []
    @Published public private(set) var playlists: [MPMediaPlaylist] = []
    @Published public private(set) var albums: [MPMediaItemCollection] = []
    @Published public private(set) var artists: [MPMediaItemCollection] = []
    @Published public private(set) var authorizationStatus = MusicLibraryController.libraryAuthorizationStatus
    @Published public private(set) var isLoading = false
    @Published public private(set) var errorMessage: String?
    private var observer: NSObjectProtocol?
    private var pendingReload = false

    private init() {
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

    public func reload() async {
        authorizationStatus = Self.libraryAuthorizationStatus
        guard authorizationStatus == .authorized else {
            songs = []; playlists = []; albums = []; artists = []
            NotificationCenter.default.post(name: .lunaMusicLibraryChanged, object: self)
            return
        }
        guard !isLoading else { pendingReload = true; return }
        isLoading = true
        errorMessage = nil
        // Queries do synchronous IPC. Run them on a serial background queue; the returned
        // media objects are immutable snapshots and published together on the main actor.
        let snapshot = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let snapshot = LibrarySnapshot(
                    songs: MPMediaQuery.songs().items ?? [],
                    playlists: (MPMediaQuery.playlists().collections ?? []).compactMap { $0 as? MPMediaPlaylist },
                    albums: MPMediaQuery.albums().collections ?? [],
                    artists: MPMediaQuery.artists().collections ?? [])
                continuation.resume(returning: snapshot)
            }
        }
        guard Self.libraryAuthorizationStatus == .authorized else {
            isLoading = false
            await reload()
            return
        }
        songs = snapshot.songs
        playlists = snapshot.playlists.sorted {
            ($0.name ?? "").localizedStandardCompare($1.name ?? "") == .orderedAscending
        }
        albums = snapshot.albums
        artists = snapshot.artists
        isLoading = false
        NotificationCenter.default.post(name: .lunaMusicLibraryChanged, object: self)
        if pendingReload { pendingReload = false; await reload() }
    }

    @discardableResult
    public func createPlaylist(name: String, items: [MPMediaItem] = []) async throws -> MPMediaPlaylist {
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
        if !items.isEmpty { try await add(items, to: playlist) }
        else { await reload() }
        return playlist
    }

    public func add(_ items: [MPMediaItem], to playlist: MPMediaPlaylist) async throws {
        guard Self.libraryAuthorizationStatus == .authorized else { throw MusicLibraryError.notAuthorized }
        guard !items.isEmpty else { return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            playlist.add(items) { error in
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
    let songs: [MPMediaItem]
    let playlists: [MPMediaPlaylist]
    let albums: [MPMediaItemCollection]
    let artists: [MPMediaItemCollection]
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
