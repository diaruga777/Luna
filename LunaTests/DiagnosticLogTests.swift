//
//  DiagnosticLogTests.swift
//  LunaTests
//

import LunaStorage
import XCTest
@testable import Luna

final class DiagnosticLogTests: XCTestCase {

    private var log: DiagnosticLog!
    private var scratchDirectory: URL!

    override func setUp() {
        super.setUp()
        scratchDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiagnosticLogTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: scratchDirectory, withIntermediateDirectories: true)
        log = DiagnosticLog(containerURL: scratchDirectory)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: scratchDirectory)
        log = nil
        super.tearDown()
    }

    /// `record` lines appear in `contents`, in order, tagged with category.
    func testRecordAppendsTaggedLinesInOrder() {
        log.record("first event", category: "push")
        log.record("second event", category: "social")

        let text = log.contents()
        XCTAssertTrue(text.contains("[push] first event"))
        XCTAssertTrue(text.contains("[social] second event"))
        let firstIndex = text.range(of: "first event")!.lowerBound
        let secondIndex = text.range(of: "second event")!.lowerBound
        XCTAssertLessThan(firstIndex, secondIndex)
    }

    /// `clear` empties the log.
    func testClearEmptiesLog() {
        log.record("event", category: "push")
        XCTAssertFalse(log.contents().isEmpty)

        log.clear()
        XCTAssertTrue(log.contents().isEmpty)
    }

    /// `exportFile` writes a `.txt` whose contents include the header and the
    /// recorded lines.
    func testExportFileIncludesHeaderAndBody() throws {
        log.record("exported event", category: "push")

        let url = try log.exportFile()
        XCTAssertEqual(url.pathExtension, "txt")
        let exported = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(exported.contains("Luna diagnostics"))
        XCTAssertTrue(exported.contains("[push] exported event"))
    }

    // MARK: - The rescue stats line
    //
    // The one place URL rescue is measurable at all. Before it, the only durable
    // record was the per-item ledger, pruned the moment an item disappeared — so
    // "has this ever accomplished anything" had no answer.

    @MainActor
    func testRescueStatsLineSaysNothingHasBeenTriedYet() {
        let stats = RescueStatsStore(containerURL: scratchDirectory)
        let screen = DiagnosticsViewController(log: log, rescueStats: stats)
        XCTAssertTrue(screen.rescueStatsText().contains("nothing attempted"))
    }

    @MainActor
    func testRescueStatsLineReportsAttemptsRecoveriesAndMethods() {
        let stats = RescueStatsStore(containerURL: scratchDirectory)
        stats.recordAttempt(); stats.recordAttempt(); stats.recordAttempt()
        stats.record(.rescued, method: "search")
        stats.record(.browserHandoff, method: "browserHandoff")
        stats.record(.guardrailed)

        let screen = DiagnosticsViewController(log: log, rescueStats: stats)
        let text = screen.rescueStatsText()
        XCTAssertTrue(text.contains("3"), "the attempt count reaches the screen: \(text)")
        XCTAssertTrue(text.contains("search 1"), "the method breakdown reaches it too: \(text)")
    }

    /// The file is trimmed once it exceeds `maxBytes`, but keeps recent lines.
    func testTrimsWhenOverSizeCap() {
        let smallLog = DiagnosticLog(containerURL: scratchDirectory, maxBytes: 2_000)
        for index in 0..<500 {
            smallLog.record("event number \(index)", category: "bulk")
        }
        let text = smallLog.contents()
        XCTAssertLessThan(text.utf8.count, 4_000)
        XCTAssertTrue(text.contains("event number 499"), "most recent line should survive")
        XCTAssertFalse(text.contains("event number 0"), "oldest line should be trimmed away")
    }
}
