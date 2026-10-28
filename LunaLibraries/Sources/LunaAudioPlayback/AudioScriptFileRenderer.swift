import AVFoundation

/// Writes one block at a time so exporting a long save never retains its entire PCM audio.
public enum AudioScriptFileRenderer {
    public static func write(_ script: AudioScript, to url: URL,
                             progress: @escaping (Double) -> Void = { _ in }) async throws -> Double {
        let renderer = SpeechRenderer()
        return try await write(script, to: url, render: { try await renderer.render($0) }, progress: progress)
    }

    static func write(_ script: AudioScript, to url: URL,
                      render: (AudioScript.SpokenBlock) async throws -> RenderedSegment,
                      progress: (Double) -> Void) async throws -> Double {
        var completed = false
        defer { if !completed { try? FileManager.default.removeItem(at: url) } }
        let blocks = script.spokenBlocks.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !blocks.isEmpty else { throw ExportError.emptyText }
        var file: AVAudioFile?
        var duration: Double = 0
        for (index, block) in blocks.enumerated() {
            try Task.checkCancellation()
            let segment = try await render(block)
            try Task.checkCancellation()
            // A missing voice can return empty buffers. Never publish a truncated readout.
            guard segment.buffers.contains(where: { $0.frameLength > 0 }) else { throw ExportError.noSpeech }
            if file == nil {
                file = try AVAudioFile(forWriting: url, settings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: segment.format.sampleRate,
                    AVNumberOfChannelsKey: segment.format.channelCount,
                    AVEncoderBitRateKey: 64_000,
                ], commonFormat: .pcmFormatFloat32, interleaved: false)
            }
            for buffer in segment.buffers { try file?.write(from: buffer) }
            duration += segment.duration
            progress(Double(index + 1) / Double(blocks.count))
        }
        file = nil // Finalize the container before the caller moves it into place.
        guard duration > 0 else { throw ExportError.noSpeech }
        completed = true
        return duration
    }

    private enum ExportError: LocalizedError {
        case emptyText, noSpeech
        var errorDescription: String? {
            switch self {
            case .emptyText: return "This save has no text to read aloud."
            case .noSpeech: return "Audio could not be created. Try choosing another read-aloud voice in Luna Reader."
            }
        }
    }
}
