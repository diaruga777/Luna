@_exported import LunaMusicFiles
import Foundation
import MediaPlayer

public struct MusicSong: @unchecked Sendable {
    public let mediaItem: MPMediaItem?
    public let file: MusicFile?
    public let peer: String
    public let persistentID: MusicID
    public var source: MusicSource { file == nil ? .apple : .vault }
    public init(_ item: MPMediaItem) {
        mediaItem = item; file = nil; peer = ""; persistentID = MusicID("apple:\(item.persistentID)")
    }
    public init(file: MusicFile, peer: String) {
        mediaItem = nil; self.file = file; self.peer = peer; persistentID = file.id(peer: peer)
    }
    public var title: String? { file?.title ?? mediaItem?.title }
    public var artist: String? { file?.artist ?? mediaItem?.artist }
    public var albumTitle: String? { file?.album ?? mediaItem?.albumTitle }
    public var albumArtist: String? { file?.albumArtist ?? mediaItem?.albumArtist ?? artist }
    public var playbackDuration: Double { file?.duration ?? mediaItem?.playbackDuration ?? 0 }
    public var dateAdded: Date { file?.modifiedAt ?? mediaItem?.dateAdded ?? .distantPast }
    public var releaseDate: Date? { mediaItem?.releaseDate }
    public var albumTrackNumber: Int { file?.track ?? mediaItem?.albumTrackNumber ?? 0 }
    public var discNumber: Int { file?.disc ?? mediaItem?.discNumber ?? 0 }
    public var artistPersistentID: MusicID { MusicID("artist:" + MusicFileProtocol.normalized(artist ?? "Unknown Artist")) }
    public var albumPersistentID: MusicID {
        MusicID("album:" + MusicFileProtocol.key(MusicFileProtocol.normalized(albumArtist ?? "Unknown Artist") + "\u{0}" + MusicFileProtocol.normalized(albumTitle ?? "Unknown Album")))
    }
    @MainActor public var isCloudItem: Bool {
        if file != nil { return !VaultMusicController.shared.isCached(self) }
        return mediaItem?.isCloudItem ?? true
    }
}
public struct MusicCollection: Sendable {
    public let items: [MusicSong]
    public var representativeItem: MusicSong? { items.first }
    public init(items: [MusicSong]) { self.items = items }
}
public struct MusicPlaylist: @unchecked Sendable {
    public let mediaPlaylist: MPMediaPlaylist?
    public let persistentID: MusicID
    public let name: String?
    public let items: [MusicSong]
    public let source: MusicSource
    public var playlistAttributes: MPMediaPlaylistAttribute { mediaPlaylist?.playlistAttributes ?? [] }
    public init(_ playlist: MPMediaPlaylist) {
        mediaPlaylist = playlist; persistentID = MusicID("apple:\(playlist.persistentID)")
        name = playlist.name; items = playlist.items.map(MusicSong.init); source = .apple
    }
    public init(_ playlist: VaultMusicPlaylist, songs: [MusicSong]) {
        mediaPlaylist = nil; persistentID = playlist.id; name = playlist.name; source = .vault
        let byID = Dictionary(songs.map { ($0.persistentID, $0) }, uniquingKeysWith: { a, _ in a })
        items = playlist.songIDs.compactMap { byID[$0] }
    }
}
