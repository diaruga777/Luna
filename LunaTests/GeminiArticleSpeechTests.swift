import AVFoundation
import XCTest
import LunaModels
@testable import LunaAudioPlayback

final class GeminiArticleSpeechTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func script(_ texts: [String]) -> AudioScript {
        AudioScript(spokenBlocks: texts.enumerated().map { .init(blockIndex: $0.offset, text: $0.element) },
                    totalWordCount: texts.reduce(0) { $0 + AudioWordIndexing.wordCount(in: $1) }, builderVersion: 1)
    }
    private func wav() throws -> Data {
        let fileURL = directory.appendingPathComponent("fixture.wav")
        let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24_000, channels: 1, interleaved: true)!
        var file: AVAudioFile? = try AVAudioFile(forWriting: fileURL, settings: format.settings, commonFormat: .pcmFormatInt16, interleaved: true)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 24_000)!
        buffer.frameLength = 24_000
        memset(buffer.int16ChannelData![0], 0, 48_000)
        try file!.write(from: buffer)
        file = nil
        return try Data(contentsOf: fileURL)
    }
    private func response(_ audio: Data, status: String = "completed") throws -> Data {
        try JSONSerialization.data(withJSONObject: ["status": status, "steps": [["type": "model_output", "content": [["type": "audio", "mime_type": "audio/wav", "data": audio.base64EncodedString()]]]]])
    }
    private func http(_ request: URLRequest, status: Int = 200) -> HTTPURLResponse {
        HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
    }

    func testChunkingPreservesTextAndBoundsEnglishAndUnspacedText() {
        for text in [Array(repeating: "word", count: 2_100).joined(separator: " "), String(repeating: "新聞", count: 7_000)] {
            let plan = GeminiSpeechPlan(script: script([text]))
            XCTAssertEqual(plan.chunks.joined(), text)
            XCTAssertTrue(plan.chunks.allSatisfy { $0.utf8.count <= 7_500 })
            XCTAssertTrue(plan.chunks.allSatisfy { AudioWordIndexing.wordCount(in: $0) <= 1_200 })
        }
    }
    func testTypicalArticleRequestCountsAndCacheIdentity() {
        for (words, expected) in [(600, 1), (800, 1), (1_000, 1), (1_200, 1), (1_800, 2), (2_400, 2)] {
            XCTAssertEqual(GeminiSpeechPlan(script: script([Array(repeating: "word", count: words).joined(separator: " ")])).chunks.count, expected)
        }
        XCTAssertNotEqual(GeminiSpeechPlan(script: script(["old"])).fingerprint, GeminiSpeechPlan(script: script(["new"])).fingerprint)
        XCTAssertNotEqual(GeminiSpeechPlan(script: script(["one", "two"])).fingerprint, GeminiSpeechPlan(script: script(["one\n\ntwo"])).fingerprint)
    }
    func testRequestKeepsKeyOutOfURLAndUsesStatelessVerbatimTTS() throws {
        let request = try GeminiArticleSpeech.request(text: "Hello, article.", apiKey: "secret")
        XCTAssertFalse(request.url!.absoluteString.contains("secret"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-goog-api-key"), "secret")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "gemini-3.8-flash-tts")
        XCTAssertEqual(body["store"] as? Bool, false)
        let generation = try XCTUnwrap(body["generation_config"] as? [String: Any])
        XCTAssertEqual(generation["max_output_tokens"] as? Int, 16_384)
        let input = try XCTUnwrap(body["input"] as? [[String: Any]])
        let content = try XCTUnwrap(input[0]["content"] as? [[String: Any]])
        XCTAssertEqual(content[0]["text"] as? String, "Hello, article.")
    }
    func testRejectsIncompleteAndInvalidAudio() throws {
        let audio = try wav()
        XCTAssertEqual(try GeminiArticleSpeech.audio(from: response(audio)), audio)
        XCTAssertThrowsError(try GeminiArticleSpeech.audio(from: response(audio, status: "incomplete")))
        XCTAssertThrowsError(try GeminiArticleSpeech.audio(from: response(Data("not audio".utf8))))
        XCTAssertThrowsError(try GeminiArticleSpeech.audio(from: Data("{}".utf8)))
    }
    func testGenerationCachesAndReplaysOfflineWithoutKey() async throws {
        let data = try response(wav())
        let calls = Counter()
        let provider = GeminiArticleSpeech(directory: directory.appendingPathComponent("cache"), send: { request in
            await calls.increment()
            return (data, self.http(request))
        })
        let id = UUID()
        let script = script(["First paragraph.", "Second paragraph."])
        let first = try await provider.renderer(itemID: id, script: script, allowGeneration: true)
        XCTAssertNotNil(first)
        let offline = GeminiArticleSpeech(directory: directory.appendingPathComponent("cache"), apiKey: { nil }, send: { _ in
            XCTFail("Cache replay must not use the network")
            throw GeminiSpeechError.unavailable
        })
        let result = try await offline.renderer(itemID: id, script: script, allowGeneration: false)
        let cached = try XCTUnwrap(result)
        var frames = 0
        for block in script.spokenBlocks {
            let segment = try await cached.render(block)
            frames += segment.buffers.reduce(0) { $0 + Int($1.frameLength) }
            XCTAssertTrue(segment.wordMarkers.isEmpty)
            XCTAssertEqual(segment.format.sampleRate, 24_000)
        }
        XCTAssertEqual(frames, 24_000, "Every generated frame plays once across paragraph boundaries")
        let count = await calls.value
        XCTAssertEqual(count, 1)
    }
    func testAutoplayMissNeverGeneratesAndMissingKeyFailsOnlyOnDemand() async throws {
        let provider = GeminiArticleSpeech(directory: directory, apiKey: { nil }, send: { _ in
            XCTFail("No authorized generation")
            throw GeminiSpeechError.unavailable
        })
        let cached = try await provider.renderer(itemID: UUID(), script: script(["Article"]), allowGeneration: false)
        XCTAssertNil(cached)
        do {
            _ = try await provider.renderer(itemID: UUID(), script: script(["Article"]), allowGeneration: true)
            XCTFail("Missing key should fail")
        } catch { XCTAssertTrue(error is GeminiSpeechError) }
    }
    func testQuotaRetryReusesCompletedChunksAndConcurrentRequestsDeduplicate() async throws {
        let data = try response(wav())
        let calls = Counter()
        let provider = GeminiArticleSpeech(directory: directory.appendingPathComponent("cache"), send: { request in
            let count = await calls.increment()
            try await Task.sleep(nanoseconds: 20_000_000)
            return (data, self.http(request, status: count == 2 ? 429 : 200))
        })
        let id = UUID()
        let script = script([Array(repeating: "word", count: 1_500).joined(separator: " ")])
        do {
            _ = try await provider.renderer(itemID: id, script: script, allowGeneration: true)
            XCTFail("Second chunk should hit quota")
        } catch { XCTAssertTrue(error is GeminiSpeechError) }
        async let first = provider.renderer(itemID: id, script: script, allowGeneration: true)
        async let second = provider.renderer(itemID: id, script: script, allowGeneration: true)
        _ = try await (first, second)
        let count = await calls.value
        XCTAssertEqual(count, 3, "First chunk is retained; retry and concurrent request share only the missing chunk")
        try await provider.clearCache()
        let cleared = try await provider.renderer(itemID: id, script: script, allowGeneration: false)
        XCTAssertNil(cleared)
    }
    func testIndependentAppProvidersShareGenerationAndExportWithoutAnotherRequest() async throws {
        let data = try response(wav())
        let calls = Counter()
        let shared = directory.appendingPathComponent("shared")
        let send: (URLRequest) async throws -> (Data, URLResponse) = { request in
            await calls.increment()
            try await Task.sleep(nanoseconds: 30_000_000)
            return (data, self.http(request))
        }
        let reader = GeminiArticleSpeech(directory: shared, send: send)
        let music = GeminiArticleSpeech(directory: shared, send: send)
        let id = UUID(), script = script(["First paragraph.", "Second paragraph."])
        async let a = reader.renderer(itemID: id, script: script, allowGeneration: true)
        async let b = music.renderer(itemID: id, script: script, allowGeneration: true)
        let (_, prepared) = try await (a, b)
        let renderer = try XCTUnwrap(prepared)
        let output = directory.appendingPathComponent("music-readout.m4a")
        let duration = try await AudioScriptFileRenderer.write(script, to: output, using: renderer)
        XCTAssertGreaterThan(duration, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
        let count = await calls.value
        XCTAssertEqual(count, 1, "Independent app providers arbitrate through the shared lock and cache")
    }
    func testReaderLocalCacheMigratesWithoutKeyOrNetwork() async throws {
        let data = try response(wav())
        let legacy = directory.appendingPathComponent("legacy")
        let old = GeminiArticleSpeech(directory: legacy, send: { request in (data, self.http(request)) })
        let id = UUID(), script = script(["Existing Reader audio"])
        _ = try await old.renderer(itemID: id, script: script, allowGeneration: true)
        let updated = GeminiArticleSpeech(directory: directory.appendingPathComponent("shared"), legacyDirectory: legacy,
            apiKey: { nil }, send: { _ in XCTFail("Migration should reuse generated audio"); throw GeminiSpeechError.unavailable })
        let migrated = try await updated.renderer(itemID: id, script: script, allowGeneration: false)
        XCTAssertNotNil(migrated)
        let oldCache = try await old.renderer(itemID: id, script: script, allowGeneration: false)
        XCTAssertNil(oldCache)
        try await updated.clearCache()
        let cleared = try await updated.renderer(itemID: id, script: script, allowGeneration: false)
        XCTAssertNil(cleared)
    }

    func testGenerationDeadlineCancelsSlowRequestAndAllowsRetry() async throws {
        let data = try response(wav())
        let calls = Counter()
        let provider = GeminiArticleSpeech(directory: directory.appendingPathComponent("cache"), requestTimeout: 0.03, send: { request in
            if await calls.increment() == 1 { try await Task.sleep(nanoseconds: 5_000_000_000) }
            return (data, self.http(request))
        })
        let id = UUID(), script = script(["Article"])
        let started = Date()
        do {
            _ = try await provider.renderer(itemID: id, script: script, allowGeneration: true)
            XCTFail("Slow request should time out")
        } catch {
            XCTAssertEqual((error as? GeminiSpeechError)?.errorDescription, GeminiSpeechError.timedOut.errorDescription)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
        let retried = try await provider.renderer(itemID: id, script: script, allowGeneration: true)
        XCTAssertNotNil(retried)
    }
    func testProgressiveReaderCanPlayFirstSectionBeforeFullArticleIsReady() async throws {
        let data = try response(wav())
        let calls = Counter(), completed = Counter()
        let provider = GeminiArticleSpeech(directory: directory.appendingPathComponent("cache"), send: { request in
            let count = await calls.increment()
            if count == 2 { try await Task.sleep(nanoseconds: 400_000_000) }
            await completed.increment()
            return (data, self.http(request))
        })
        let text = Array(repeating: "word", count: 1_200).joined(separator: " ")
        let script = script([text, "Second section."])
        let result = try await provider.renderer(itemID: UUID(), script: script, allowGeneration: true, startBeforeCompletion: true)
        let renderer = try XCTUnwrap(result)
        let first = try await renderer.render(script.spokenBlocks[0])
        XCTAssertGreaterThan(first.duration, 0)
        let completedBeforePlayback = await completed.value
        XCTAssertEqual(completedBeforePlayback, 1, "Reader should not wait for the whole article")
        let second = try await renderer.render(script.spokenBlocks[1])
        XCTAssertGreaterThan(second.duration, 0)
        let completedAfterPlayback = await completed.value
        XCTAssertEqual(completedAfterPlayback, 2)
    }
    func testCancellingInitialGenerationStopsRequestAndDoesNotPoisonRetry() async throws {
        let data = try response(wav())
        let calls = Counter()
        let provider = GeminiArticleSpeech(directory: directory.appendingPathComponent("cache"), send: { request in
            if await calls.increment() == 1 { try await Task.sleep(nanoseconds: 5_000_000_000) }
            return (data, self.http(request))
        })
        let id = UUID(), script = script(["Article"])
        let operation = Task { try await provider.renderer(itemID: id, script: script, allowGeneration: true, startBeforeCompletion: true) }
        while await calls.value == 0 { await Task.yield() }
        operation.cancel()
        do { _ = try await operation.value; XCTFail("Expected cancellation") } catch { XCTAssertTrue(error is CancellationError) }
        let retried = try await provider.renderer(itemID: id, script: script, allowGeneration: true)
        XCTAssertNotNil(retried)
    }

    func testRemovingArticleRemovesItsAudio() async throws {
        let data = try response(wav())
        let provider = GeminiArticleSpeech(directory: directory.appendingPathComponent("cache"), send: { request in (data, self.http(request)) })
        let id = UUID()
        let script = script(["Article"])
        _ = try await provider.renderer(itemID: id, script: script, allowGeneration: true)
        try await provider.removeAudio(except: [])
        let cached = try await provider.renderer(itemID: id, script: script, allowGeneration: false)
        XCTAssertNil(cached)
    }
}

private actor Counter {
    private(set) var value = 0
    @discardableResult func increment() -> Int { value += 1; return value }
}
