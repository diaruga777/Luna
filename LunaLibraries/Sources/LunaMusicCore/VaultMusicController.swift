import Foundation
import Combine
import LunaMusicFiles

@MainActor
public final class VaultMusicController: ObservableObject {
    public static let shared = VaultMusicController()
    @Published public private(set) var state = VaultMusicState()
    @Published public private(set) var errorMessage: String?
    @Published public private(set) var cacheProgress: String?
    public private(set) var cache: VaultMusicCache?
    public private(set) var root: URL
    private let stateURL: URL
    private var request: VaultMusicCache.Request?
    private var peerID: (() -> String)?
    private var refreshing = false
    private var worker: Task<Void, Never>?
    private var revision = UUID()
    private var storageError: Error?
    public var songs: [MusicSong] { state.files.map { MusicSong(file: $0, peer: state.peer) } }
    public var playlists: [MusicPlaylist] { state.playlists.map { MusicPlaylist($0, songs: songs) } }
    public var cachedSongs: [MusicSong] { songs.filter(isCached) }
    init(directory suppliedDirectory: URL? = nil) {
        let directory = suppliedDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("LunaMusic", isDirectory: true)
        root = directory.appendingPathComponent("Audio", isDirectory: true)
        stateURL = directory.appendingPathComponent("vault-library.json")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: stateURL.path) {
                state = try JSONDecoder().decode(VaultMusicState.self, from: Data(contentsOf: stateURL))
                state.automaticPlaylistCount = min(10, max(0, state.automaticPlaylistCount))
            }
        } catch { storageError = error; errorMessage = error.localizedDescription }
    }
    public func configure(peer: @escaping @Sendable () -> String, request: @escaping VaultMusicCache.Request) throws {
        if let storageError { throw storageError }
        peerID = peer; self.request = request
        cache = try VaultMusicCache(root: root, peerID: peer, request: request)
    }
    public func localURL(_ song: MusicSong) -> URL? {
        guard let file = song.file else { return nil }
        let url = VaultMusicCache.url(root: root, song: song)
        return VaultMusicCache.complete(url, size: file.size) ? url : nil
    }
    public func isCached(_ song: MusicSong) -> Bool { localURL(song) != nil }
    public func refresh() async {
        guard !refreshing, let request, let peer = peerID?(), !peer.isEmpty else { return }
        refreshing = true
        defer { refreshing = false }
        do {
            var files: [MusicFile] = []
            var offset: Int64 = 0
            var generation: String?
            repeat {
                let payload = try JSONEncoder().encode(MusicFileRequest(.catalog, offset: offset, generation: generation))
                let response = try JSONDecoder().decode(MusicFileResponse.self, from: await request(payload))
                if let error = response.error { throw MusicFileError(error) }
                guard peerID?() == peer else { throw CancellationError() }
                if offset > 0, generation != response.generation { throw MusicFileError("The Mac music library changed during refresh. Try again.") }
                generation = response.generation
                files.append(contentsOf: response.files)
                guard let next = response.nextOffset else { break }
                guard next > offset, !response.files.isEmpty else { throw MusicFileError("The Mac returned an invalid music page.") }
                offset = next
            } while true
            var next = state
            // Keep user playlists; IDs from an old peer cannot match the newly paired Mac.
            next.peer = peer; next.files = files
            try save(next)
            errorMessage = nil
            changed(); reconcile()
        } catch {
            if !(error is CancellationError) { errorMessage = "Couldn’t refresh Mac music. " + error.localizedDescription; changed() }
        }
    }
    @discardableResult
    public func createPlaylist(name: String, songs: [MusicSong]) throws -> MusicPlaylist {
        guard songs.allSatisfy({ $0.source == .vault }) else { throw MusicFileError("A playlist can contain Apple Music songs or Vault songs, but not both.") }
        var next = state
        let playlist = try next.createPlaylist(name: name, songIDs: songs.map(\.persistentID))
        try save(next); changed()
        return MusicPlaylist(playlist, songs: self.songs)
    }
    public func add(_ songs: [MusicSong], to playlist: MusicPlaylist) throws {
        guard playlist.source == .vault, songs.allSatisfy({ $0.source == .vault }),
              let index = state.playlists.firstIndex(where: { $0.id == playlist.persistentID }) else { throw MusicFileError("A playlist can contain only songs from its own source.") }
        let available = Set(self.songs.map(\.persistentID))
        guard songs.allSatisfy({ available.contains($0.persistentID) }) else { throw MusicFileError("A selected song is no longer in this library.") }
        var next = state
        var seen = Set(next.playlists[index].songIDs)
        next.playlists[index].songIDs += songs.map(\.persistentID).filter { seen.insert($0).inserted }
        try save(next); changed(); reconcile()
    }
    public func removeSong(_ song: MusicSong, from playlist: MusicPlaylist) throws {
        guard let index = state.playlists.firstIndex(where: { $0.id == playlist.persistentID }) else { return }
        var next = state; next.playlists[index].songIDs.removeAll { $0 == song.persistentID }
        try save(next); changed(); reconcile()
    }
    public func deletePlaylist(_ playlist: MusicPlaylist) throws {
        var next = state; next.playlists.removeAll { $0.id == playlist.persistentID }
        try save(next); changed(); reconcile()
    }
    public func recordPlay(playlistID: MusicID) {
        guard let index = state.playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        var next = state
        next.playlists[index].playCount = min(Int.max - 1, next.playlists[index].playCount) + 1
        next.playlists[index].lastPlayed = Date()
        do { try save(next); reconcile() } catch { errorMessage = error.localizedDescription }
    }
    public func setAutomaticPlaylistCount(_ count: Int) throws {
        var next = state; next.automaticPlaylistCount = min(10, max(0, count))
        try save(next); changed(); reconcile()
    }
    public func cacheSongs(_ songs: [MusicSong]) throws {
        var next = state
        for song in songs where song.source == .vault {
            next.manual.insert(song.persistentID); next.excluded.remove(song.persistentID)
        }
        try save(next); changed(); reconcile()
    }
    public func removeCachedSong(_ song: MusicSong) async throws {
        var next = state; next.manual.remove(song.persistentID); next.excluded.insert(song.persistentID)
        try save(next)
        worker?.cancel()
        await worker?.value
        let url = VaultMusicCache.url(root: root, song: song)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        changed(); reconcile()
    }
    public func retryDownloads() { errorMessage = nil; reconcile() }
    private func save(_ next: VaultMusicState) throws {
        if let storageError { throw storageError }
        try JSONEncoder().encode(next).write(to: stateURL, options: .atomic)
        state = next
    }
    private func changed() { NotificationCenter.default.post(name: .lunaMusicVaultChanged, object: self) }
    private func reconcile() {
        let previous = worker
        previous?.cancel()
        let generation = UUID(); revision = generation
        worker = Task { [weak self] in
            await previous?.value
            guard let self, !Task.isCancelled, let cache else { return }
            let wanted = songs.filter { state.desiredIDs.contains($0.persistentID) }
            do {
                try await cache.purge(keeping: Set(wanted.map { VaultMusicCache.url(root: root, song: $0) }))
                for (index, song) in wanted.enumerated() {
                    try Task.checkCancellation()
                    if isCached(song) { continue }
                    cacheProgress = "Downloading \(index + 1) of \(wanted.count): \(song.title ?? "Song")"; changed()
                    _ = try await cache.download(song)
                    changed()
                }
            } catch { if !(error is CancellationError) { errorMessage = error.localizedDescription } }
            if revision == generation { cacheProgress = nil; changed() }
        }
    }
}
public extension Notification.Name {
    static let lunaMusicVaultChanged = Notification.Name("LunaMusic.vaultChanged")
}
