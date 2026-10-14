import AVFoundation
import LunaPodcastCore

/// Durable preparation performed once after transfer, never during app launch.
/// Compressed packets are copied into an indexed container, not decoded/re-encoded.
enum PodcastAudioPreparation {
    struct Result: Sendable {
        var url: URL
        var duration: Double?
        var chapters: [PodcastChapter]
    }
    static func prepare(_ url: URL, mediaType: String, suffix: String) async throws -> Result {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let length = try? await asset.load(.duration).seconds
        let duration = length.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        var chapters: [PodcastChapter] = []
        if let locale = try? await asset.load(.availableChapterLocales).first,
           let groups = try? await asset.loadChapterMetadataGroups(withTitleLocale: locale, containingItemsWithCommonKeys: [.commonKeyTitle]) {
            for group in groups {
                let title = try? await group.items.first?.load(.stringValue)
                chapters.append(.init(start: group.timeRange.start.seconds, title: title ?? "Chapter"))
            }
        }
        try Task.checkCancellation()
        let original = Result(url: url, duration: duration, chapters: chapters)
        // MP4/M4A and PCM already provide direct timing/seek information. Raw
        // compressed audio may require scanning packet headers on every cold seek.
        guard ["mp3", "aac"].contains(suffix) || ["audio/mpeg", "audio/mp3", "audio/aac", "audio/aacp"].contains(mediaType),
              let duration,
              let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough),
              exporter.supportedFileTypes.contains(.mov) else { return original }
        let indexed = url.appendingPathExtension("indexed.mov")
        do {
            try await withTaskCancellationHandler {
                try await exporter.export(to: indexed, as: .mov)
            } onCancel: { exporter.cancelExport() }
            try Task.checkCancellation()
            let output = AVURLAsset(url: indexed)
            let outputDuration = try await output.load(.duration).seconds
            let audio = try await output.loadTracks(withMediaType: .audio)
            guard !audio.isEmpty, outputDuration.isFinite,
                  abs(outputDuration - duration) < max(0.1, duration * 0.001) else {
                try? FileManager.default.removeItem(at: indexed); return original
            }
            return Result(url: indexed, duration: outputDuration, chapters: chapters)
        } catch {
            try? FileManager.default.removeItem(at: indexed)
            try Task.checkCancellation()
            // An unusual publisher format must remain playable if passthrough
            // isn't supported. Never fall back to a lossy transcoding preset.
            return original
        }
    }
}
