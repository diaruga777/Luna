import Foundation
import Intents
import LunaMusicCore

/// SiriKit delivers natural-language media requests separately from App Shortcuts.
final class MusicSiriPlayback: NSObject, INPlayMediaIntentHandling {
    @MainActor func resolveMediaItems(for intent: INPlayMediaIntent) async -> [INPlayMediaMediaItemResolutionResult] {
        let library = await LibraryMusicPlayback.library()
        let matches = Self.matches(for: intent, in: LibraryMusicQuery.entities(in: library))
        switch matches.count {
        case 0: return [.unsupported()]
        case 1: return [.success(with: matches[0].siriItem)]
        default: return [.disambiguation(with: matches.prefix(10).map(\.siriItem))]
        }
    }

    @MainActor func handle(intent: INPlayMediaIntent) async -> INPlayMediaIntentResponse {
        let library = await LibraryMusicPlayback.library()
        let id: String
        if let resolved = Self.identifier(for: intent) {
            id = resolved
        } else {
            let matches = Self.matches(for: intent, in: LibraryMusicQuery.entities(in: library))
            guard matches.count == 1 else {
                let code: INPlayMediaIntentResponseCode = library.authorizationStatus == .authorized
                    ? .failure : .failureRequiringAppLaunch
                return INPlayMediaIntentResponse(code: code, userActivity: nil)
            }
            id = matches[0].id
        }
        do {
            try await LibraryMusicPlayback.play(id: id, in: library, shuffle: intent.playShuffled)
            return INPlayMediaIntentResponse(code: .success, userActivity: nil)
        } catch {
            return INPlayMediaIntentResponse(code: .failure, userActivity: nil)
        }
    }

    private static func identifier(for intent: INPlayMediaIntent) -> String? {
        let item = intent.mediaItems?.first ?? intent.mediaContainer
        return item?.identifier ?? intent.mediaSearch?.mediaIdentifier
    }

    static func matches(for intent: INPlayMediaIntent, in library: [LibraryMusicEntity]) -> [LibraryMusicEntity] {
        let item = intent.mediaItems?.first ?? intent.mediaContainer
        let search = intent.mediaSearch
        if let id = identifier(for: intent) {
            return library.filter { $0.id == id }
        }

        let name = MusicFileProtocol.normalized(search?.mediaName ?? item?.title ?? "")
        let artist = MusicFileProtocol.normalized(search?.artistName ?? item?.artist ?? "")
        let album = MusicFileProtocol.normalized(search?.albumName ?? "")
        var type = search?.mediaType ?? item?.type ?? .unknown
        var title = name
        // Siri may send "play ABBA" as music by an artist, with no media title.
        if title.isEmpty, !album.isEmpty, [.music, .unknown, .album, .song].contains(type) {
            title = album
            type = .album
        } else if title.isEmpty, !artist.isEmpty, [.music, .unknown, .artist, .song].contains(type) {
            title = artist
            type = .artist
        }
        guard !title.isEmpty else { return [] }

        let candidates = library.filter { entity in
            (type == .unknown || type == .music || type == entity.siriType)
                && (artist.isEmpty || MusicFileProtocol.normalized(entity.artistName ?? "") == artist)
                && (album.isEmpty || MusicFileProtocol.normalized(entity.albumName ?? "") == album)
        }
        let exact = candidates.filter { MusicFileProtocol.normalized($0.name) == title }
        if !exact.isEmpty {
            if type == .music || type == .unknown,
               let artist = exact.first(where: { $0.siriType == .artist }) {
                return [artist]
            }
            return exact
        }
        return candidates.filter { $0.name.localizedStandardContains(title) }
    }
}

private extension LibraryMusicEntity {
    var siriType: INMediaItemType {
        switch kind {
        case "song": return .song
        case "album": return .album
        case "artist": return .artist
        case "playlist": return .playlist
        default: return .unknown
        }
    }

    var siriItem: INMediaItem {
        INMediaItem(identifier: id, title: name, type: siriType, artwork: nil, artist: artistName)
    }
}
