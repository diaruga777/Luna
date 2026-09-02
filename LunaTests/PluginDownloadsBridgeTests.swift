//
//  PluginDownloadsBridgeTests.swift
//  LunaTests
//

import LunaModels
import LunaPluginKit
import LunaPluginRuntime
import LunaStorage
import XCTest

/// `luna.downloads` (§6.9): a read-only view of the download engine's own
/// jobs, driven from real plugin JavaScript against a scratch `SavesStore`
/// the way `PluginDownloadsBridge` reads the shared one.
final class PluginDownloadsBridgeTests: XCTestCase {

    private var runner: PluginJSFixtureRunner!
    private var savesStore: SavesStore!
    private var containerURL: URL!

    private let pluginID = "test.plugin.downloads"

    private func source() -> String {
        """
        /* luna-plugin
        {
          "id": "\(pluginID)",
          "name": "Downloads",
          "version": "1.0.0",
          "api": 1,
          "capabilities": ["downloads"]
        }
        */
        luna.register({
            async onAction(input) {
                const key = input && input.key;
                if (key === "jobs") { return { jobs: await luna.downloads.jobs() }; }
                if (key === "job") { return { job: await luna.downloads.job(input.saveId) }; }
                if (key === "badArgument") {
                    let code = null;
                    try { await luna.downloads.job(input.saveId); }
                    catch (error) { code = error.code; }
                    return { code };
                }
                if (key === "present") {
                    return {
                        present: typeof luna.downloads !== "undefined",
                        hasJobs: typeof luna.downloads.jobs === "function",
                        hasJob: typeof luna.downloads.job === "function",
                    };
                }
                return null;
            },
        });
        """
    }

    private func boot(processKind: PluginProcessKind = .app) throws {
        containerURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "PluginDownloadsBridgeTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: containerURL, withIntermediateDirectories: true)
        savesStore = SavesStore(containerURL: containerURL)
        runner = PluginJSFixtureRunner(processKind: processKind)
        runner.capabilities.register(
            PluginDownloadsBridge(store: savesStore, scheduler: runner.runtime))
        try runner.load(source())
    }

    override func tearDown() {
        runner?.cleanUp()
        runner = nil
        savesStore = nil
        if let containerURL { try? FileManager.default.removeItem(at: containerURL) }
        containerURL = nil
        super.tearDown()
    }

    // MARK: - Wire shapes

    private struct ActionArgument: Encodable {
        let key: String
        var saveId: String? = nil
    }

    private struct DownloadJobWire: Decodable, Equatable {
        let saveId: String?
        let sourceUrl: String
        let title: String
        let phase: String
        let progress: Double
        let receivedBytes: Double?
        let expectedBytes: Double?
        let failure: String?
        let pluginId: String?
        let quality: String?
    }

    private struct JobsAnswer: Decodable { let jobs: [DownloadJobWire] }
    private struct JobAnswer: Decodable { let job: DownloadJobWire? }
    private struct CodeAnswer: Decodable { let code: String? }
    private struct PresenceAnswer: Decodable {
        let present: Bool
        let hasJobs: Bool
        let hasJob: Bool
    }

    private func makeJob(
        sourceURLString: String, title: String = "A save",
        phase: LiveMediaDownloadJob.Phase = .downloading, progress: Double = 0.4,
        receivedByteCount: Int64? = 400, expectedByteCount: Int64? = 1000,
        errorMessage: String? = nil, pluginID: String? = "app.luna.tiktok",
        quality: String? = "720p"
    ) -> LiveMediaDownloadJob {
        LiveMediaDownloadJob(
            id: UUID().uuidString, sourceURLString: sourceURLString, title: title,
            phase: phase, progress: progress,
            expectedByteCount: expectedByteCount, receivedByteCount: receivedByteCount,
            errorMessage: errorMessage, resolveAttempts: 0, mediaAttempts: 0,
            pluginID: pluginID, quality: quality)
    }

    // MARK: - jobs()

    func testJobsListsWrittenJobsWithTheirFields() async throws {
        try boot()
        let save = savesStore.add(urlString: "https://example.com/reel")
        let job = makeJob(sourceURLString: save.urlString)
        savesStore.writeMediaDownloadJob(job)

        let answer = await runner.invoke(
            .onAction, pluginID: pluginID, argument: ActionArgument(key: "jobs"),
            as: JobsAnswer.self)
        let wire = try XCTUnwrap(answer?.jobs.first)

        XCTAssertEqual(answer?.jobs.count, 1)
        XCTAssertEqual(wire.saveId, save.id.uuidString)
        XCTAssertEqual(wire.sourceUrl, save.urlString)
        XCTAssertEqual(wire.title, "A save")
        XCTAssertEqual(wire.phase, "downloading")
        XCTAssertEqual(wire.progress, 0.4)
        XCTAssertEqual(wire.receivedBytes, 400)
        XCTAssertEqual(wire.expectedBytes, 1000)
        XCTAssertNil(wire.failure)
        XCTAssertEqual(wire.pluginId, "app.luna.tiktok")
        XCTAssertEqual(wire.quality, "720p")
    }

    func testAJobWhoseSaveWasDeletedHasSaveIdNull() async throws {
        try boot()
        // No matching save was ever created for this URL — the source url a
        // job carries is the only link back to one, and this one names none.
        let job = makeJob(sourceURLString: "https://example.com/orphaned")
        savesStore.writeMediaDownloadJob(job)

        let answer = await runner.invoke(
            .onAction, pluginID: pluginID, argument: ActionArgument(key: "jobs"),
            as: JobsAnswer.self)

        XCTAssertEqual(answer?.jobs.count, 1)
        XCTAssertNil(answer?.jobs.first?.saveId)
    }

    // MARK: - job(saveId)

    func testJobForASaveWithNoJobIsNull() async throws {
        try boot()
        let save = savesStore.add(urlString: "https://example.com/nothing-downloading")

        let answer = await runner.invoke(
            .onAction, pluginID: pluginID,
            argument: ActionArgument(key: "job", saveId: save.id.uuidString),
            as: JobAnswer.self)

        XCTAssertNotNil(answer, "the call itself must succeed")
        XCTAssertNil(answer?.job)
    }

    func testJobResolvesTheSavesURLToItsJob() async throws {
        try boot()
        let save = savesStore.add(urlString: "https://example.com/found")
        savesStore.writeMediaDownloadJob(makeJob(sourceURLString: save.urlString, title: "Found"))

        let answer = await runner.invoke(
            .onAction, pluginID: pluginID,
            argument: ActionArgument(key: "job", saveId: save.id.uuidString),
            as: JobAnswer.self)

        XCTAssertEqual(answer?.job?.title, "Found")
        XCTAssertEqual(answer?.job?.saveId, save.id.uuidString)
    }

    func testJobRejectsBadArgumentForANonUUIDSaveId() async throws {
        try boot()

        let answer = await runner.invoke(
            .onAction, pluginID: pluginID,
            argument: ActionArgument(key: "badArgument", saveId: "not-a-uuid"),
            as: CodeAnswer.self)

        XCTAssertEqual(answer?.code, "bad-argument")
    }

    // MARK: - Grant

    func testADeclaredDownloadsCapabilityIsPresentInEveryProcessKind() async throws {
        for processKind in [PluginProcessKind.app, .share, .action] {
            try boot(processKind: processKind)
            let answer = await runner.invoke(
                .onAction, pluginID: pluginID, argument: ActionArgument(key: "present"),
                as: PresenceAnswer.self)
            XCTAssertEqual(answer?.present, true, "\(processKind)")
            XCTAssertEqual(answer?.hasJobs, true, "\(processKind)")
            XCTAssertEqual(answer?.hasJob, true, "\(processKind)")
            runner.cleanUp()
            runner = nil
        }
    }
}
