//
//  SavesIngestorTranscriptionTests.swift
//  LunaTests
//

import LunaIngest
import LunaModels
import LunaPluginIngest
import LunaPluginKit
import LunaReaderUI
import LunaStorage
import XCTest
@testable import LunaSaves

/// What the ingestor does with a plugin's recording
/// (`claudedocs/plans/transcription-plugins.md` §3.5 and decision 3): the save
/// parks `.pending` under its title with a job row, and from then on neither a
/// direct `ingest` nor the launch sweep re-walks it.
///
/// The plugin stage is a scripted invoker over the REAL `PluginIngestStage` and
/// the REAL `ArticleModelAdopter`; the URL is claimed before any fetch, so no
/// test touches the network.
final class SavesIngestorTranscriptionTests: XCTestCase {

    private var tempDirectory: URL!
    private var store: SavesStore!
    private var jobs: TranscriptionJobStore!
    private var previousStage: PluginIngestStaging?
    private var previousArticleHandler: IngestorArticleHandling?
    private var scope = PluginAdopterScope()
    private var invoker = FakePluginInvoker()

    override func setUp() {
        super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SavesIngestorTranscriptionTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        store = SavesStore(containerURL: tempDirectory)
        jobs = TranscriptionJobStore(saves: store)
        previousStage = IngestPipeline.pluginStage
        previousArticleHandler = IngestorKindHandlers.article
        scope = PluginAdopterScope()
        PluginModelAdopters.article = ArticleModelAdopter()

        invoker = FakePluginInvoker()
        invoker.loadedPlugins = [.fake(id: "t", produces: [.article])]
        invoker.classifyAnswers["t"] = .json(#"{"kind":"article","itemId":"abc"}"#)
        invoker.ingestAnswers["t"] = .json("""
            {"kind":"article","title":"A recorded talk","author":"Someone","language":"en",
             "html":"<p>The description.</p>",
             "transcription":{"url":"https://cdn.example.com/v.mp4","type":"video",
                              "audioURL":"https://cdn.example.com/a.m4a"}}
            """)
        IngestPipeline.pluginStage = PluginIngestStage(invoker: invoker, processKind: .app)
    }

    override func tearDown() {
        IngestPipeline.pluginStage = previousStage
        IngestorKindHandlers.article = previousArticleHandler
        scope.restore()
        try? FileManager.default.removeItem(at: tempDirectory)
        super.tearDown()
    }

    private func makeIngestor() -> SavesIngestor {
        SavesIngestor(store: store, surfaceGate: ScriptedIngestGate.supported)
    }

    // MARK: - Parking

    func testATranscriptionOutcomeParksTheSaveUnderItsTitleWithAQueuedJob() async throws {
        let ingestor = makeIngestor()
        let saved = store.add(urlString: "https://example.com/p/abc", source: .paste)

        let decision = await ingestor.ingest(saved, intent: .transcribe)

        XCTAssertEqual(decision, .supported)
        let item = try XCTUnwrap(store.item(withID: saved.id))
        XCTAssertEqual(item.state, .pending, "the save waits for the runner")
        XCTAssertEqual(item.title, "A recorded talk")
        XCTAssertEqual(item.pluginID, "t")
        let job = try XCTUnwrap(jobs.job(saveID: saved.id))
        XCTAssertEqual(job.status, .queued)
        XCTAssertEqual(job.request.mediaKind, .video)
        XCTAssertEqual(job.request.audioURL?.absoluteString, "https://cdn.example.com/a.m4a")
        XCTAssertEqual(job.request.pluginID, "t")
        XCTAssertEqual(job.request.leadContent?.blocks.first?.text, "The description.")
        XCTAssertEqual(
            invoker.encodedArguments.map { $0.json["intent"] as? String },
            ["transcribe", "transcribe"])
    }

    // MARK: - The runner owns a queued save

    func testASaveWithAJobIsNeverReWalkedByIngest() async {
        let ingestor = makeIngestor()
        let saved = store.add(urlString: "https://example.com/p/abc", source: .paste)
        _ = await ingestor.ingest(saved)
        let callsAfterParking = invoker.calls.count
        XCTAssertGreaterThan(callsAfterParking, 0)

        let again = await ingestor.ingest(store.item(withID: saved.id) ?? saved)

        XCTAssertEqual(again, .supported)
        XCTAssertEqual(invoker.calls.count, callsAfterParking, "no plugin is asked a second time")
        XCTAssertEqual(jobs.job(saveID: saved.id)?.status, .queued)
    }

    /// The launch sweep re-ingests every pending and failed save. A save with a
    /// job row is skipped, whatever its state; its neighbour without one is not.
    func testTheLaunchSweepSkipsSavesWithAJob() async throws {
        let handler = RecordingArticleHandler()
        IngestorKindHandlers.article = handler
        let ingestor = makeIngestor()

        let owned = SavedItem(
            seed: "owned", urlString: "lunadoc://owned", title: "Owned",
            dateAdded: Date(), state: .failed, documentType: "pdf", captureSource: .manual)
        let free = SavedItem(
            seed: "free", urlString: "lunadoc://free", title: "Free",
            dateAdded: Date(), state: .pending, documentType: "pdf", captureSource: .manual)
        store.seedForTesting(items: [owned, free], contents: [:])
        jobs.enqueue(
            saveID: owned.id,
            request: TranscriptionRequest(
                mediaURL: URL(string: "https://cdn.example.com/a.m4a")!, mediaKind: .audio,
                title: "Owned", pluginID: "t"))

        let swept = expectation(description: "sweep body ran")
        ingestor.ingestAllPending { swept.fulfill() }
        await fulfillment(of: [swept], timeout: 5)

        let deadline = Date().addingTimeInterval(5)
        while handler.documentIDs.isEmpty, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(handler.documentIDs, [free.id], "only the save without a job is re-ingested")
    }
}

/// Records which saves the article kind was asked to ingest as documents.
private final class RecordingArticleHandler: IngestorArticleHandling {
    private let lock = NSLock()
    private var ids: [UUID] = []
    var documentIDs: [UUID] { lock.withLock { ids } }

    func persistArticle(
        _ content: ArticleContent, html: String, for item: SavedItem, url: URL, store: SavesStore
    ) async {}
    func ingestDocument(_ item: SavedItem, store: SavesStore) async {
        lock.withLock { ids.append(item.id) }
    }
    func backfillMissingWebArchives(store: SavesStore) {}
    func backfillMissingThumbnails(store: SavesStore) {}
    func preloadPasteboard(content: ArticleContent, sourceURL: URL) {}
    func doubleSaveDestinationIDs() -> [String] { [] }
    func sendToDestination(_ item: SavedItem, destinationID: String) async {}
    func isDestinationConfigured(_ destinationID: String) -> Bool { false }
}
