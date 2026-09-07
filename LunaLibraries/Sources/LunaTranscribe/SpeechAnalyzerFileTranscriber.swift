//
//  SpeechAnalyzerFileTranscriber.swift
//  LunaTranscribe
//

import AVFoundation
import Foundation
import LunaModels
import Speech

/// Picks the engine for the running OS.
public enum TranscriptionEngineFactory {
    public static func make() -> any TranscriptionEngine {
        if #available(iOS 26, *) {
            return SpeechAnalyzerFileTranscriber()
        }
        return UnavailableTranscriptionEngine()
    }
}

/// The engine below iOS 26: it can run nothing, and says so.
public struct UnavailableTranscriptionEngine: TranscriptionEngine {
    public init() {}

    public var availability: TranscriptionAvailability { .unsupportedOS }

    public func transcribe(
        audioFileURL: URL, mediaKind: TranscriptionRequest.MediaKind, language: String?,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> [TranscriptSegment] {
        throw TranscriptionError.unsupportedOS
    }
}

/// On-device transcription of a local file through `SpeechAnalyzer` and
/// `SpeechTranscriber`, the same modules `LunaWriterVoice` runs over the
/// microphone. The file's audio track is decoded by `AudioTrackReader` in the
/// analyzer's preferred format and fed as one `AnalyzerInput` sequence.
@available(iOS 26, *)
public final class SpeechAnalyzerFileTranscriber: TranscriptionEngine {

    public init() {}

    public var availability: TranscriptionAvailability {
        SpeechTranscriber.isAvailable ? .available : .unsupportedOS
    }

    public func transcribe(
        audioFileURL: URL, mediaKind: TranscriptionRequest.MediaKind, language: String?,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> [TranscriptSegment] {
        guard SpeechTranscriber.isAvailable else { throw TranscriptionError.unsupportedOS }
        let locale = try await Self.resolveLocale(language)
        let module = SpeechTranscriber(
            locale: locale, transcriptionOptions: [], reportingOptions: [],
            attributeOptions: [.audioTimeRange])
        try await Self.ensureAssets(for: module, locale: locale)

        let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module])
        let decoded = try await AudioTrackReader.open(fileURL: audioFileURL, outputFormat: format)
        let total = decoded.duration

        let analyzer = SpeechAnalyzer(modules: [module])
        let (inputs, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        let collector = SegmentCollector()

        try await withThrowingTaskGroup(of: Void.self) { group in
            // The results loop subscribes BEFORE the analyzer starts, as the
            // Writer's transcriber does: `analyzeSequence` does not return until
            // the input ends, and nothing else drains `module.results`.
            group.addTask {
                for try await result in module.results where result.isFinal {
                    await collector.append(
                        TranscriptSegment(
                            start: result.range.start.seconds,
                            end: result.range.end.seconds,
                            text: String(result.text.characters)))
                }
            }
            group.addTask {
                defer { continuation.finish() }
                for try await chunk in decoded.chunks {
                    continuation.yield(AnalyzerInput(buffer: chunk.buffer, bufferStartTime: chunk.start))
                    if total > 0 {
                        progress(min(1, max(0, chunk.start.seconds / total)))
                    }
                }
            }
            group.addTask {
                _ = try await analyzer.analyzeSequence(inputs)
                try await analyzer.finalizeAndFinishThroughEndOfInput()
            }
            try await group.waitForAll()
        }
        progress(1)
        return await collector.sorted()
    }

    // MARK: - Locale and assets

    /// The supported locale for `language`, matched by language code so
    /// `en-GB` finds `en_US` when that is what the device carries. Nil asks
    /// for the device locale, then any English.
    static func resolveLocale(_ language: String?) async throws -> Locale {
        let supported = await SpeechTranscriber.supportedLocales
        func match(_ wanted: Locale) -> Locale? {
            if let exact = supported.first(where: {
                $0.identifier(.bcp47) == wanted.identifier(.bcp47)
            }) { return exact }
            guard let code = wanted.language.languageCode?.identifier else { return nil }
            return supported.first { $0.language.languageCode?.identifier == code }
        }
        if let language, !language.isEmpty {
            guard let found = match(Locale(identifier: language)) else {
                throw TranscriptionError.unsupportedLanguage
            }
            return found
        }
        if let current = match(.current) { return current }
        if let english = match(Locale(identifier: "en")) { return english }
        throw TranscriptionError.unsupportedLanguage
    }

    static func ensureAssets(for module: SpeechTranscriber, locale: Locale) async throws {
        var status = await AssetInventory.status(forModules: [module])
        switch status {
        case .installed:
            return
        case .unsupported:
            throw TranscriptionError.unsupportedLanguage
        default:
            break
        }
        let reserved = await AssetInventory.reservedLocales
        let maximumReserved = await AssetInventory.maximumReservedLocales
        if !reserved.contains(locale), reserved.count < maximumReserved {
            _ = try? await AssetInventory.reserve(locale: locale)
        }
        if let request = try? await AssetInventory.assetInstallationRequest(supporting: [module]) {
            try? await request.downloadAndInstall()
        }
        status = await AssetInventory.status(forModules: [module])
        guard status == .installed else { throw TranscriptionError.modelNotInstalled }
    }
}

private actor SegmentCollector {
    private var segments: [TranscriptSegment] = []

    func append(_ segment: TranscriptSegment) {
        segments.append(segment)
    }

    func sorted() -> [TranscriptSegment] {
        segments.sorted { $0.start < $1.start }
    }
}
