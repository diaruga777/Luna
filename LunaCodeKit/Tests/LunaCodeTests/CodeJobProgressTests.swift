import XCTest
@testable import LunaCodeCore
@testable import LunaCodeMac

final class CodeJobProgressTests: XCTestCase {
    func testEstimateAdvancesWithinStageAndNeverCompletesIt() {
        let start = Date(timeIntervalSince1970: 100)
        let progress = CodeJobProgress(stage: "Compile", start: 0.25, end: 0.80, estimatedSeconds: 240, startedAt: start)
        XCTAssertEqual(progress.fraction(at: start), 0.25)
        XCTAssertGreaterThan(progress.fraction(at: start.addingTimeInterval(120)), 0.25)
        XCTAssertLessThan(progress.fraction(at: start.addingTimeInterval(1_000_000)), 0.80)
        XCTAssertEqual(progress.fraction(at: start.addingTimeInterval(-100)), 0.25)
    }
    func testOnlySuccessReachesOneHundredAndFailureFreezes() {
        var job = CodeJob(id: "job", title: "Build")
        let start = Date(timeIntervalSince1970: 100)
        job.progress = CodeJobProgress(stage: "Install", start: 0.80, end: 0.93, estimatedSeconds: 40, startedAt: start)
        job.progress?.stoppedAt = start.addingTimeInterval(20)
        job.state = .failed
        XCTAssertEqual(job.progressFraction(at: start.addingTimeInterval(100)), job.progressFraction(at: start.addingTimeInterval(1000)))
        XCTAssertLessThan(job.progressFraction(), 1)
        job.state = .cancelled
        XCTAssertLessThan(job.progressFraction(), 1)
        job.state = .succeeded
        XCTAssertEqual(job.progressFraction(), 1)
    }
    func testOldCompanionJobDecodesWithoutProgress() throws {
        let data = Data(#"{"id":"old","title":"Build","state":"running","log":"","startedAt":100}"#.utf8)
        let job = try JSONDecoder().decode(CodeJob.self, from: data)
        XCTAssertNil(job.progress)
        XCTAssertEqual(job.progressFraction(), 0.05)
    }
    func testStagesAndFrozenProgressSurviveWireRoundTrip() throws {
        var job = CodeJob(id: "job", title: "Build")
        job.progress = CodeJobProgress(stage: "Checkout", start: 0.10, end: 0.15, estimatedSeconds: 20)
        job.progress?.stoppedAt = Date()
        XCTAssertEqual(job, try JSONDecoder().decode(CodeJob.self, from: JSONEncoder().encode(job)))
    }
    func testRestartFreezesInterruptedProgressAndRetainsFailure() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var job = CodeJob(id: "interrupted", title: "Build")
        job.progress = CodeJobProgress(stage: "Compile", start: 0.25, end: 0.80, estimatedSeconds: 240)
        try JSONEncoder().encode(job).write(to: root.appendingPathComponent(job.id + ".json"))
        let jobs = try CodeJobs(root: root)
        let restored = try await jobs.status(job.id)
        XCTAssertEqual(restored.state, .failed)
        XCTAssertNotNil(restored.progress?.stoppedAt)
        XCTAssertTrue(restored.failureMessage?.contains("restarted") == true)
    }
}
