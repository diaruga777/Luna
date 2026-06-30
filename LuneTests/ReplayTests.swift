//
//  ReplayTests.swift
//  LuneTests
//

import LuneReaderUI
import LuneStorage
import LunePaywallBypass
import LuneModels
import XCTest
@testable import Lune

final class ReplayTests: XCTestCase {

    // MARK: - Encode / decode round-trip

    /// A replay with one of every event kind round-trips through JSON unchanged,
    /// including the internally-tagged `EventKind` discriminator and bodies.
    func testReplayRoundTripsThroughJSON() throws {
        let content = ArticleContent(
            title: "Hello", author: "A. Writer",
            blocks: [ArticleContent.Block(kind: .paragraph, text: "Body text.", links: [])])
        let replay = Replay(
            metadata: Replay.Metadata(
                id: UUID(), state: .success, createdAt: Date(timeIntervalSince1970: 1000),
                terminatedAt: Date(timeIntervalSince1970: 1005),
                itemURLString: "https://example.com/a", itemID: UUID()),
            input: Replay.Input(
                initialURLString: "https://example.com/a", source: .capture(.shareSheet)),
            events: [
                Replay.Event(index: 0, timestamp: Date(timeIntervalSince1970: 1001),
                             kind: .note("started")),
                Replay.Event(index: 1, timestamp: Date(timeIntervalSince1970: 1002),
                             kind: .networkRequest(NetworkRequest(
                                urlString: "https://example.com/a", method: "GET",
                                headers: ["User-Agent": "x"], body: nil))),
                Replay.Event(index: 2, timestamp: Date(timeIntervalSince1970: 1003),
                             kind: .networkResponse(NetworkResponse(
                                urlString: "https://example.com/a", statusCode: 200,
                                headers: [:], body: .text("<html/>", truncatedBytes: 5), error: nil))),
                Replay.Event(index: 3, timestamp: Date(timeIntervalSince1970: 1004),
                             kind: .unwrap(fromURLString: "https://t.co/x",
                                           toURLString: "https://example.com/a")),
                Replay.Event(index: 4, timestamp: Date(timeIntervalSince1970: 1004),
                             kind: .resolveDecision(.readable)),
                Replay.Event(index: 5, timestamp: Date(timeIntervalSince1970: 1004),
                             kind: .bypassStrategy(name: "amp", runsSilently: true, succeeded: false)),
                Replay.Event(index: 6, timestamp: Date(timeIntervalSince1970: 1004),
                             kind: .archiveStage(stage: "challenge", urlString: "https://archive.ph",
                                                 note: nil)),
                Replay.Event(index: 7, timestamp: Date(timeIntervalSince1970: 1004),
                             kind: .extraction(blockCount: 1, bodyTextLength: 10,
                                               title: "Hello", hasReadableBody: true)),
                Replay.Event(index: 8, timestamp: Date(timeIntervalSince1970: 1004),
                             kind: .mediaReference(role: "cover",
                                                   urlString: "https://example.com/cover.jpg")),
                Replay.Event(index: 9, timestamp: Date(timeIntervalSince1970: 1005),
                             kind: .stateChange(.success)),
            ],
            finalContent: content)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(replay)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(Replay.self, from: data)

        XCTAssertEqual(decoded, replay)
        XCTAssertEqual(decoded.schemaVersion, Replay.currentSchemaVersion)
        XCTAssertEqual(decoded.finalContent?.title, "Hello")
    }

    /// The `EventKind` discriminator is the documented `type` string the harness
    /// reads, and `HTTPBody`/`ReplaySource` use their documented shapes.
    func testEventKindUsesDocumentedDiscriminators() throws {
        let encoder = JSONEncoder()
        let request = try encoder.encode(EventKind.networkRequest(NetworkRequest(
            urlString: "u", method: "GET", headers: [:], body: .omitted(reason: "media"))))
        let json = String(decoding: request, as: UTF8.self)
        XCTAssertTrue(json.contains("\"type\":\"networkRequest\""))
        XCTAssertTrue(json.contains("\"kind\":\"omitted\""))
        XCTAssertTrue(json.contains("\"reason\":\"media\""))
    }

    func testReplaySourceLinkInViewerRoundTrips() throws {
        let source = ReplaySource.linkInViewer(parentURLString: "https://parent.example")
        let data = try JSONEncoder().encode(source)
        let decoded = try JSONDecoder().decode(ReplaySource.self, from: data)
        XCTAssertEqual(decoded, source)
        XCTAssertEqual(decoded.label, "linkInViewer")
        XCTAssertEqual(ReplaySource.capture(.appIntent).label, "appIntent")
    }

    // MARK: - Recorder lifecycle, ordering, state transitions

    func testRecorderAssignsMonotonicEventIndicesAndTerminalState() async throws {
        let store = InMemoryReplayStore()
        let recorder = ReplayRecorder(store: store)
        guard let id = await recorder.begin(
            urlString: "https://example.com/a", source: .capture(.manual)) else {
            return XCTFail("begin returned nil")
        }
        await recorder.record(.note("one"), for: id)
        await recorder.record(.note("two"), for: id)
        await recorder.record(.resolveDecision(.readable), for: id)
        await recorder.terminate(id, state: .success, finalContent: nil)

        let written = try XCTUnwrap(store.lastWritten)
        XCTAssertEqual(written.metadata.state, .success)
        XCTAssertNotNil(written.metadata.terminatedAt)
        XCTAssertEqual(written.events.map(\.index), Array(0..<written.events.count))
        // The terminate appends a closing stateChange.
        if case .stateChange(.success) = written.events.last?.kind {} else {
            XCTFail("last event should be the terminal stateChange")
        }
    }

    func testRecorderIgnoresEventsForUnknownReplay() async {
        let store = InMemoryReplayStore()
        let recorder = ReplayRecorder(store: store)
        await recorder.record(.note("orphan"), for: UUID())
        await recorder.terminate(UUID(), state: .failed, finalContent: nil)
        XCTAssertNil(store.lastWritten)
    }

    func testRecorderCapsOversizedTextBody() async throws {
        let store = InMemoryReplayStore()
        let recorder = ReplayRecorder(store: store)
        let begun = await recorder.begin(urlString: "https://e.com", source: .capture(.manual))
        let id = try XCTUnwrap(begun)
        let huge = String(repeating: "x", count: ReplayRecorder.maxBodyBytes + 100)
        await recorder.record(.networkResponse(NetworkResponse(
            urlString: "https://e.com", statusCode: 200, headers: [:],
            body: .text(huge, truncatedBytes: 0), error: nil)), for: id)
        await recorder.terminate(id, state: .success, finalContent: nil)

        let written = try XCTUnwrap(store.lastWritten)
        guard case let .networkResponse(response) = written.events[0].kind,
              case let .text(value, truncated) = response.body else {
            return XCTFail("expected a capped text body")
        }
        XCTAssertEqual(value.utf8.count, ReplayRecorder.maxBodyBytes)
        XCTAssertEqual(truncated, 100)
    }

    func testMarkUserReportedRewritesStateAndReturnsZipURL() async throws {
        let store = InMemoryReplayStore()
        let recorder = ReplayRecorder(store: store)
        let begun = await recorder.begin(urlString: "https://e.com/x", source: .capture(.manual))
        let id = try XCTUnwrap(begun)
        await recorder.terminate(id, state: .success, finalContent: nil)

        let url = await recorder.markUserReported(forItemURLString: "https://e.com/x")
        XCTAssertNotNil(url)
        XCTAssertEqual(store.lastWritten?.metadata.state, .userReported)
        let nilURL = await recorder.markUserReported(forItemURLString: "https://no-such.example")
        XCTAssertNil(nilURL)
    }

    // MARK: - Disk store zip round-trip

    func testDiskStoreZipsAndDecodesReplay() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("replay-test-\(UUID().uuidString)")
        let store = ReplayDiskStore(directory: directory)
        let id = UUID()
        let replay = Replay(
            metadata: Replay.Metadata(
                id: id, state: .userReported, createdAt: Date(),
                terminatedAt: Date(), itemURLString: "https://e.com/round", itemID: nil),
            input: Replay.Input(initialURLString: "https://e.com/round", source: .capture(.paste)),
            events: [Replay.Event(index: 0, timestamp: Date(), kind: .note("hi"))])
        store.write(replay)

        let listed = store.storedReplays()
        XCTAssertEqual(listed.count, 1)
        XCTAssertEqual(listed.first?.id, id)
        XCTAssertEqual(listed.first?.state, .userReported)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.zipURL(for: id).path))

        let decoded = try XCTUnwrap(store.newestReplay(forItemURLString: "https://e.com/round"))
        XCTAssertEqual(decoded.metadata.id, id)
        XCTAssertEqual(decoded.events.first?.kind, .note("hi"))

        try? FileManager.default.removeItem(at: directory)
    }

    func testFirstStoredEntryDataExtractsPayload() {
        var zip = ZipArchiveWriter()
        let payload = Data("the-replay-json".utf8)
        zip.addEntry(path: "x.txt", data: payload)
        let extracted = ReplayDiskStore.firstStoredEntryData(inZip: zip.archiveData())
        XCTAssertEqual(extracted, payload)
    }

    // MARK: - Recording fetcher decorator

    func testRecordingFetcherCapturesRequestAndResponse() async throws {
        let underlying = MockArticleFetcher()
        let url = URL(string: "https://e.com/a")!
        underlying.htmlByURL = [url.absoluteString: "<html>article</html>"]
        let store = InMemoryReplayStore()
        let recorder = ReplayRecorder(store: store)
        let begun = await recorder.begin(urlString: url.absoluteString, source: .capture(.manual))
        let id = try XCTUnwrap(begun)
        let recording = RecordingHTMLFetcher(wrapping: underlying, recorder: recorder, replayID: id)

        let html = try await recording.fetchHTML(from: url, userAgent: "Bot/1", xForwardedFor: "1.2.3.4")
        XCTAssertEqual(html, "<html>article</html>")
        await recorder.terminate(id, state: .success, finalContent: nil)

        let written = try XCTUnwrap(store.lastWritten)
        guard case let .networkRequest(request) = written.events[0].kind else {
            return XCTFail("first event should be the request")
        }
        XCTAssertEqual(request.urlString, url.absoluteString)
        XCTAssertEqual(request.headers["User-Agent"], "Bot/1")
        XCTAssertEqual(request.headers["X-Forwarded-For"], "1.2.3.4")
        guard case let .networkResponse(response) = written.events[1].kind,
              case let .text(body, _) = response.body else {
            return XCTFail("second event should be the response with the HTML body")
        }
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(body, "<html>article</html>")
    }

    func testRecordingFetcherCapturesFailureAsError() async throws {
        let underlying = MockArticleFetcher()
        let url = URL(string: "https://e.com/missing")!
        underlying.failingURLs = [url.absoluteString]
        let store = InMemoryReplayStore()
        let recorder = ReplayRecorder(store: store)
        let begun = await recorder.begin(urlString: url.absoluteString, source: .capture(.manual))
        let id = try XCTUnwrap(begun)
        let recording = RecordingHTMLFetcher(wrapping: underlying, recorder: recorder, replayID: id)

        await XCTAssertThrowsErrorAsync { try await recording.fetchHTML(from: url) }
        await recorder.terminate(id, state: .failed, finalContent: nil)

        let written = try XCTUnwrap(store.lastWritten)
        guard case let .networkResponse(response) = written.events[1].kind else {
            return XCTFail("expected an error response event")
        }
        XCTAssertEqual(response.statusCode, -1)
        XCTAssertNotNil(response.error)
    }

    // MARK: - Resolver bypass-strategy logging

    /// `ArticleResolver.resolve` emits a `bypassStrategy` event (with the strategy's
    /// stable name) for each silent strategy it tries when the direct fetch isn't
    /// readable — the events the integration harness replays.
    func testResolverLogsBypassStrategyAttempts() async {
        let fetcher = MockArticleFetcher()
        let url = URL(string: "https://nytimes.com/2026/story")!
        // Direct fetch returns a server-locked paywall stub (not readable) so the
        // silent bypass strategies run; all of them throw (only the direct URL is
        // stubbed) → no readable result, but each attempt is logged.
        fetcher.htmlByURL = [url.absoluteString: """
            <html><head><meta property="article:content_tier" content="locked"></head>
            <body><p>To continue reading, subscribe now.</p></body></html>
            """]
        let recorded = LoggedEvents()
        _ = await ArticleResolver.resolve(
            url: url, fetcher: fetcher,
            replayLog: { event in await recorded.append(event) })

        let names = await recorded.bypassNames()
        XCTAssertFalse(names.isEmpty, "expected at least one bypassStrategy event")
        // Every logged bypass attempt should have failed (no readable stub).
        let succeeded = await recorded.anyBypassSucceeded()
        XCTAssertFalse(succeeded)
    }

    /// Collects logged `EventKind`s from a resolver `replayLog` (an actor for the
    /// concurrency-safe append).
    actor LoggedEvents {
        private var events: [EventKind] = []
        func append(_ event: EventKind) { events.append(event) }
        func bypassNames() -> [String] {
            events.compactMap { if case let .bypassStrategy(name, _, _) = $0 { return name }; return nil }
        }
        func anyBypassSucceeded() -> Bool {
            events.contains { if case .bypassStrategy(_, _, true) = $0 { return true }; return false }
        }
    }

    // MARK: - Media redaction

    func testMediaBodiesAreNeverStoredAsBytes() throws {
        // Media is recorded as a reference (URL only); an omitted body carries no
        // bytes. The recorder/fetcher never emit base64 for media — confirm the
        // omitted marker encodes without any payload field.
        let body = HTTPBody.omitted(reason: "media: image bytes excluded")
        let data = try JSONEncoder().encode(body)
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(json.contains("base64"))
        XCTAssertFalse(json.contains("\"text\""))
        XCTAssertTrue(json.contains("omitted"))
    }
}

/// An in-memory `ReplayStoring` for recorder tests: keeps the last written replay
/// (and a by-URL map) without touching disk.
final class InMemoryReplayStore: ReplayStoring, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var lastWritten: Replay?
    private var byURL: [String: Replay] = [:]

    func write(_ replay: Replay) {
        lock.lock(); defer { lock.unlock() }
        lastWritten = replay
        byURL[replay.metadata.itemURLString] = replay
    }

    func zipURL(for id: UUID) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("\(id.uuidString).zip")
    }

    func storedReplays() -> [StoredReplay] {
        lock.lock(); defer { lock.unlock() }
        return byURL.values.map {
            StoredReplay(id: $0.metadata.id, itemURLString: $0.metadata.itemURLString,
                         state: $0.metadata.state, createdAt: $0.metadata.createdAt,
                         zipURL: zipURL(for: $0.metadata.id))
        }
    }

    func newestReplay(forItemURLString itemURLString: String) -> Replay? {
        lock.lock(); defer { lock.unlock() }
        return byURL[itemURLString]
    }
}

extension XCTestCase {
    /// Async-friendly `XCTAssertThrowsError`.
    func XCTAssertThrowsErrorAsync(
        _ expression: () async throws -> some Any,
        file: StaticString = #filePath, line: UInt = #line
    ) async {
        do {
            _ = try await expression()
            XCTFail("Expected an error to be thrown", file: file, line: line)
        } catch {}
    }
}
