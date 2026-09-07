//
//  SpeechAnalyzerFileTranscriberTests.swift
//  LunaTests
//

import AVFoundation
import LunaTranscribe
import XCTest

/// The real on-device engine over a clip the test speaks itself. Gated like
/// `ArticleAudioEngineTests`: the simulator carries no speech model, and the
/// first run on a device downloads one, so this runs only on request:
/// `RUN_SPEECH_TRANSCRIBER_TESTS=1`.
final class SpeechAnalyzerFileTranscriberTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["RUN_SPEECH_TRANSCRIBER_TESTS"] == "1",
            "set RUN_SPEECH_TRANSCRIBER_TESTS=1 to run the on-device speech engine")
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpeechAnalyzerFileTranscriberTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        super.tearDown()
    }

    func testASpokenClipComesBackAsText() async throws {
        guard #available(iOS 26, *) else { throw XCTSkip("SpeechAnalyzer needs iOS 26") }
        let engine = SpeechAnalyzerFileTranscriber()
        try XCTSkipUnless(engine.availability == .available, "no speech transcriber on this device")

        let clip = try await renderSpeech("Hello Luna, this is a short recording about the moon.")
        var lastProgress = 0.0
        let segments = try await engine.transcribe(
            audioFileURL: clip, mediaKind: .audio, language: "en",
            progress: { lastProgress = max(lastProgress, $0) })

        let text = segments.map(\.text).joined(separator: " ").lowercased()
        XCTAssertTrue(text.contains("moon") || text.contains("recording"), text)
        XCTAssertEqual(lastProgress, 1, accuracy: 0.001)
        XCTAssertTrue(segments.allSatisfy { $0.end >= $0.start })
    }

    func testAnUnknownLanguageIsRefusedBeforeDecoding() async throws {
        guard #available(iOS 26, *) else { throw XCTSkip("SpeechAnalyzer needs iOS 26") }
        let engine = SpeechAnalyzerFileTranscriber()
        try XCTSkipUnless(engine.availability == .available, "no speech transcriber on this device")
        do {
            _ = try await engine.transcribe(
                audioFileURL: directory.appendingPathComponent("missing.m4a"), mediaKind: .audio,
                language: "zxx-Qaaa", progress: { _ in })
            XCTFail("an unsupported language must fail closed")
        } catch let error as TranscriptionError {
            XCTAssertEqual(error, .unsupportedLanguage)
        }
    }

    /// Renders `text` through the system voice into an m4a.
    private func renderSpeech(_ text: String) async throws -> URL {
        let url = directory.appendingPathComponent("speech.caf")
        let synthesizer = AVSpeechSynthesizer()
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        var file: AVAudioFile?
        return try await withCheckedThrowingContinuation { continuation in
            synthesizer.write(utterance) { buffer in
                guard let pcm = buffer as? AVAudioPCMBuffer else { return }
                if pcm.frameLength == 0 {
                    continuation.resume(returning: url)
                    return
                }
                do {
                    if file == nil {
                        file = try AVAudioFile(forWriting: url, settings: pcm.format.settings)
                    }
                    try file?.write(from: pcm)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
