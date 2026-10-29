import Foundation
import LunaModels
import XCTest
@testable import LunaAudioPlayback

final class NightlyArticleAudioTests: XCTestCase {
    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
    private func item(_ name: String, age: TimeInterval = 0, state: SavedItem.State = .ready,
                      read: SavedItem.ReadState = .unopened) -> SavedItem {
        SavedItem(seed: name, urlString: "https://example.com/\(name)", title: name,
                  dateAdded: date("2026-07-01T07:30:00Z").addingTimeInterval(-age), state: state, readState: read)
    }
    private var content: ArticleContent {
        ArticleContent(title: "Article", author: "Jane Smith", blocks: [.init(kind: .paragraph, text: "Words to speak.", links: [])])
    }
    private func worker(items: [SavedItem], now: @escaping () -> Date, enabled: @escaping () -> Bool = { true },
                        current: ((UUID) -> SavedItem?)? = nil,
                        prepare: @escaping (SavedItem, AudioScript, String?, Date) async throws -> Void) -> NightlyArticleAudioWorker {
        NightlyArticleAudioWorker(now: now, enabled: enabled, items: { items },
            currentItem: current ?? { id in items.first { $0.id == id } }, content: { _ in self.content },
            script: { _, content in AudioTrimHeuristics.classify(content).heuristicScript(for: content) }, prepare: prepare)
    }

    func testFixedPSTWindowInSummerAndWinterAndExactBoundaries() {
        // Los Angeles is on PDT in July. Literal PST must still open at 07 UTC.
        for month in ["01", "07"] {
            XCTAssertNil(NightlyArticleAudioWindow.deadline(at: date("2026-\(month)-01T06:59:59Z")))
            XCTAssertEqual(NightlyArticleAudioWindow.deadline(at: date("2026-\(month)-01T07:00:00Z")), date("2026-\(month)-01T08:00:00Z"))
            XCTAssertNotNil(NightlyArticleAudioWindow.deadline(at: date("2026-\(month)-01T07:59:59Z")))
            XCTAssertNil(NightlyArticleAudioWindow.deadline(at: date("2026-\(month)-01T08:00:00Z")))
        }
        XCTAssertEqual(NightlyArticleAudioWindow.nextStart(after: date("2026-07-01T06:59:59Z")), date("2026-07-01T07:00:00Z"))
        XCTAssertEqual(NightlyArticleAudioWindow.nextStart(after: date("2026-07-01T08:00:00Z")), date("2026-07-02T07:00:00Z"))
        XCTAssertEqual(NightlyArticleAudioWindow.nextStart(after: date("2026-12-31T07:30:00Z"), skipCurrentWindow: true), date("2027-01-01T07:00:00Z"))
        XCTAssertEqual(NightlyArticleAudioWindow.nextStart(after: date("2026-07-01T06:00:00Z"), skipCurrentWindow: true), date("2026-07-01T07:00:00Z"))
    }

    func testEarlyLateAndDisabledJobsDoNoWork() async throws {
        for clock in ["2026-07-01T06:59:59Z", "2026-07-01T08:00:00Z"] {
            try await worker(items: [item("article")], now: { self.date(clock) }) { _, _, _, _ in XCTFail("Outside window") }.run()
        }
        try await worker(items: [item("article")], now: { self.date("2026-07-01T07:30:00Z") }, enabled: { false }) { _, _, _, _ in XCTFail("Opted out") }.run()
    }

    func testNewestUnreadFirstIncludingOpenedAndRecheckCurrentState() async throws {
        let old = item("old", age: 100)
        let opened = item("opened", age: 10, read: .opened)
        let newest = item("newest")
        let removed = item("removed", age: 5)
        let read = item("read", read: .read)
        let pending = item("pending", state: .pending)
        var prepared: [UUID] = []
        try await worker(items: [old, read, pending, removed, opened, newest], now: { self.date("2026-07-01T07:30:00Z") },
            current: { id in id == removed.id ? nil : [old, opened, newest, read, pending].first { $0.id == id } }) { item, _, author, deadline in
                XCTAssertEqual(author, "Jane Smith")
                prepared.append(item.id)
                XCTAssertEqual(deadline, self.date("2026-07-01T08:00:00Z"))
            }.run()
        XCTAssertEqual(prepared, [newest.id, opened.id, old.id])
    }

    func testQuotaExitsEntireJobAndMidnightStopsNextArticle() async throws {
        let items = [item("newest"), item("older", age: 10)]
        var count = 0
        do {
            try await worker(items: items, now: { self.date("2026-07-01T07:30:00Z") }) { _, _, _, _ in
                count += 1
                throw GeminiSpeechError.quota
            }.run()
            XCTFail("Quota must propagate")
        } catch { XCTAssertEqual(error as? GeminiSpeechError, .quota) }
        XCTAssertEqual(count, 1)
        var clock = date("2026-07-01T07:59:59Z")
        count = 0
        try await worker(items: items, now: { clock }) { _, _, _, _ in
            count += 1
            clock = self.date("2026-07-01T08:00:00Z")
        }.run()
        XCTAssertEqual(count, 1)
    }

    func testCancellationStopsBeforeFirstArticle() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await worker(items: [item("article")], now: { self.date("2026-07-01T07:30:00Z") }) { _, _, _, _ in XCTFail("Cancelled") }.run()
        }
        do { try await task.value; XCTFail("Expected cancellation") } catch { XCTAssertTrue(error is CancellationError) }
    }
}
