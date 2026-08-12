//
//  SaveDiagnosticsTests.swift
//  LunaTests
//
//  The per-save diagnostic trace's two halves: the in-memory recorder that a
//  save binds as a task-local (LunaModels) and the per-item file it flushes
//  into on failure (LunaStorage). See `claudedocs/save-diagnostics.md`.
//

import LunaModels
import LunaStorage
import XCTest

final class SaveDiagnosticsRecorderTests: XCTestCase {

    /// A recorder plus the messages its mirror saw, since almost every
    /// assertion here is about the pair.
    private func makeRecorder(
        itemID: UUID = UUID(), maxBufferedLines: Int = 2_000
    ) -> (SaveDiagnosticsRecorder, () -> [(String, String)]) {
        let box = MirrorBox()
        let recorder = SaveDiagnosticsRecorder(
            itemID: itemID, maxBufferedLines: maxBufferedLines
        ) { message, category in
            box.append((message, category))
        }
        return (recorder, { box.messages })
    }

    private final class MirrorBox: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [(String, String)] = []
        var messages: [(String, String)] {
            lock.lock(); defer { lock.unlock() }
            return storage
        }
        func append(_ entry: (String, String)) {
            lock.lock(); defer { lock.unlock() }
            storage.append(entry)
        }
    }

    // MARK: - Buffering and mirroring

    /// The buffered line is the on-disk format (`ISO8601 [category] message`),
    /// while the mirrored copy carries the correlation tag instead — the
    /// `[category]` slot of a diagnostics line is already spoken for.
    func testEachRecordBuffersAFormattedLineAndMirrorsItTagged() {
        let itemID = UUID()
        let (recorder, mirrored) = makeRecorder(itemID: itemID)

        recorder.record("GET example.com → 403", category: "fetch")

        let lines = recorder.drainLines()
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines[0].hasSuffix("[fetch] GET example.com → 403"), lines[0])
        XCTAssertTrue(lines[0].hasPrefix("20"), "the line leads with an ISO8601 stamp: \(lines[0])")

        XCTAssertEqual(mirrored().count, 1)
        XCTAssertEqual(mirrored()[0].1, "fetch")
        XCTAssertEqual(
            mirrored()[0].0,
            "[save \(itemID.uuidString.prefix(8))] GET example.com → 403")
    }

    /// Draining is a hand-off, not a copy: the second flush of a retried save
    /// must carry only that attempt's lines, or every retry would re-share the
    /// whole history under a fresh attempt separator.
    func testDrainingEmptiesTheBufferSoASecondFlushCarriesOnlyNewLines() {
        let (recorder, _) = makeRecorder()
        recorder.record("first", category: "ingest")
        XCTAssertEqual(recorder.drainLines().count, 1)

        XCTAssertTrue(recorder.isEmpty)
        recorder.record("second", category: "ingest")
        let second = recorder.drainLines()
        XCTAssertEqual(second.count, 1)
        XCTAssertTrue(second[0].hasSuffix("second"))
    }

    /// A runaway save must not buffer without bound, and a trimmed trace must
    /// not read as a complete one.
    func testTheBufferCapDropsTheOldestLinesAndSaysSo() {
        let (recorder, _) = makeRecorder(maxBufferedLines: 3)
        for index in 1...6 { recorder.record("line \(index)", category: "ingest") }

        let lines = recorder.drainLines()
        XCTAssertEqual(lines.count, 4, "3 kept lines plus the notice")
        XCTAssertTrue(lines[0].contains("3 earlier lines dropped"), lines[0])
        XCTAssertTrue(lines[1].hasSuffix("line 4"))
        XCTAssertTrue(lines[3].hasSuffix("line 6"))
    }

    // MARK: - The task-local binding

    /// Instrumentation call sites are unconditional; outside a save they must
    /// write nothing at all.
    func testRecordingOutsideASaveIsANoOp() {
        SaveDiagnostics.record("stray", category: "fetch")
        XCTAssertFalse(SaveDiagnostics.isRecording)
        XCTAssertNil(SaveDiagnostics.recorder)
    }

    /// The whole point of the task-local: a leg six modules down records into
    /// the right save's trace without anyone threading an argument to it.
    func testTheBindingReachesAnAsyncCalleeAndEndsWithIt() async {
        let (recorder, mirrored) = makeRecorder()

        await SaveDiagnostics.$recorder.withValue(recorder) {
            await self.pretendPipelineLeg()
        }
        // Outside the binding again — this one must not land.
        await pretendPipelineLeg()

        let lines = recorder.drainLines()
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines[0].hasSuffix("[fetch] a leg deep in the pipeline"))
        XCTAssertEqual(mirrored().count, 1)
    }

    private func pretendPipelineLeg() async {
        await Task.yield()
        SaveDiagnostics.record("a leg deep in the pipeline", category: "fetch")
    }

    /// The media leg's seam: a save whose `Outcome` is a success but which is
    /// nonetheless broken can say so, and the flush honours it.
    func testMarkingATerminalFailureIsVisibleToTheFlush() {
        let (recorder, _) = makeRecorder()
        XCTAssertNil(recorder.terminalFailure)

        SaveDiagnostics.$recorder.withValue(recorder) {
            SaveDiagnostics.markTerminalFailure(.noMediaFound)
        }
        XCTAssertEqual(recorder.terminalFailure, .noMediaFound)
    }

    // MARK: - Redaction helpers

    /// A trace carries shapes, never bodies — and one record must stay one
    /// line, or a multi-line error would forge extra entries.
    func testSnippetClampsAndFlattensQuotedText() {
        let long = String(repeating: "x", count: 500)
        let clamped = SaveDiagnostics.snippet(long)
        XCTAssertEqual(clamped.count, 201, "200 chars plus the ellipsis")
        XCTAssertTrue(clamped.hasSuffix("…"))

        XCTAssertEqual(SaveDiagnostics.snippet("one\ntwo\r\nthree"), "one two  three")
    }

    /// `formatLine` is the writer for a leg with no task tree left (a
    /// background transfer). It must produce the SAME shape the recorder does,
    /// or a file would hold two formats.
    func testFormatLineMatchesTheRecordersOwnShape() {
        let (recorder, _) = makeRecorder()
        recorder.record("shape", category: "media")
        let buffered = recorder.drainLines()[0]
        let direct = SaveDiagnostics.formatLine("shape", category: "media")

        XCTAssertTrue(direct.hasSuffix("[media] shape"))
        XCTAssertEqual(
            direct.prefix(while: { $0 != " " }).count,
            buffered.prefix(while: { $0 != " " }).count,
            "both stamps are the same ISO8601 shape")
    }
}

final class SaveDiagnosticsStoreTests: XCTestCase {

    private var directory: URL!
    private var store: SaveDiagnosticsStore!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SaveDiagnosticsStoreTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = SaveDiagnosticsStore(containerURL: directory)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    /// A retry appends rather than replaces, which is what makes a shared trace
    /// show whether a failure is stable or intermittent.
    func testLaterAttemptsAppendToTheSameTrace() {
        let id = UUID()
        XCTAssertFalse(store.hasDiagnostics(for: id))
        XCTAssertNil(store.contents(for: id))

        store.appendLines(["— attempt 1 —", "tried this"], for: id)
        store.appendLines(["— attempt 2 —", "tried that"], for: id)

        let contents = store.contents(for: id)
        XCTAssertEqual(
            contents,
            "— attempt 1 —\ntried this\n— attempt 2 —\ntried that\n")
        XCTAssertTrue(store.hasDiagnostics(for: id))
    }

    func testAppendingNothingCreatesNoFile() {
        let id = UUID()
        store.appendLines([], for: id)
        XCTAssertFalse(store.hasDiagnostics(for: id))
    }

    /// The inverse trim of `DiagnosticLog`'s: retries append forever, so the
    /// NEWEST attempt is the one that must survive the cap.
    func testAnOversizedTraceKeepsItsNewestLines() throws {
        let small = SaveDiagnosticsStore(containerURL: directory, maxBytesPerFile: 2_000)
        let id = UUID()
        for index in 1...400 {
            small.appendLine("line \(index) " + String(repeating: "p", count: 40), for: id)
        }

        let contents = try XCTUnwrap(small.contents(for: id))
        XCTAssertLessThanOrEqual(contents.utf8.count, 2_000)
        XCTAssertTrue(contents.hasPrefix("…(trimmed)\n"), String(contents.prefix(40)))
        XCTAssertTrue(contents.contains("line 400 "), "the newest line survives")
        XCTAssertFalse(contents.contains("line 1 "), "the oldest lines are the ones dropped")
    }

    func testDeleteRemovesOnlyThatItemsTrace() {
        let kept = UUID()
        let dropped = UUID()
        store.appendLine("kept", for: kept)
        store.appendLine("dropped", for: dropped)

        store.delete(for: dropped)

        XCTAssertTrue(store.hasDiagnostics(for: kept))
        XCTAssertFalse(store.hasDiagnostics(for: dropped))
    }

    func testPruningDropsTracesForItemsThatNoLongerExist() {
        let kept = UUID()
        let gone = UUID()
        store.appendLine("kept", for: kept)
        store.appendLine("gone", for: gone)

        store.prune(keeping: [kept])

        XCTAssertTrue(store.hasDiagnostics(for: kept))
        XCTAssertFalse(store.hasDiagnostics(for: gone))
    }

    func testExportWritesTheHeaderAheadOfTheTrace() throws {
        let id = UUID()
        store.appendLines(["first", "second"], for: id)

        let exported = try store.exportFile(for: id, header: "Luna save diagnostics\n----\n\n")
        let text = try String(contentsOf: exported, encoding: .utf8)

        XCTAssertTrue(text.hasPrefix("Luna save diagnostics\n----\n\n"))
        XCTAssertTrue(text.hasSuffix("first\nsecond\n"))
        XCTAssertTrue(exported.lastPathComponent.hasSuffix(".txt"))
        try? FileManager.default.removeItem(at: exported)
    }

    /// Nothing to export is an error, not an empty file — the card only offers
    /// the verb when `hasDiagnostics`, so reaching here means the trace was
    /// deleted underneath it.
    func testExportingAnAbsentTraceThrows() {
        XCTAssertThrowsError(try store.exportFile(for: UUID(), header: "header"))
    }
}
