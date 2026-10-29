import Foundation
import AVFoundation
import UniformTypeIdentifiers
import LunaAppConfig
import LunaPodcastCore

@MainActor public enum PodcastAutomation {
    public static func recordChanges(_ old: PodcastLibraryState, _ new: PodcastLibraryState) {
        for id in Set(old.episodes.keys).union(new.episodes.keys).sorted() {
            if old.episodes[id] != new.episodes[id] {
                AppAutomation.record(.music, kind: "episode", id: id, operation: new.episodes[id] == nil ? "deleted" : old.episodes[id] == nil ? "created" : "updated")
            } else if old.progress[id]?.listened != new.progress[id]?.listened {
                AppAutomation.record(.music, kind: "episode", id: id, operation: "updated")
            }
        }
        for id in Set(old.shows.keys).union(new.shows.keys).sorted() {
            let a = old.shows[id], b = new.shows[id]
            if a?.title != b?.title || a?.followed != b?.followed || a?.settings != b?.settings {
                AppAutomation.record(.music, kind: "show", id: id, operation: b == nil ? "deleted" : a == nil ? "created" : "updated")
            }
        }
        for id in Set(old.stations.map(\.id)).union(new.stations.map(\.id)).sorted() {
            let a = old.stations.first { $0.id == id }, b = new.stations.first { $0.id == id }
            if a != b { AppAutomation.record(.music, kind: "station", id: id, operation: b == nil ? "deleted" : a == nil ? "created" : "updated") }
        }
        if old.queue != new.queue { AppAutomation.record(.music, kind: "queue", id: "podcasts", operation: "updated") }
    }
    /// A local show is a named list of imported audio, using the existing podcast
    /// library and player. It is never fetched as a remote feed.
    @discardableResult public static func createAudioList(name: String, library: PodcastLibraryController = .shared) throws -> PodcastShow {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw PodcastError("Give the audio list a name.") }
        let id = "audio-list-" + UUID().uuidString
        var show = PodcastShow(feedURL: URL(string: "lunamusic://audio-list/" + id)!, title: name, id: id)
        show.followed = true; show.settings.automaticDownloadLimit = 0; show.settings.notifications = false
        try library.edit { $0.shows[id] = show }
        return show
    }
    @discardableResult public static func importAudio(at source: URL, title: String, listID: String?, enqueue: Bool,
        next: Bool = false, importKey: String? = nil, library: PodcastLibraryController = .shared) async throws -> PodcastEpisode {
        let store = try library.requireStore()
        let show: PodcastShow
        if let listID {
            guard let existing = store.state.shows[listID], existing.feedURL.scheme == "lunamusic",
                  existing.feedURL.host == "audio-list" else { throw PodcastError("Choose a local audio list.") }
            show = existing
        } else if let existing = store.state.shows["external-audio"] { show = existing }
        else {
            var value = PodcastShow(feedURL: URL(string: "lunamusic://audio-list/external-audio")!, title: "Imported Audio", id: "external-audio")
            value.followed = true; value.settings.automaticDownloadLimit = 0; value.settings.notifications = false; show = value
        }
        let key = importKey.flatMap { $0.isEmpty ? nil : $0 } ?? UUID().uuidString
        let id = PodcastIdentity.episode(showID: show.id, guid: key)
        if let existing = store.state.episodes[id] {
            if enqueue { try store.enqueue(id, next: next); library.reloadState() }
            return existing
        }
        let ext = source.pathExtension.lowercased()
        guard source.isFileURL, let type = UTType(filenameExtension: ext), type.conforms(to: .audio) else {
            throw PodcastError("Choose an audio file.")
        }
        let access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() } }
        let duration = try await AVURLAsset(url: source).load(.duration).seconds
        guard duration.isFinite, duration > 0 else { throw PodcastError("This audio file couldn’t be played.") }
        try Task.checkCancellation()
        // Another call may have finished this import while duration loaded.
        if let existing = store.state.episodes[id] {
            if enqueue { try store.enqueue(id, next: next); library.reloadState() }
            return existing
        }
        let directory = store.url.deletingLastPathComponent().appendingPathComponent("ImportedAudio", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(id + "." + ext)
        // Hash-derived owned destination, never an arbitrary input path.
        if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
        try FileManager.default.copyItem(at: source, to: destination)
        var episode = PodcastEpisode(showID: show.id, guid: key,
            title: title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? source.deletingPathExtension().lastPathComponent : title,
            publishedAt: Date(), mediaURL: destination)
        episode.duration = duration; episode.mediaType = type.preferredMIMEType ?? "audio/mp4"
        episode.byteCount = (try FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?.int64Value ?? 0
        do {
            try library.edit { state in
                state.shows[show.id] = state.shows[show.id] ?? show
                state.episodes[id] = episode
                if enqueue { if next { state.queue.insert(id, at: 0) } else { state.queue.append(id) } }
            }
        } catch { try? FileManager.default.removeItem(at: destination); throw error }
        return episode
    }
}
