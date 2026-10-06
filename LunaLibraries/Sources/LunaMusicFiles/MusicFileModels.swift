import Foundation
import CryptoKit

public enum MusicSource: String, Codable, Sendable { case apple, vault }

/// Source-qualified IDs prevent Apple persistent IDs colliding with file or playlist IDs.
public struct MusicID: Hashable, Codable, Sendable, Comparable, CustomStringConvertible, ExpressibleByIntegerLiteral {
    public let rawValue: String
    public var description: String { rawValue }
    public init(_ value: String) { rawValue = value }
    public init(integerLiteral value: UInt64) { rawValue = "apple:\(value)" }
    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue.compare(rhs.rawValue, options: .numeric) == .orderedAscending
    }
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let number = try? container.decode(UInt64.self) { rawValue = "apple:\(number)" }
        else { rawValue = try container.decode(String.self) }
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer(); try container.encode(rawValue)
    }
}

public enum MusicFileProtocol {
    public static let folder = "luna-music-v1"
    public static let chunkSize = 512 * 1024
    public static let pageSize = 100
    public static let maximumResponseSize = 2 * 1024 * 1024
    public static let extensions: Set<String> = ["mp3", "m4a", "mp4", "aac", "wav", "aif", "aiff", "caf", "flac"]
    public static func key(_ string: String) -> String {
        SHA256.hash(data: Data(string.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    public static func normalized(_ string: String) -> String {
        string.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
}

public struct MusicFile: Codable, Equatable, Sendable {
    public var path: String
    public var version: String
    public var size: Int64
    public var title: String
    public var artist: String
    public var album: String
    public var albumArtist: String
    public var duration: Double
    public var track: Int
    public var disc: Int
    public var modifiedAt: Date
    public var artwork: Data?
    public init(path: String, version: String, size: Int64, title: String, artist: String,
                album: String, albumArtist: String? = nil, duration: Double = 0, track: Int = 0,
                disc: Int = 0, modifiedAt: Date = Date(), artwork: Data? = nil) {
        self.path = path; self.version = version; self.size = size; self.title = title
        self.artist = artist; self.album = album; self.albumArtist = albumArtist ?? artist
        self.duration = duration; self.track = track; self.disc = disc
        self.modifiedAt = modifiedAt; self.artwork = artwork
    }
    public func id(peer: String) -> MusicID { MusicID("vault:\(peer):\(path)") }
}
public struct MusicFileRequest: Codable, Sendable {
    public enum Operation: String, Codable, Sendable { case catalog, read }
    public var operation: Operation
    public var path: String = ""
    public var version: String = ""
    public var offset: Int64 = 0
    public var length: Int = 0
    public var generation: String?
    public init(_ operation: Operation, path: String = "", version: String = "", offset: Int64 = 0,
                length: Int = 0, generation: String? = nil) {
        self.operation = operation; self.path = path; self.version = version
        self.offset = offset; self.length = length; self.generation = generation
    }
}
public struct MusicFileResponse: Codable, Sendable {
    public var files: [MusicFile] = []
    public var nextOffset: Int64?
    public var generation: String?
    public var data: Data?
    public var error: String?
    public init(files: [MusicFile] = [], nextOffset: Int64? = nil, generation: String? = nil,
                data: Data? = nil, error: String? = nil) {
        self.files = files; self.nextOffset = nextOffset; self.generation = generation
        self.data = data; self.error = error
    }
}
public struct MusicFileError: LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public struct VaultMusicPlaylist: Codable, Equatable, Sendable {
    public var id: MusicID
    public var name: String
    public var songIDs: [MusicID]
    public var playCount: Int = 0
    public var lastPlayed: Date?
    public init(name: String, songIDs: [MusicID] = []) {
        id = MusicID("vault-playlist:\(UUID().uuidString)"); self.name = name; self.songIDs = songIDs
    }
}
public struct VaultMusicState: Codable, Sendable {
    public var peer = ""
    public var files: [MusicFile] = []
    public var playlists: [VaultMusicPlaylist] = []
    public var manual: Set<MusicID> = []
    public var excluded: Set<MusicID> = []
    public var automaticPlaylistCount = 3
    public init() {}
    public var automaticIDs: Set<MusicID> {
        let ranked = playlists.filter { $0.playCount > 0 }.sorted {
            if $0.playCount != $1.playCount { return $0.playCount > $1.playCount }
            if $0.lastPlayed != $1.lastPlayed { return ($0.lastPlayed ?? .distantPast) > ($1.lastPlayed ?? .distantPast) }
            return $0.id < $1.id
        }
        return Set(ranked.prefix(min(10, max(0, automaticPlaylistCount))).flatMap(\.songIDs)).subtracting(excluded)
    }
    public var desiredIDs: Set<MusicID> { manual.union(automaticIDs) }
    public mutating func createPlaylist(name: String, songIDs: [MusicID]) throws -> VaultMusicPlaylist {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw MusicFileError("Enter a playlist name.") }
        let available = Set(files.map { $0.id(peer: peer) })
        guard songIDs.allSatisfy({ available.contains($0) }) else { throw MusicFileError("A Vault playlist can contain only Vault songs from your library.") }
        var seen = Set<MusicID>()
        let playlist = VaultMusicPlaylist(name: trimmed, songIDs: songIDs.filter { seen.insert($0).inserted })
        playlists.append(playlist); return playlist
    }
}
