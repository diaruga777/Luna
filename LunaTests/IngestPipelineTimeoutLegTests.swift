//
//  IngestPipelineTimeoutLegTests.swift
//  LunaTests
//
//  The overall-budget leg of `IngestPipeline.processResolved`: it must speak
//  only when the budget really elapsed. It is one of two children in a task
//  group, and the group cancels it as soon as the work leg answers. A
//  cancelled sleeper that falls through and records anyway would put "budget
//  of 28s elapsed" as the last line of the trace for a save that finished in
//  a second.
//

import LunaFetch
import LunaIngest
import LunaModels
import XCTest

final class IngestPipelineTimeoutLegTests: XCTestCase {

    private func url(_ string: String) -> URL { URL(string: string)! }

    /// Runs `body` with a diagnostics recorder bound and returns everything it
    /// buffered, exactly as a save's flush would read it.
    private func trace(_ body: () async -> Void) async -> [String] {
        let recorder = SaveDiagnosticsRecorder(itemID: UUID())
        await SaveDiagnostics.$recorder.withValue(recorder) { await body() }
        return recorder.drainLines()
    }

    private let budgetPhrase = "budget of"

    // MARK: - A save that answers inside its budget

    /// The bug: a video URL is classified offline and answers in milliseconds, yet
    /// its trace claimed the 28-second budget had elapsed.
    func testAFastSaveRecordsNoBudgetLine() async {
        var result: IngestResult?
        let lines = await trace {
            result = await IngestPipeline.processResolved(
                IngestInput(url: url("https://www.youtube.com/watch?v=dQw4w9WgXcQ"),
                            source: .shareSheet),
                timeout: 28,
                fetcher: MockArticleFetcher(),
                articleProcessor: nil,
                productProcessor: nil,
                socialTextProcessor: nil)
        }

        if case .video(let platform, _) = result?.outcome {
            XCTAssertEqual(platform, .youtube)
        } else {
            XCTFail("expected .video, got \(String(describing: result?.outcome))")
        }
        XCTAssertFalse(
            lines.isEmpty, "the pipeline records its classification, so the trace has lines")
        XCTAssertFalse(
            lines.contains { $0.contains(budgetPhrase) },
            "a save that answered inside its budget claimed the budget elapsed: \(lines)")
    }

    // MARK: - A save that really does run out of budget

    /// The genuine timeout for an ordinary host: `.failed(.timedOut)`, and the
    /// budget line IS recorded.
    func testAnOrdinaryHostThatExceedsItsBudgetFailsTimedOutAndSaysSo() async {
        let fetcher = MockArticleFetcher()
        fetcher.delaysByKind[.plain] = 5
        var result: IngestResult?
        let lines = await trace {
            result = await IngestPipeline.processResolved(
                IngestInput(url: url("https://example.com/2026/08/a-readable-story"),
                            source: .shareSheet),
                timeout: 0.05,
                fetcher: fetcher,
                articleProcessor: nil,
                productProcessor: nil,
                socialTextProcessor: nil)
        }

        XCTAssertEqual(result?.outcome, .failed(.timedOut))
        XCTAssertTrue(
            lines.contains { $0.contains(budgetPhrase) && $0.contains("failing timedOut") },
            "the genuine timeout must still record why it gave up: \(lines)")
    }

    /// The genuine timeout for a hard-paywall host parks for the archive reader
    /// instead of failing, and says that in the trace.
    func testAHardPaywallHostThatExceedsItsBudgetParksForTheArchiveReader() async {
        let fetcher = MockArticleFetcher()
        fetcher.delaysByKind[.plain] = 5
        var result: IngestResult?
        let lines = await trace {
            result = await IngestPipeline.processResolved(
                IngestInput(url: url("https://www.nytimes.com/2026/08/13/us/a-real-story.html"),
                            source: .shareSheet),
                timeout: 0.05,
                fetcher: fetcher,
                articleProcessor: nil,
                productProcessor: nil,
                socialTextProcessor: nil)
        }

        if case .needsArchive(let title) = result?.outcome {
            XCTAssertFalse(title.isEmpty)
        } else {
            XCTFail("expected .needsArchive, got \(String(describing: result?.outcome))")
        }
        XCTAssertTrue(
            lines.contains {
                $0.contains(budgetPhrase) && $0.contains("hard-paywall host")
            },
            "the parking decision must be in the trace: \(lines)")
    }
}
