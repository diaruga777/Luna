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
    private func article(words: Int) -> String {
        (0..<words).map { ($0 % 20 == 0 ? "Word" : "word") + ($0 % 20 == 19 || $0 == words - 1 ? "." : "") }.joined(separator: " ")
    }
    private func transcript(_ request: URLRequest) throws -> String {
        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        let input = body["input"] as! [[String: Any]]
        let content = input[0]["content"] as! [[String: Any]]
        return content[0]["text"] as! String
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

    func testNightlyQuotaDoesNotFallBackOrRetryAnotherModel() async throws {
        let clock = ISO8601DateFormatter().date(from: "2026-07-01T07:30:00Z")!
        let calls = Counter()
        let provider = GeminiArticleSpeech(directory: directory, now: { clock }, send: { request in
            await calls.increment()
            return (Data(), self.http(request, status: 429))
        })
        do {
            try await provider.cacheForNightlyReadout(itemID: UUID(), script: script(["Article"]),
                                                      deadline: NightlyArticleAudioWindow.deadline(at: clock)!)
            XCTFail("Quota must stop nightly work")
        } catch { XCTAssertEqual(error as? GeminiSpeechError, .quota) }
        let count = await calls.value
        XCTAssertEqual(count, 1)
    }

    func testNightlyRejectsLateLaunchAndCrossingMidnightBeforePublishing() async throws {
        var clock = ISO8601DateFormatter().date(from: "2026-07-01T07:59:59Z")!
        let deadline = NightlyArticleAudioWindow.deadline(at: clock)!
        let data = try response(wav())
        let calls = Counter()
        let provider = GeminiArticleSpeech(directory: directory.appendingPathComponent("cache"), now: { clock }, send: { request in
            await calls.increment()
            XCTAssertLessThanOrEqual(request.timeoutInterval, 1)
            clock = deadline
            return (data, self.http(request))
        })
        let id = UUID(), script = script(["Article"])
        do {
            try await provider.cacheForNightlyReadout(itemID: id, script: script, deadline: deadline)
            XCTFail("Cannot publish after midnight")
        } catch { XCTAssertTrue(error is CancellationError) }
        let cache = try await provider.renderer(itemID: id, script: script, allowGeneration: false)
        XCTAssertNil(cache)
        do {
            try await provider.cacheForNightlyReadout(itemID: UUID(), script: script, deadline: deadline)
            XCTFail("Cannot start at midnight")
        } catch { XCTAssertTrue(error is CancellationError) }
        let count = await calls.value
        XCTAssertEqual(count, 1)
    }

    func testRetentionUsesGenerationAgeAndReadStateIncludingLegacyAndPartialAudio() async throws {
        let now = Date()
        let day: TimeInterval = 86_400
        let unread = SavedItem(seed: "unread", urlString: "https://example.com/1", title: nil, dateAdded: now)
        let read = SavedItem(seed: "read", urlString: "https://example.com/2", title: nil, dateAdded: now, readState: .read)
        let removed = UUID()
        let cacheRoot = directory.appendingPathComponent("cache")
        let legacy = directory.appendingPathComponent("legacy")
        func chunk(_ root: URL, id: UUID, name: String, age: TimeInterval) throws -> URL {
            let folder = root.appendingPathComponent(id.uuidString).appendingPathComponent("fingerprint")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent(name + ".m4a")
            try Data("cache".utf8).write(to: file)
            try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-age)], ofItemAtPath: file.path)
            return file
        }
        for root in [cacheRoot, legacy] {
            let freshUnread = try chunk(root, id: unread.id, name: "0", age: 14 * day - 1)
            let expiredUnread = try chunk(root, id: unread.id, name: "1", age: 14 * day)
            let freshRead = try chunk(root, id: read.id, name: "0", age: 2 * day - 1)
            let expiredRead = try chunk(root, id: read.id, name: "1", age: 2 * day)
            let deleted = try chunk(root, id: removed, name: "0", age: 0)
            let provider = GeminiArticleSpeech(directory: cacheRoot, legacyDirectory: legacy, send: { _ in
                XCTFail("Retention never uses network")
                throw GeminiSpeechError.unavailable
            })
            try await provider.pruneAudio(for: [unread, read], now: now)
            XCTAssertTrue(FileManager.default.fileExists(atPath: freshUnread.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: freshRead.path))
            for file in [expiredUnread, expiredRead, deleted] { XCTAssertFalse(FileManager.default.fileExists(atPath: file.path)) }
            // Becoming read shortens retention without extending the generation clock.
            var finished = unread
            finished.readState = .read
            try await provider.pruneAudio(for: [finished, read], now: now)
            XCTAssertFalse(FileManager.default.fileExists(atPath: freshUnread.path))
        }
    }

    func testChunkingPreservesTextAndBoundsEnglishAndUnspacedText() {
        for text in [article(words: 2_100), String(repeating: "新聞記事です。", count: 1_000)] {
            let plan = GeminiSpeechPlan(script: script([text]))
            XCTAssertEqual(plan.chunks.joined(), text)
            XCTAssertTrue(plan.chunks.allSatisfy { $0.utf8.count <= 7_500 })
            XCTAssertTrue(plan.chunks.allSatisfy { AudioWordIndexing.wordCount(in: $0) <= 1_200 })
        }
    }
    func testTypicalArticleRequestCountsAndCacheIdentity() {
        for (words, expected) in [(600, 1), (800, 1), (1_000, 1), (1_200, 1), (1_800, 2), (2_400, 2)] {
            XCTAssertEqual(GeminiSpeechPlan(script: script([article(words: words)])).chunks.count, expected)
        }
        XCTAssertNotEqual(GeminiSpeechPlan(script: script(["old"])).fingerprint, GeminiSpeechPlan(script: script(["new"])).fingerprint)
        XCTAssertNotEqual(GeminiSpeechPlan(script: script(["one", "two"])).fingerprint, GeminiSpeechPlan(script: script(["one\n\ntwo"])).fingerprint)
    }

    func testSentenceChunksHaveContiguousDisjointRangesAndNeverRepeatContext() {
        let sentences = (0..<180).map { "Sentence \($0) has its own unique words, including a comma and a finish." }
        let text = sentences.joined(separator: " ")
        let plan = GeminiSpeechPlan(script: script([text]))
        XCTAssertGreaterThan(plan.chunks.count, 1)
        XCTAssertEqual(plan.chunks.joined(), text)
        var offset = 0
        for (chunk, range) in zip(plan.chunks, plan.chunkRanges) {
            XCTAssertEqual(range.location, offset)
            XCTAssertEqual((text as NSString).substring(with: range), chunk)
            XCTAssertTrue(chunk.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("finish."))
            offset = NSMaxRange(range)
        }
        XCTAssertEqual(offset, text.utf16.count)
        for sentence in sentences { XCTAssertEqual(plan.chunks.filter { $0.contains(sentence) }.count, 1) }
    }

    func testSentenceTokenizerHandlesAbbreviationsQuotesAndUnspacedScripts() {
        for text in ["Dr. Smith paid $3.14. He said, “Yes!” Then he left.", "最初の文です。次の文です！最後の文です？", "Hello 👨‍👩‍👧‍👦. Café! Done?"] {
            let ranges = GeminiSpeechSentences.ranges(in: text)
            let chunks = GeminiSpeechSentences.chunks(in: text, sentences: ranges, maxBytes: 1, maxWords: 1)
            XCTAssertEqual(chunks, ranges, "Even a small target must preserve whole sentences")
            XCTAssertEqual(chunks.map { (text as NSString).substring(with: $0) }.joined(), text)
            if text.hasPrefix("Dr.") { XCTAssertEqual((text as NSString).substring(with: chunks[0]).trimmingCharacters(in: .whitespaces), "Dr. Smith paid $3.14.") }
        }
        let unbroken = String(repeating: "長", count: 4_000) + "。"
        XCTAssertEqual(GeminiSpeechPlan(script: script([unbroken])).chunks, [unbroken], "An oversized sentence must never be split mid-sentence")
    }

    func testAlignmentUsesOnlyAnExactConfirmedSentencePrefix() {
        let text = "First sentence. Second sentence. Third sentence."
        let spans: [GeminiSpeechAlignment.Span] = [
            .init(text: "First", start: 0, end: 0.4), .init(text: "sentence.", start: 0.4, end: 1),
            .init(text: "Second", start: 1.2, end: 1.5), .init(text: "wrong.", start: 1.5, end: 2)
        ]
        let boundaries = GeminiSpeechAlignment.boundaries(text: text, spans: spans, frames: 72_000)
        XCTAssertEqual(boundaries, [.init(textEnd: "First sentence. ".utf16.count, frames: 24_000)])
        XCTAssertTrue(GeminiSpeechAlignment.boundaries(text: text, spans: [.init(text: "Second sentence.", start: 0, end: 1)], frames: 72_000).isEmpty, "A repeated phrase later in the input cannot skip the beginning")
        XCTAssertTrue(GeminiSpeechAlignment.boundaries(text: text, spans: [.init(text: "First sentence. Second", start: 0, end: 1)], frames: 72_000).isEmpty, "Do not interpolate a sentence boundary within a timed run")
        XCTAssertTrue(GeminiSpeechAlignment.boundaries(text: text, spans: Array(spans.prefix(2)), frames: 24_000).isEmpty, "A clipped stream ending on the last word is not a safe checkpoint")
    }

    func testInterruptedPCMResumesAtSentenceAndSurvivesRepeatedFailuresAndNewProviders() async throws {
        let cache = directory.appendingPathComponent("cache")
        let id = UUID(), script = script(["First sentence. Second sentence. Third sentence."])
        let requested = RequestedModels()
        let recognize: GeminiSpeechAlignment.Recognize = { url, text in
            XCTAssertGreaterThan(try AVAudioFile(forReading: url).length, 24_000)
            let word = text.hasPrefix("First") ? "First" : "Second"
            return [.init(text: word, start: 0, end: 0.4), .init(text: "sentence.", start: 0.4, end: 1),
                    .init(text: "unfinished", start: 1.2, end: 1.5)]
        }
        for failure in 0..<2 {
            let provider = GeminiArticleSpeech(directory: cache, recognize: recognize, stream: { request, receive in
                requested.append(try self.transcript(request))
                try receive(Data(repeating: 0, count: failure == 0 ? 144_001 : 96_000))
                if failure == 0 { throw URLError(.networkConnectionLost) }
                throw GeminiSpeechError.quota
            })
            do { _ = try await provider.renderer(itemID: id, script: script, allowGeneration: true); XCTFail("Expected interrupted stream") }
            catch {}
            let folder = cache.appendingPathComponent(id.uuidString).appendingPathComponent(GeminiSpeechPlan(script: script).fingerprint)
            XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("0.partial.pcm").path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("0.m4a").path))
            let offline = try await provider.renderer(itemID: id, script: script, allowGeneration: false)
            XCTAssertNil(offline, "An interrupted stream must never masquerade as a complete readout")
        }
        let retry = GeminiArticleSpeech(directory: cache, recognize: recognize, stream: { request, receive in
            requested.append(try self.transcript(request))
            try receive(Data(repeating: 0, count: 48_000))
            return self.http(request)
        })
        let result = try await retry.renderer(itemID: id, script: script, allowGeneration: true)
        let renderer = try XCTUnwrap(result)
        let segment = try await renderer.render(script.spokenBlocks[0])
        XCTAssertEqual(segment.buffers.reduce(0) { $0 + Int($1.frameLength) }, 72_000, "Each retained sentence and the regenerated suffix occur exactly once")
        XCTAssertEqual(requested.values, ["First sentence. Second sentence. Third sentence.", "Second sentence. Third sentence.", "Third sentence."])
        let folder = cache.appendingPathComponent(id.uuidString).appendingPathComponent(GeminiSpeechPlan(script: script).fingerprint)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("0.partial.pcm").path))
    }

    func testCompletedChunksSurviveNetworkFailuresAndMissingAlignmentDoesNotSkipText() async throws {
        let cache = directory.appendingPathComponent("cache")
        let texts = [article(words: 1_200), "Second sentence. Third sentence."]
        let script = script(texts), id = UUID(), requested = RequestedModels(), calls = Counter()
        let provider = GeminiArticleSpeech(directory: cache, recognize: { _, _ in [] }, stream: { request, receive in
            let count = await calls.increment()
            requested.append(try self.transcript(request))
            try receive(Data(repeating: 0, count: 48_000))
            if count == 2 { throw URLError(.notConnectedToInternet) }
            return self.http(request)
        })
        do { _ = try await provider.renderer(itemID: id, script: script, allowGeneration: true); XCTFail("Expected failure") } catch {}
        let retry = GeminiArticleSpeech(directory: cache, recognize: { _, _ in throw GeminiSpeechError.unavailable }, stream: { request, receive in
            requested.append(try self.transcript(request))
            try receive(Data(repeating: 0, count: 48_000))
            return self.http(request)
        })
        _ = try await retry.renderer(itemID: id, script: script, allowGeneration: true)
        let plan = GeminiSpeechPlan(script: script)
        XCTAssertEqual(requested.values, [plan.chunks[0], plan.chunks[1], plan.chunks[1]], "A retry regenerates only the failed chunk when no timing can certify its prefix")
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
        var key = "first-key"
        let provider = GeminiArticleSpeech(directory: directory.appendingPathComponent("cache"), apiKey: { key }, send: { request in
            let count = await calls.increment()
            try await Task.sleep(nanoseconds: 20_000_000)
            return (data, self.http(request, status: (2...4).contains(count) ? 429 : 200))
        })
        let id = UUID()
        let script = script([article(words: 1_500)])
        do {
            _ = try await provider.renderer(itemID: id, script: script, allowGeneration: true)
            XCTFail("Second chunk should hit quota")
        } catch { XCTAssertTrue(error is GeminiSpeechError) }
        key = "replacement-key"
        async let first = provider.renderer(itemID: id, script: script, allowGeneration: true)
        async let second = provider.renderer(itemID: id, script: script, allowGeneration: true)
        _ = try await (first, second)
        let count = await calls.value
        XCTAssertEqual(count, 5, "All models exhaust quota; retry shares only the missing chunk")
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
        let text = article(words: 1_200)
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

    func testStreamingPlaysBeforeRequestCompletesAndNeverDuplicatesFrames() async throws {
        let finished = Counter()
        let pcm = Data(repeating: 0, count: 96_000)
        let values = ProgressValues()
        let provider = GeminiArticleSpeech(directory: directory.appendingPathComponent("cache"), stream: { request, receive in
            try receive(Data(pcm.prefix(24_001))) // Split an Int16 sample across deltas.
            try await Task.sleep(nanoseconds: 300_000_000)
            try receive(Data(pcm.dropFirst(24_001)))
            await finished.increment()
            return self.http(request)
        })
        let id = UUID(), script = script(["First paragraph", "Second paragraph"])
        let prepared = try await provider.renderer(itemID: id, script: script, allowGeneration: true, progress: { values.append($0) }, startBeforeCompletion: true)
        let renderer = try XCTUnwrap(prepared as? ProgressiveSpeechRendering)
        let session = UUID()
        let first = try await renderer.nextSegment(startingAt: script.spokenBlocks[0], sessionID: session)
        XCTAssertGreaterThan(try XCTUnwrap(first).duration, 0)
        let finishedAtFirstAudio = await finished.value
        XCTAssertEqual(finishedAtFirstAudio, 0, "A full text chunk must not gate first audio")
        let joinedProgress = ProgressValues()
        _ = try await provider.renderer(itemID: id, script: script, allowGeneration: true, progress: { joinedProgress.append($0) }, startBeforeCompletion: true)
        var frames = first!.buffers.reduce(0) { $0 + Int($1.frameLength) }
        while let segment = try await renderer.nextSegment(startingAt: script.spokenBlocks[0], sessionID: session) {
            frames += segment.buffers.reduce(0) { $0 + Int($1.frameLength) }
        }
        XCTAssertEqual(frames, 48_000)
        XCTAssertTrue(values.values.contains { $0 > 0 && $0 < 1 })
        XCTAssertEqual(values.values.last, 1)
        XCTAssertEqual(values.values, values.values.sorted())
        XCTAssertTrue(joinedProgress.values.contains { $0 > 0 && $0 < 1 }, "Joining a job receives incremental progress too")
        XCTAssertEqual(joinedProgress.values.last, 1)
        let cachedResult = try await provider.renderer(itemID: id, script: script, allowGeneration: false)
        let cached = try XCTUnwrap(cachedResult)
        var cachedFrames = 0
        for block in script.spokenBlocks { cachedFrames += try await cached.render(block).buffers.reduce(0) { $0 + Int($1.frameLength) } }
        XCTAssertEqual(cachedFrames, frames)
    }

    func testPartialStreamFailureDoesNotPublishCacheOrFallbackAfterAudio() async throws {
        let calls = Counter()
        let provider = GeminiArticleSpeech(directory: directory.appendingPathComponent("cache"), stream: { request, receive in
            await calls.increment()
            try receive(Data(repeating: 0, count: 48_000))
            try await Task.sleep(nanoseconds: 100_000_000)
            throw GeminiSpeechError.quota
        })
        let id = UUID(), script = script(["Article"])
        let result = try await provider.renderer(itemID: id, script: script, allowGeneration: true, startBeforeCompletion: true)
        let renderer = try XCTUnwrap(result as? ProgressiveSpeechRendering)
        let token = UUID()
        _ = try await renderer.nextSegment(startingAt: script.spokenBlocks[0], sessionID: token)
        do {
            while try await renderer.nextSegment(startingAt: script.spokenBlocks[0], sessionID: token) != nil {}
            XCTFail("Partial stream must fail")
        } catch { XCTAssertEqual(error as? GeminiSpeechError, .quota) }
        let cached = try await provider.renderer(itemID: id, script: script, allowGeneration: false)
        XCTAssertNil(cached)
        let count = await calls.value
        XCTAssertEqual(count, 1, "Fallback after audio could repeat spoken words")
    }

    func testRetryPlaybackRoundsAudibleFrameBackToSentenceWithoutReplayingPrefix() async throws {
        let cache = directory.appendingPathComponent("cache"), id = UUID()
        let script = script(["First sentence. Second sentence. Third sentence."])
        func pcm(_ sample: Int16, frames: Int) -> Data {
            var value = sample.littleEndian
            return withUnsafeBytes(of: &value) { Data(Array(repeating: Array($0), count: frames).joined()) }
        }
        let raw = pcm(8_192, frames: 24_000) + pcm(16_384, frames: 24_000) + pcm(-8_192, frames: 24_000)
        let recognize: GeminiSpeechAlignment.Recognize = { _, _ in
            [.init(text: "First sentence.", start: 0, end: 1), .init(text: "Second sentence.", start: 1.1, end: 2),
             .init(text: "Third", start: 2.2, end: 2.5)]
        }
        let original = GeminiArticleSpeech(directory: cache, recognize: recognize, stream: { _, receive in
            try receive(raw)
            try await Task.sleep(nanoseconds: 200_000_000)
            throw URLError(.networkConnectionLost)
        })
        let first = try await original.renderer(itemID: id, script: script, allowGeneration: true, startBeforeCompletion: true)
        let stream = try XCTUnwrap(first as? ProgressiveSpeechRendering), token = UUID()
        for _ in 0..<2 { _ = try await stream.nextSegment(startingAt: script.spokenBlocks[0], sessionID: token) }
        let position = await stream.position(afterPlaying: 1.5)
        XCTAssertEqual(position, .init(chunk: 0, frame: 36_000), "Use the audible playhead, not the prefetched frontier")
        do {
            while try await stream.nextSegment(startingAt: script.spokenBlocks[0], sessionID: token) != nil {}
            XCTFail("Expected network failure")
        } catch {}
        let retry = GeminiArticleSpeech(directory: cache, recognize: recognize, stream: { request, receive in
            XCTAssertEqual(try self.transcript(request), "Third sentence.")
            try receive(pcm(24_576, frames: 24_000))
            return self.http(request)
        })
        let retried = try await retry.renderer(itemID: id, script: script, allowGeneration: true, startBeforeCompletion: true)
        let renderer = try XCTUnwrap(retried as? ProgressiveSpeechRendering)
        await renderer.resume(from: try XCTUnwrap(position))
        let newToken = UUID()
        let resumed = try await renderer.nextSegment(startingAt: script.spokenBlocks[0], sessionID: newToken)
        XCTAssertEqual(try XCTUnwrap(resumed?.buffers.first?.floatChannelData?[0][0]), 0.5, accuracy: 0.01, "Resume at the second sentence, with no first-sentence overlap")
        var frames = resumed!.buffers.reduce(0) { $0 + Int($1.frameLength) }
        while let next = try await renderer.nextSegment(startingAt: script.spokenBlocks[0], sessionID: newToken) {
            frames += next.buffers.reduce(0) { $0 + Int($1.frameLength) }
        }
        XCTAssertEqual(frames, 48_000, "Replay only the interrupted sentence and the new suffix")
    }

    func testCancellationAndDeadlineKeepDurableStreamedPCM() async throws {
        for cancel in [true, false] {
            let cache = directory.appendingPathComponent(UUID().uuidString), calls = Counter()
            let script = script(["First sentence. Second sentence."]), id = UUID()
            let provider = GeminiArticleSpeech(directory: cache, requestTimeout: cancel ? 10 : 0.05,
                recognize: { _, _ in [] }, stream: { _, receive in
                    try receive(Data(repeating: 0, count: 96_001))
                    await calls.increment()
                    try await Task.sleep(nanoseconds: 5_000_000_000)
                    throw GeminiSpeechError.incomplete
                })
            let task = Task { try await provider.renderer(itemID: id, script: script, allowGeneration: true) }
            while await calls.value == 0 { await Task.yield() }
            if cancel { task.cancel() }
            do { _ = try await task.value; XCTFail("Expected interruption") } catch {}
            let folder = cache.appendingPathComponent(id.uuidString).appendingPathComponent(GeminiSpeechPlan(script: script).fingerprint)
            XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("0.partial.pcm")).count, 96_001)
            let retry = GeminiArticleSpeech(directory: cache, recognize: { _, _ in [.init(text: "First sentence.", start: 0, end: 1)] }, stream: { request, receive in
                XCTAssertEqual(try self.transcript(request), "Second sentence.")
                try receive(Data(repeating: 0, count: 48_000))
                return self.http(request)
            })
            _ = try await retry.renderer(itemID: id, script: script, allowGeneration: true)
        }
    }

    func testSSEReplayedEventIDDoesNotDuplicatePCMButEqualNewAudioDoes() throws {
        var parser = GeminiSpeechEvents(), received = Data()
        func event(_ id: String, audio: Data = Data([0, 1])) throws {
            let json = try JSONSerialization.data(withJSONObject: ["event_id": id, "event_type": "step.delta", "delta": ["type": "audio", "data": audio.base64EncodedString()]], options: .sortedKeys)
            try parser.line("data: " + String(decoding: json, as: UTF8.self), receive: { received.append($0) })
            try parser.line("", receive: { received.append($0) })
        }
        try event("first"); try event("first"); try event("second")
        XCTAssertEqual(received, Data([0, 1, 0, 1]), "Only the repeated ID is a duplicate; identical audio in a new event is legitimate")
        XCTAssertThrowsError(try event("first", audio: Data([2, 3])))
    }

    func testQuotaFallbackUsesRankOrderAndKeepsModelForLaterChunksAndArticles() async throws {
        let requested = RequestedModels()
        let provider = GeminiArticleSpeech(directory: directory.appendingPathComponent("cache"), stream: { request, receive in
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            let model = body["model"] as? String ?? GeminiArticleSpeech.models[2]
            requested.append(model)
            if model != GeminiArticleSpeech.models[2] { throw GeminiSpeechError.quota }
            XCTAssertTrue(request.url!.path.hasSuffix(":generateContent"))
            XCTAssertNil(body["stream"], "2.5 must use unary generation")
            try receive(Data(repeating: 0, count: 48_000))
            return self.http(request)
        })
        let long = script([article(words: 2_500)])
        _ = try await provider.renderer(itemID: UUID(), script: long, allowGeneration: true)
        _ = try await provider.renderer(itemID: UUID(), script: script(["Another article"]), allowGeneration: true)
        XCTAssertEqual(requested.values, [GeminiArticleSpeech.models[0], GeminiArticleSpeech.models[1]] + Array(repeating: GeminiArticleSpeech.models[2], count: 4))
    }

    func testAuthenticationAndNetworkFailuresDoNotSpendAnotherModelsQuota() async throws {
        for failure in [GeminiSpeechError.unauthorized, .permissionDenied, .unavailable, .invalidAudio] {
            let calls = Counter()
            let provider = GeminiArticleSpeech(directory: directory.appendingPathComponent(UUID().uuidString), stream: { _, _ in
                await calls.increment(); throw failure
            })
            do { _ = try await provider.renderer(itemID: UUID(), script: script(["Article"]), allowGeneration: true); XCTFail("Expected failure") }
            catch { XCTAssertEqual(error as? GeminiSpeechError, failure) }
            let count = await calls.value; XCTAssertEqual(count, 1)
        }
    }

    func testSSERequiresCompletionAndRejectsMalformedAndUnsupportedAudio() throws {
        func event(_ object: [String: Any]) throws -> String { String(data: try JSONSerialization.data(withJSONObject: object), encoding: .utf8)! }
        let audio = try event(["event_type": "step.delta", "delta": ["type": "audio", "mime_type": "audio/l16", "data": Data([0, 1]).base64EncodedString()]])
        let done = try event(["event_type": "interaction.completed", "interaction": ["status": "completed"]])
        var parser = GeminiSpeechEvents(), received = Data()
        try parser.line(": heartbeat", receive: { received.append($0) })
        try parser.line("event: step.delta", receive: { received.append($0) })
        try parser.line("data: " + audio, receive: { received.append($0) })
        try parser.line("", receive: { received.append($0) })
        XCTAssertEqual(received, Data([0, 1]))
        XCTAssertThrowsError(try parser.finish(receive: { _ in }))
        try parser.line("data: " + done, receive: { _ in })
        try parser.finish(receive: { _ in }) // Last event need not end with a blank line.
        for bad in ["{}", "not JSON", try event(["event_type": "step.delta", "delta": ["type": "audio", "data": "bad-base64"]]),
                    try event(["event_type": "step.delta", "delta": ["type": "audio", "mime_type": "audio/wav", "data": "AAE="]]),
                    try event(["event_type": "interaction.completed", "interaction": ["status": "incomplete"]])] {
            var parser = GeminiSpeechEvents()
            try parser.line("data: " + bad, receive: { _ in })
            XCTAssertThrowsError(try parser.finish(receive: { _ in }))
        }
        var failed = GeminiSpeechEvents()
        try failed.line("data: " + event(["event_type": "error", "error": ["code": "resource_exhausted"]]), receive: { _ in })
        XCTAssertThrowsError(try failed.finish(receive: { _ in })) { XCTAssertEqual($0 as? GeminiSpeechError, .quota) }
    }

    func testQuotaCooldownHonorsRetryAndPacificDayReset() throws {
        let now = ISO8601DateFormatter().date(from: "2026-10-28T23:30:00Z")!
        let retry = HTTPURLResponse(url: URL(string: "https://example.com")!, statusCode: 429, httpVersion: nil, headerFields: ["Retry-After": "12"])!
        XCTAssertEqual(GeminiSpeechModelAvailability.retryDate(body: Data(), response: retry, now: now), now.addingTimeInterval(12))
        let daily = try JSONSerialization.data(withJSONObject: ["error": ["details": [["violations": [["quotaMetric": "generate_content_free_tier_requests_per_day"]]]]]])
        XCTAssertEqual(GeminiSpeechModelAvailability.retryDate(body: daily, response: retry, now: now), ISO8601DateFormatter().date(from: "2026-10-29T07:00:00Z"))
        let dailyID = try JSONSerialization.data(withJSONObject: ["error": ["details": [["violations": [["quotaMetric": "generate_content_free_tier_requests", "quotaId": "GenerateRequestsPerDayPerProjectPerModel-FreeTier"]]]]]])
        XCTAssertEqual(GeminiSpeechModelAvailability.retryDate(body: dailyID, response: retry, now: now), ISO8601DateFormatter().date(from: "2026-10-29T07:00:00Z"))
        let available = GeminiSpeechModelAvailability()
        available.suspend("model", credential: "a", until: now.addingTimeInterval(12))
        XCTAssertFalse(available.available("model", credential: "a", now: now))
        XCTAssertTrue(available.available("model", credential: "b", now: now))
        XCTAssertTrue(available.available("model", credential: "a", now: now.addingTimeInterval(13)))
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

private final class ProgressValues: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Double] = []
    var values: [Double] { lock.lock(); defer { lock.unlock() }; return storage }
    func append(_ value: Double) { lock.lock(); storage.append(value); lock.unlock() }
}
private final class RequestedModels: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    var values: [String] { lock.lock(); defer { lock.unlock() }; return storage }
    func append(_ value: String) { lock.lock(); storage.append(value); lock.unlock() }
}
