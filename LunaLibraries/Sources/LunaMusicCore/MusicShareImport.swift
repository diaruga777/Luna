import Foundation
import AVFoundation
import LunaCompanionShareCore
import LunaMusicFiles

@MainActor public enum MusicShareImport {
    private static var importing = false
    private static var timer: Timer?
    public static func start() {
        // Audio keeps the app alive in the background. Poll only while that
        // process is running so Play Next can reach the current podcast queue.
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            Task { @MainActor in await consume() }
        }
        Task { await consume() }
    }
    public static func publishChoices() {
        do {
            var choices = CompanionShareChoices()
            choices.playlists = VaultMusicController.shared.state.playlists.map { .init(id: $0.id.rawValue, title: $0.name) }
            choices.audioLists = PodcastLibraryController.shared.state.shows.values.filter {
                $0.feedURL.scheme == "lunamusic" && $0.feedURL.host == "audio-list" && $0.id != "external-audio"
            }.sorted { $0.title < $1.title }.map { .init(id: $0.id, title: $0.title) }
            try CompanionShareInbox.production("music").publish(choices)
        } catch { NSLog("Music share choices: %@", error.localizedDescription) }
    }
    public static func consume() async {
        guard !importing else { return }; importing = true
        defer { importing = false }
        do {
            let inbox = try CompanionShareInbox.production("music")
            for capture in try inbox.pending() {
                do {
                    try await importCapture(capture, inbox: inbox)
                    try inbox.remove(capture)
                } catch { PodcastLibraryController.shared.report(error); break }
            }
            publishChoices()
        } catch { PodcastLibraryController.shared.report(error) }
    }
    public static func importCapture(_ capture: CompanionShareCapture, inbox: CompanionShareInbox,
                                     podcasts: PodcastLibraryController = .shared,
                                     music: VaultMusicController = .shared) async throws {
        let directory = inbox.directory(for: capture)
        let entries = Array(capture.filenames.enumerated())
        for (index, filename) in capture.playNext && capture.kind == .podcast ? Array(entries.reversed()) : entries {
            let source = directory.appendingPathComponent(filename)
            let title = capture.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? String((filename as NSString).deletingPathExtension.drop(while: { $0 != "-" }).dropFirst()) : capture.title
            let key = capture.id.uuidString + "-\(index)"
            switch capture.kind {
            case .podcast:
                _ = try await PodcastAutomation.importAudio(at: source, title: title, listID: capture.destinations.first,
                    enqueue: true, next: capture.playNext, importKey: key, library: podcasts)
            case .song:
                var playlists = capture.destinations.map(MusicID.init)
                if !capture.newPlaylist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let id = MusicID("vault-playlist:share-" + capture.id.uuidString)
                    try music.ensureImportedPlaylist(id: id, name: capture.newPlaylist)
                    playlists.append(id)
                }
                try await music.importSong(at: source, key: key, title: title, playlists: playlists)
            default: throw MusicFileError("This shared item isn’t audio.")
            }
        }
    }
}

extension VaultMusicController {
    func ensureImportedPlaylist(id: MusicID, name: String) throws {
        guard !state.playlists.contains(where: { $0.id == id }) else { return }
        var next = state; var playlist = VaultMusicPlaylist(name: name.trimmingCharacters(in: .whitespacesAndNewlines))
        playlist.id = id; next.playlists.append(playlist); try save(next); changed()
    }
    public func importSong(at source: URL, key: String, title: String, playlists: [MusicID]) async throws {
        guard playlists.allSatisfy({ id in state.playlists.contains { $0.id == id } }) else {
            throw MusicFileError("A selected playlist is no longer available.")
        }
        let filename = MusicFileProtocol.key(key) + "." + source.pathExtension.lowercased()
        let destination = importedSongsDirectory.appendingPathComponent(filename)
        let id = MusicFile(path: filename, version: key, size: 0, title: title, artist: "", album: "").id(peer: Self.importedPeer)
        if !(state.importedFiles ?? []).contains(where: { $0.path == filename }) {
            let accessed = source.startAccessingSecurityScopedResource()
            defer { if accessed { source.stopAccessingSecurityScopedResource() } }
            let asset = AVURLAsset(url: source)
            let duration = try await asset.load(.duration).seconds
            guard duration.isFinite, duration > 0 else { throw MusicFileError("This audio file couldn’t be played.") }
            try FileManager.default.createDirectory(at: importedSongsDirectory, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
            try FileManager.default.copyItem(at: source, to: destination)
            let size = (try FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?.int64Value ?? 0
            var next = state
            next.importedFiles = (next.importedFiles ?? []) + [MusicFile(path: filename, version: key, size: size,
                title: title, artist: "", album: "Imported Audio", duration: duration)]
            do { try save(next) }
            catch { try? FileManager.default.removeItem(at: destination); throw error }
        }
        var next = state
        for index in next.playlists.indices where playlists.contains(next.playlists[index].id) {
            if !next.playlists[index].songIDs.contains(id) { next.playlists[index].songIDs.append(id) }
        }
        try save(next); changed()
    }
}
