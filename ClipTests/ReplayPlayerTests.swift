//
//  ReplayPlayerTests.swift
//  ClipTests
//

import ClipReaderUI
import ClipHTMLClassification
import ClipModels
import XCTest
@testable import Clip

/// Integration tests that run exported `Replay`s back through the REAL article
/// pipeline (unwrap → resolve → extract) with no live network, asserting the app
/// reproduces each replay's recorded terminal outcome.
///
/// Every `*.json` / `*.txt` file under `ClipTests/Fixtures/Replays/` becomes a test
/// case automatically: dropping in a new replay export adds a new assertion. A
/// SUCCESS replay must reproduce its `finalContent`; a FAILED replay must reproduce
/// a non-readable failure (so a failing-save replay is a regression target — fix
/// the code until the replay passes).
final class ReplayPlayerTests: XCTestCase {

    // MARK: - Fixture-driven integration tests (auto-discovered)

    /// Plays every replay fixture through the pipeline and asserts faithful
    /// reproduction. Adding a replay file to the Replays fixtures folder extends
    /// this test with a new case automatically.
    func testAllReplayFixturesReproduce() async throws {
        let fixtures = ReplayFixtures.allReplayJSON()
        XCTAssertFalse(fixtures.isEmpty, "no replay fixtures found under Fixtures/Replays")

        for fixture in fixtures {
            let replay = try ReplayPlayer.decode(json: fixture.json)
            let outcome = try await ReplayPlayer.play(replay)
            XCTAssertTrue(
                outcome.passed,
                """
                replay \(fixture.name) did not reproduce its recorded outcome:
                  expected state \(outcome.expectedState), got \(outcome.reproducedState)
                  content diffs: \(outcome.contentDiffs)
                """)
        }
    }

    // MARK: - Harness unit coverage (constructed replays)

    /// A SUCCESS replay built from real HTML run through the real extractor
    /// reproduces its `finalContent` exactly — the round-trip the fixture relies on.
    func testSuccessReplayReproducesFinalContent() async throws {
        let url = URL(string: "https://example.com/story")! // valid constant URL
        let html = Self.readableArticleHTML
        let content = try ArticleExtractor().extract(html: html, baseURL: url)
        let replay = Self.successReplay(url: url, html: html, finalContent: content)

        let outcome = try await ReplayPlayer.play(replay)
        XCTAssertTrue(outcome.passed, "diffs: \(outcome.contentDiffs)")
        XCTAssertEqual(outcome.reproducedState, .success)
        XCTAssertEqual(outcome.reproducedContent?.title, content.title)
    }

    /// A SUCCESS replay whose recorded `finalContent` disagrees with what the
    /// pipeline produces is a FAILED reproduction (the regression-catching path).
    func testTamperedFinalContentFailsReproduction() async throws {
        let url = URL(string: "https://example.com/story")! // valid constant URL
        let html = Self.readableArticleHTML
        var content = try ArticleExtractor().extract(html: html, baseURL: url)
        content.title = "A Title The Page Never Had"
        let replay = Self.successReplay(url: url, html: html, finalContent: content)

        let outcome = try await ReplayPlayer.play(replay)
        XCTAssertFalse(outcome.passed)
        XCTAssertTrue(outcome.contentDiffs.contains { $0.hasPrefix("title:") })
    }

    /// A replay whose only recorded response is a transport error reproduces a
    /// failure: no readable content, terminal state `.failed`.
    func testFailedNetworkReplayReproducesFailure() async throws {
        let url = URL(string: "https://unreachable.example/story")! // valid constant URL
        let replay = Replay(
            metadata: Replay.Metadata(
                id: UUID(), state: .failed, createdAt: Date(), terminatedAt: Date(),
                itemURLString: url.absoluteString, itemID: nil),
            input: Replay.Input(
                initialURLString: url.absoluteString, source: .capture(.shareSheet)),
            events: [
                Replay.Event(index: 0, timestamp: Date(), kind: .networkRequest(NetworkRequest(
                    urlString: url.absoluteString, method: "GET", headers: [:], body: nil))),
                Replay.Event(index: 1, timestamp: Date(), kind: .networkResponse(NetworkResponse(
                    urlString: url.absoluteString, statusCode: -1, headers: [:],
                    body: nil, error: "The request timed out."))),
                Replay.Event(index: 2, timestamp: Date(), kind: .resolveDecision(.unreadable)),
                Replay.Event(index: 3, timestamp: Date(), kind: .stateChange(.failed)),
            ],
            finalContent: nil)

        let outcome = try await ReplayPlayer.play(replay)
        XCTAssertTrue(outcome.passed)
        XCTAssertEqual(outcome.reproducedState, .failed)
        XCTAssertNil(outcome.reproducedContent)
    }

    /// The recorded `unwrap` event repoints the pipeline to the publisher URL, so
    /// the recorded response keyed by the publisher URL answers the fetch.
    func testReplayHonorsRecordedUnwrapTarget() async throws {
        let wrapper = URL(string: "https://news.google.com/rss/articles/CBMabc")! // valid constant URL
        let publisher = URL(string: "https://example.com/real-story")! // valid constant URL
        let html = Self.readableArticleHTML
        let content = try ArticleExtractor().extract(html: html, baseURL: publisher)
        let replay = Replay(
            metadata: Replay.Metadata(
                id: UUID(), state: .success, createdAt: Date(), terminatedAt: Date(),
                itemURLString: publisher.absoluteString, itemID: nil),
            input: Replay.Input(
                initialURLString: wrapper.absoluteString, source: .capture(.shareSheet)),
            events: [
                Replay.Event(index: 0, timestamp: Date(), kind: .unwrap(
                    fromURLString: wrapper.absoluteString, toURLString: publisher.absoluteString)),
                Replay.Event(index: 1, timestamp: Date(), kind: .networkRequest(NetworkRequest(
                    urlString: publisher.absoluteString, method: "GET", headers: [:], body: nil))),
                Replay.Event(index: 2, timestamp: Date(), kind: .networkResponse(NetworkResponse(
                    urlString: publisher.absoluteString, statusCode: 200, headers: [:],
                    body: .text(html, truncatedBytes: 0), error: nil))),
                Replay.Event(index: 3, timestamp: Date(), kind: .resolveDecision(.readable)),
                Replay.Event(index: 4, timestamp: Date(), kind: .stateChange(.success)),
            ],
            finalContent: content)

        let outcome = try await ReplayPlayer.play(replay)
        XCTAssertTrue(outcome.passed, "diffs: \(outcome.contentDiffs)")
    }

    /// A non-article (youtube/platform/document) replay can't be driven through the
    /// article path and is rejected as an unsupported source.
    func testNonArticleReplayIsRejectedAsUnsupported() async throws {
        let url = URL(string: "https://youtube.com/watch?v=abc")! // valid constant URL
        let replay = Replay(
            metadata: Replay.Metadata(
                id: UUID(), state: .success, createdAt: Date(), terminatedAt: Date(),
                itemURLString: url.absoluteString, itemID: nil),
            input: Replay.Input(initialURLString: url.absoluteString, source: .capture(.shareSheet)),
            events: [Replay.Event(index: 0, timestamp: Date(), kind: .note("youtube video abc"))],
            finalContent: nil)

        do {
            _ = try await ReplayPlayer.play(replay)
            XCTFail("expected an unsupportedSource error")
        } catch ReplayPlayer.PlaybackError.unsupportedSource {
            // expected
        }
    }

    // MARK: - Fixture generation (one-off utility)

    /// Writes the canonical SUCCESS fixture to the Replays folder. Disabled by
    /// default (prefixed `_`); run once via the explicit name to regenerate the
    /// fixture if the extractor's output changes.
    func _generateSuccessFixture() throws {
        let url = URL(string: "https://example.com/small-habits")! // valid constant URL
        let html = Self.readableArticleHTML
        let content = try ArticleExtractor().extract(html: html, baseURL: url)
        let replay = Self.successReplay(url: url, html: html, finalContent: content)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let json = try encoder.encode(replay)
        let path = ReplayFixtures.directory().appendingPathComponent("success-article.txt")
        try json.write(to: path)
        print("wrote fixture to \(path.path)")
    }

    // MARK: - Replay construction helpers

    /// A self-contained, extractor-friendly article page used to build SUCCESS
    /// replays whose `finalContent` is exactly what the real extractor produces.
    static let readableArticleHTML = """
    <html><head>
    <title>Fallback Title</title>
    <meta property="og:title" content="The Quiet Power of Small Habits" />
    <meta name="author" content="Jordan Avery" />
    </head><body>
    <nav><p>Site navigation that the extractor should strip from the output entirely.</p></nav>
    <article>
    <h1>The Quiet Power of Small Habits</h1>
    <p>Most lasting change does not arrive in a single dramatic moment. It accumulates quietly, one small and almost unnoticeable decision at a time, until the sum of those decisions becomes who you are.</p>
    <p>Researchers who study behavior have found that the size of a habit matters far less than its consistency. A two-minute version of a routine, repeated daily, reshapes identity more reliably than an ambitious plan abandoned after a week of enthusiasm.</p>
    <p>The practical lesson is to make the desired behavior so small that refusing it feels absurd. Read one page. Write one sentence. Stretch for sixty seconds. The point is not the page or the sentence; it is the vote you cast for the kind of person you are becoming.</p>
    <p>Over months these votes compound. The reader becomes a person who reads, the writer a person who writes, and the change feels, in retrospect, both inevitable and effortless even though each individual step was almost nothing at all.</p>
    </article>
    <footer><p>Copyright footer boilerplate the extractor should discard.</p></footer>
    </body></html>
    """

    /// Builds a SUCCESS `Replay` for `url` whose single recorded response carries
    /// `html`, with `finalContent` set to the extractor's output for that HTML.
    static func successReplay(url: URL, html: String, finalContent: ArticleContent) -> Replay {
        Replay(
            metadata: Replay.Metadata(
                id: UUID(), state: .success, createdAt: Date(), terminatedAt: Date(),
                itemURLString: url.absoluteString, itemID: nil),
            input: Replay.Input(initialURLString: url.absoluteString, source: .capture(.shareSheet)),
            events: [
                Replay.Event(index: 0, timestamp: Date(), kind: .networkRequest(NetworkRequest(
                    urlString: url.absoluteString, method: "GET", headers: [:], body: nil))),
                Replay.Event(index: 1, timestamp: Date(), kind: .networkResponse(NetworkResponse(
                    urlString: url.absoluteString, statusCode: 200, headers: [:],
                    body: .text(html, truncatedBytes: 0), error: nil))),
                Replay.Event(index: 2, timestamp: Date(), kind: .resolveDecision(.readable)),
                Replay.Event(index: 3, timestamp: Date(), kind: .extraction(
                    blockCount: finalContent.blocks.count, bodyTextLength: finalContent.bodyTextLength,
                    title: finalContent.title, hasReadableBody: finalContent.hasReadableBody)),
                Replay.Event(index: 4, timestamp: Date(), kind: .stateChange(.success)),
            ],
            finalContent: finalContent)
    }
}

/// Loads `Replay` JSON fixtures from `ClipTests/Fixtures/Replays/`, resolved
/// relative to this source file (the test bundle doesn't ship them as resources),
/// so replays live and version alongside the tests. Accepts both `.json` and `.txt`
/// (a replay export's inner entry is a `.txt` of JSON).
enum ReplayFixtures {

    /// One discovered replay fixture: its file name and raw JSON bytes.
    struct Fixture {
        var name: String
        var json: Data
    }

    /// The Replays fixtures directory, alongside this test source.
    static func directory(file: StaticString = #filePath) -> URL {
        URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent("Replays")
    }

    /// Every `*.json` / `*.txt` replay in the fixtures folder, sorted by name for
    /// deterministic ordering.
    static func allReplayJSON(file: StaticString = #filePath) -> [Fixture] {
        let directory = directory(file: file)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
            return []
        }
        return names
            .filter { $0.hasSuffix(".json") || $0.hasSuffix(".txt") }
            .sorted()
            .compactMap { name in
                guard let json = try? Data(contentsOf: directory.appendingPathComponent(name)) else {
                    return nil
                }
                return Fixture(name: name, json: json)
            }
    }
}
