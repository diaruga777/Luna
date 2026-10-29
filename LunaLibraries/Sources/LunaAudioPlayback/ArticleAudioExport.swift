import AVFoundation
import LunaModels
import LunaStorage

/// File export used by Shortcuts and app features. It never modifies a queue.
public enum ArticleAudioExport {
    public enum Voice: String { case device, gemini }
    public static func write(saveID: UUID, voice: Voice = .device,
                             saves: SavesStore = .shared,
                             progress: @escaping (Double) -> Void = { _ in }) async throws -> URL {
        guard let item = saves.item(withID: saveID), item.state == .ready,
              item.exportKind == .article, let content = saves.content(for: item) else {
            throw ExportError.missing
        }
        let script = item.contentFileName.flatMap {
            AudioScriptStore(articlesDirectory: saves.articlesDirectory).load(forContentFileName: $0)?.script
        } ?? AudioTrimHeuristics.classify(content).heuristicScript(for: content)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ArticleAudio-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("Article.m4a")
        do {
            if voice == .gemini {
                guard let renderer = try await GeminiArticleSpeech.shared.renderer(itemID: saveID, script: script,
                    author: content.author, allowGeneration: true, progress: { progress($0 * 0.9) }) else { throw ExportError.voice }
                _ = try await AudioScriptFileRenderer.write(script, to: url, using: renderer, progress: { progress(0.9 + $0 * 0.1) })
            } else { _ = try await AudioScriptFileRenderer.write(script, to: url, progress: progress) }
            return url
        } catch { try? FileManager.default.removeItem(at: directory); throw error }
    }
    private enum ExportError: LocalizedError {
        case missing, voice
        var errorDescription: String? {
            self == .missing ? "This save has no readable article. Open it in Luna Reader first." : "Set up the Gemini voice in Luna Reader first."
        }
    }
}
