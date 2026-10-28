import AVFoundation
import Foundation
import Combine
import LunaAudioPlayback
import LunaModels
import LunaStorage
import LunaPodcastCore

/// Music reads text saves from the App Group; only Music writes its podcast library.
/// Rendered copies belong to Music and remain playable if the original save is deleted.
@MainActor public final class ReaderPodcastController: ObservableObject {
    public enum Voice: Sendable { case device, gemini }
    public var hasGeminiAPIKey: Bool { geminiAvailable() }
    public static let shared = ReaderPodcastController()
    @Published public private(set) var progress: [UUID: Double] = [:]
    private let saves: SavesStore
    private let library: PodcastLibraryController
    private let directory: URL
    private let render: (AudioScript, URL, @escaping (Double) -> Void) async throws -> Double
    private let renderGemini: (UUID, AudioScript, URL, @escaping (Double) -> Void) async throws -> Double
    private let preferredVoice: () -> Voice
    private let geminiAvailable: () -> Bool
    private var jobVoices: [UUID: Voice] = [:]
    private var jobs: [UUID: Task<PodcastEpisode, Error>] = [:]
    private var renderTail: Task<PodcastEpisode, Error>?

    public init(saves: SavesStore = .shared, library: PodcastLibraryController = .shared,
                directory: URL = PodcastLibraryController.directory.appendingPathComponent("ReaderAudio", isDirectory: true),
                render: @escaping (AudioScript, URL, @escaping (Double) -> Void) async throws -> Double = {
                    try await AudioScriptFileRenderer.write($0, to: $1, progress: $2)
                },
                renderGemini: @escaping (UUID, AudioScript, URL, @escaping (Double) -> Void) async throws -> Double = { id, script, url, progress in
                    guard let voice = try await GeminiArticleSpeech.shared.renderer(itemID: id, script: script, allowGeneration: true, progress: { progress($0 * 0.9) }) else {
                        throw PodcastError(L10n.string("Gemini_unavailable"))
                    }
                    return try await AudioScriptFileRenderer.write(script, to: url, using: voice, progress: { progress(0.9 + $0 * 0.1) })
                },
                preferredVoice: @escaping () -> Voice = { AudioSettings.usesGeminiVoice ? .gemini : .device },
                geminiAvailable: @escaping () -> Bool = { GeminiSpeechCredential.apiKey?.isEmpty == false }) {
        self.saves = saves; self.library = library; self.directory = directory; self.render = render
        self.renderGemini = renderGemini; self.preferredVoice = preferredVoice; self.geminiAvailable = geminiAvailable
    }
    public nonisolated static func isTextSave(_ item: SavedItem) -> Bool {
        item.state == .ready && item.exportKind == .article && item.contentFileName != nil
    }
    public func items() async -> [SavedItem] {
        let saves = saves
        return await Task.detached(priority: .userInitiated) {
            saves.items().filter { Self.isTextSave($0) && saves.content(for: $0)?.blocks.contains(where: {
                !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }) == true }
        }.value
    }
    @discardableResult public func enqueue(_ saveID: UUID, next: Bool = false, voice: Voice? = nil) async throws -> PodcastEpisode {
        let voice = voice ?? preferredVoice()
        if let job = jobs[saveID] {
            guard jobVoices[saveID] == voice else { throw PodcastError(L10n.string("Music_reader_generationBusy")) }
            return try await job.value
        }
        progress[saveID] = 0
        // Keep selection order even when a later save is shorter or already rendered.
        // One speech job at a time also bounds synthesis memory and service usage.
        let previous = renderTail
        let job = Task {
            _ = try? await previous?.value
            let episode = try await self.prepare(saveID, voice: voice)
            try self.library.requireStore().enqueue(episode.id, next: next)
            self.library.reloadState()
            return episode
        }
        jobs[saveID] = job; jobVoices[saveID] = voice; renderTail = job
        defer { jobs[saveID] = nil; jobVoices[saveID] = nil; progress[saveID] = nil }
        return try await job.value
    }
    public func removeReadout(_ episode: PodcastEpisode) throws {
        guard episode.showID == ReaderPodcastSource.showID else { return }
        guard library.state.currentEpisodeID != episode.id else {
            throw PodcastError("Choose another episode before removing this readout.")
        }
        try library.edit { state in
            state.queue.removeAll { $0 == episode.id }; state.continuation.removeAll { $0 == episode.id }
            state.episodes.removeValue(forKey: episode.id); state.progress.removeValue(forKey: episode.id)
            if state.lastPlayedEpisodeID == episode.id { state.lastPlayedEpisodeID = nil }
        }
        // Derive the owned path from the episode ID rather than trusting a stored URL.
        for voice in [Voice.device, .gemini] {
            let url = audioURL(episode.id, voice: voice)
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        }
    }
    private func audioURL(_ id: String, voice: Voice) -> URL {
        directory.appendingPathComponent(voice == .gemini ? "\(id).gemini.m4a" : "\(id).m4a")
    }
    private func prepare(_ saveID: UUID, voice: Voice) async throws -> PodcastEpisode {
        let id = ReaderPodcastSource.episodeID(saveID)
        let destination = audioURL(id, voice: voice)
        let existing = library.state.episodes[id]
        let changingVoice = existing != nil && existing?.mediaURL.lastPathComponent != destination.lastPathComponent
        if let episode = existing, !changingVoice, FileManager.default.fileExists(atPath: episode.mediaURL.path) { return episode }
        guard !changingVoice || library.state.currentEpisodeID != id else {
            throw PodcastError(L10n.string("Music_reader_changeVoiceWhilePlaying"))
        }
        let saves = saves
        let (item, content, script) = try await Task.detached(priority: .userInitiated) {
            guard let item = saves.item(withID: saveID), Self.isTextSave(item),
                  let content = saves.content(for: item) else {
                throw PodcastError("This save is no longer available. Open it in Luna Reader and try again.")
            }
            let cached = item.contentFileName.flatMap { AudioScriptStore(articlesDirectory: saves.articlesDirectory).load(forContentFileName: $0)?.script }
            let script = cached ?? AudioTrimHeuristics.classify(content).heuristicScript(for: content)
            return (item, content, script)
        }.value
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appendingPathComponent("\(UUID().uuidString).partial.m4a")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let duration: Double
        // Voice-specific exports let an existing device readout be upgraded to
        // Gemini without mistaking the old audio for an already generated result.
        if FileManager.default.fileExists(atPath: destination.path) {
            duration = try await AVURLAsset(url: destination).load(.duration).seconds
        } else {
            let reportProgress: (Double) -> Void = { value in
                Task { @MainActor in
                    if self.jobs[saveID] != nil { self.progress[saveID] = value }
                }
            }
            duration = try await voice == .gemini
                ? renderGemini(saveID, script, temporary, reportProgress)
                : render(script, temporary, reportProgress)
            try FileManager.default.moveItem(at: temporary, to: destination)
        }
        var episode = PodcastEpisode(showID: ReaderPodcastSource.showID, guid: saveID.uuidString,
            title: item.cardTitle ?? content.title, publishedAt: item.dateAdded, mediaURL: destination)
        episode.duration = duration; episode.mediaType = "audio/mp4"; episode.websiteURL = PodcastIdentity.webURL(item.urlString)
        episode.byteCount = (try FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?.int64Value ?? 0
        var show = PodcastShow(feedURL: URL(string: "lunamusic://reader")!, title: "Luna Reader", id: ReaderPodcastSource.showID)
        show.settings.automaticDownloadLimit = 0; show.settings.notifications = false
        show.settings.playbackRate = AudioSettings.preferredRate
        do {
            try library.edit { state in
                if state.shows[show.id] == nil { state.shows[show.id] = show }
                state.episodes[episode.id] = episode
                if changingVoice { state.progress.removeValue(forKey: episode.id) }
            }
        } catch { try? FileManager.default.removeItem(at: destination); throw error }
        return episode
    }
}
