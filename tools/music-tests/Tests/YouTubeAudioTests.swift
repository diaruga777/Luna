import XCTest
import LunaMusicFiles
@testable import LunaVaultMacPeer

final class YouTubeAudioTests: XCTestCase {
    private let video = "cwAkcsg7NCg"
    func testSharingWatchShortsEmbedAndLiveLinksCanonicalize() {
        for input in [
            "https://youtu.be/cwAkcsg7NCg?si=PuFEYt2h0NdKCjUa",
            "https://www.youtube.com/watch?v=cwAkcsg7NCg&list=abc&t=42",
            "https://m.youtube.com/watch?v=cwAkcsg7NCg&feature=shared",
            "https://music.youtube.com/watch?v=cwAkcsg7NCg",
            "https://www.youtube.com/shorts/cwAkcsg7NCg?feature=share",
            "https://www.youtube.com/embed/cwAkcsg7NCg",
            "https://youtube.com/live/cwAkcsg7NCg?si=abc"
        ] { XCTAssertEqual(YouTubeAudioURL.videoID(input), video, input) }
        for input in ["https://youtube.com.evil.test/watch?v=cwAkcsg7NCg", "file:///tmp/cwAkcsg7NCg",
                      "https://youtu.be/../../etc/passwd", "https://youtube.com/playlist?list=abc", "--exec touch /tmp/test",
                      "https://evil@youtube.com/watch?v=cwAkcsg7NCg", "https://youtu.be/too-short", "https://youtu.be/cwAkcsg7NCg/extra"] {
            XCTAssertNil(YouTubeAudioURL.videoID(input), input)
        }
    }
    func testOnlyMediaRejectionsTriggerMacFallback() {
        XCTAssertTrue(YouTubeAudioFailurePolicy.shouldUseMac(YouTubeMediaRejection()))
        for code in [URLError.Code.badServerResponse, .cannotDecodeContentData] {
            XCTAssertTrue(YouTubeAudioFailurePolicy.shouldUseMac(URLError(code)))
        }
        for code in [URLError.Code.notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotFindHost,
                     .dnsLookupFailed, .cancelled, .secureConnectionFailed, .dataNotAllowed, .cannotWriteToFile] {
            XCTAssertFalse(YouTubeAudioFailurePolicy.shouldUseMac(URLError(code)), "\(code)")
        }
        XCTAssertFalse(YouTubeAudioFailurePolicy.shouldUseMac(CancellationError()))
        XCTAssertFalse(YouTubeAudioFailurePolicy.shouldUseMac(CocoaError(.fileWriteOutOfSpace)))
    }
    func testUnavailableServiceDoesNotStartJob() async {
        let service = CompanionYouTubeAudio(detector: { nil }, runner: { _ in XCTFail("Tool invoked when unavailable"); return Data() })
        let availability = await service.handle(.init(.availability))
        XCTAssertEqual(availability.available, false)
        let response = await service.handle(.init(.resolve, id: UUID().uuidString, url: YouTubeAudioURL.canonical(video).absoluteString))
        XCTAssertEqual(response.state, .failed)
    }
    func testExtractionUpdatesOnceThenRetriesAndNeverDownloads() async throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let runner = MockYouTubeTools(failures: 1)
        let service = service(root, runner: runner)
        let id = UUID().uuidString
        _ = await service.handle(.init(.resolve, id: id, url: "https://youtu.be/\(video)?si=share"))
        let result = try await poll(service, id: id, until: .resolved)
        XCTAssertEqual(result.metadata?.videoID, video)
        XCTAssertEqual(result.metadata?.headers["User-Agent"], "Test Agent")
        let calls = await runner.calls
        XCTAssertEqual(calls.filter { $0.executable.lastPathComponent == "brew" }.map(\.arguments), [["update"], ["upgrade", "yt-dlp"]])
        let extraction = calls.filter { $0.arguments.contains("--dump-single-json") }
        XCTAssertEqual(extraction.count, 2)
        XCTAssertTrue(extraction.allSatisfy { $0.arguments.contains("--skip-download") && $0.arguments.contains("--no-playlist") })
        XCTAssertFalse(calls.contains { $0.watchedFile != nil })
    }
    func testSecondFailureStopsAfterOneUpgradeAndRetry() async throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let runner = MockYouTubeTools(failures: 2), id = UUID().uuidString
        let service = service(root, runner: runner)
        _ = await service.handle(.init(.resolve, id: id, url: YouTubeAudioURL.canonical(video).absoluteString))
        let result = try await poll(service, id: id, until: .failed)
        XCTAssertNotNil(result.error)
        let calls = await runner.calls
        XCTAssertEqual(calls.filter { $0.arguments.contains("--dump-single-json") }.count, 2)
        XCTAssertEqual(calls.filter { $0.arguments == ["upgrade", "yt-dlp"] }.count, 1)
    }
    func testMacDownloadRangesReleaseAndReconnectJobLookup() async throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let runner = MockYouTubeTools(), id = UUID().uuidString
        let service = service(root, runner: runner)
        _ = await service.handle(.init(.resolve, id: id, url: YouTubeAudioURL.canonical(video).absoluteString))
        _ = try await poll(service, id: id, until: .resolved)
        _ = await service.handle(.init(.download, id: id, maximumBytes: 100))
        let ready = try await poll(service, id: id, until: .ready)
        XCTAssertEqual(ready.size, 16)
        let read = await service.handle(.init(.read, id: id, offset: 5, length: 6))
        XCTAssertEqual(read.data, Data((5..<11).map(UInt8.init)))
        let invalid = await service.handle(.init(.read, id: id, offset: 15, length: 2))
        XCTAssertEqual(invalid.state, .failed)
        _ = await service.handle(.init(.release, id: id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(id).path))
        let expired = await service.handle(.init(.status, id: id))
        XCTAssertNotNil(expired.error)
        let calls = await runner.calls
        XCTAssertEqual(calls.filter { $0.watchedFile != nil }.count, 1)
    }
    func testRejectsUnsafeJobIDsAndFormatMetadata() async throws {
        let runner = MockYouTubeTools(), root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let service = service(root, runner: runner)
        for id in ["../outside", "/tmp/audio", ""] {
            let reply = await service.handle(.init(.resolve, id: id, url: YouTubeAudioURL.canonical(video).absoluteString))
            XCTAssertNotNil(reply.error)
        }
        var json = MockYouTubeTools.json
        json["vcodec"] = "h264"
        XCTAssertThrowsError(try CompanionYouTubeAudio.metadata(JSONSerialization.data(withJSONObject: json), video: video))
        json = MockYouTubeTools.json; json["url"] = "file:///tmp/audio"
        XCTAssertThrowsError(try CompanionYouTubeAudio.metadata(JSONSerialization.data(withJSONObject: json), video: video))
        json = MockYouTubeTools.json; json["http_headers"] = ["Bad\nHeader": "value", "Host": "evil", "User-Agent": "Good"]
        let safe = try CompanionYouTubeAudio.metadata(JSONSerialization.data(withJSONObject: json), video: video)
        XCTAssertEqual(safe.headers, ["User-Agent": "Good"])
    }
    func testCommandRunnerReturnsOutputAndStopsOnTimeoutOrCancellation() async throws {
        let bin = URL(fileURLWithPath: "/usr/bin")
        let output = try await CompanionYouTubeAudio.run(.init(executable: bin.appendingPathComponent("printf"), arguments: ["%s", "safe output"], bin: bin))
        XCTAssertEqual(String(data: output, encoding: .utf8), "safe output")
        let started = Date()
        do {
            _ = try await CompanionYouTubeAudio.run(.init(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["5"], bin: bin, timeout: 0.05))
            XCTFail("Expected process timeout")
        } catch { XCTAssertLessThan(Date().timeIntervalSince(started), 3) }
        let task = Task { try await CompanionYouTubeAudio.run(.init(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["5"], bin: bin)) }
        try await Task.sleep(for: .milliseconds(50)); task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch is CancellationError { }
    }
    private func service(_ root: URL, runner: MockYouTubeTools) -> CompanionYouTubeAudio {
        CompanionYouTubeAudio(cacheDirectory: root, detector: {
            .init(brew: URL(fileURLWithPath: "/fake/brew"), ytDLP: URL(fileURLWithPath: "/fake/yt-dlp"), bin: URL(fileURLWithPath: "/fake"))
        }, runner: { try await runner.run($0) })
    }
    private func poll(_ service: CompanionYouTubeAudio, id: String, until state: YouTubeAudioResponse.State) async throws -> YouTubeAudioResponse {
        for _ in 0..<300 {
            let response = await service.handle(.init(.status, id: id))
            if response.state == state { return response }
            if response.state == .failed { throw MusicFileError(response.error ?? "Unexpected failure") }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw URLError(.timedOut)
    }
    private func temporary() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("YouTubeTests-" + UUID().uuidString) }
}

private actor MockYouTubeTools {
    static var json: [String: Any] { ["id": "cwAkcsg7NCg", "title": "Test Audio", "channel": "Test Channel", "duration": 10,
        "vcodec": "none", "ext": "m4a", "protocol": "https", "url": "https://audio.googlevideo.com/audio?expire=123",
        "http_headers": ["User-Agent": "Test Agent"]] }
    var calls: [CompanionYouTubeAudio.Command] = []
    var failures: Int
    init(failures: Int = 0) { self.failures = failures }
    func run(_ command: CompanionYouTubeAudio.Command) throws -> Data {
        calls.append(command)
        if command.arguments.contains("--dump-single-json") {
            if failures > 0 { failures -= 1; throw MusicFileError("Extraction failed") }
            return try JSONSerialization.data(withJSONObject: Self.json)
        }
        if let file = command.watchedFile { try Data((0..<16).map(UInt8.init)).write(to: file) }
        return Data()
    }
}
