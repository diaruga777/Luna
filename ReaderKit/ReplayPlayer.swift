//
//  ReplayPlayer.swift
//  ReaderKit
//

import ClipModels
import Foundation

/// Replays a `Replay` through the REAL article pipeline (unwrap → resolve →
/// extract) with NO live network — every fetch is answered from the replay's
/// recorded `networkResponse` events via `ReplayHTMLFetcher` — and checks that the
/// app reproduces the same terminal outcome the replay recorded.
///
/// This is the reusable, test-framework-agnostic core of the integration-test
/// harness (the XCTest wrapper lives in `ClipTests`). A success replay must
/// reproduce its `finalContent`; a failed replay must reproduce a non-readable
/// terminal outcome. The producer of the comparison is the same `ArticleResolver`
/// the ingestor/extensions use, so a passing replay exercises the real code path.
enum ReplayPlayer {

    /// The outcome of replaying one `Replay` through the pipeline.
    struct Outcome: Equatable {
        /// Whether the pipeline reproduced the replay's recorded terminal state.
        var matchedExpectedState: Bool
        /// The terminal `ReplayState` the pipeline reproduced.
        var reproducedState: Replay.ReplayState
        /// The terminal `ReplayState` the replay recorded as its expectation.
        var expectedState: Replay.ReplayState
        /// The article content the pipeline produced (nil for a non-readable outcome).
        var reproducedContent: ArticleContent?
        /// Per-field differences between the recorded `finalContent` and the
        /// reproduced content (empty when they match or neither expects content).
        var contentDiffs: [String]

        /// Whether the replay was reproduced faithfully: the terminal state matched
        /// and (for a success replay) the content matched field-for-field.
        var passed: Bool {
            matchedExpectedState && contentDiffs.isEmpty
        }
    }

    /// Why a replay could not be run at all (a malformed replay, not a pipeline
    /// mismatch — those are reported in `Outcome`).
    enum PlaybackError: Error, Equatable {
        /// The replay's schema version isn't one this player understands.
        case unsupportedSchemaVersion(Int)
        /// The replay's effective URL string couldn't be parsed into a `URL`.
        case invalidURL(String)
        /// The replay records a source this player can't drive yet (only the article
        /// path is supported — YouTube/platform/document saves carry a `note`, not a
        /// resolvable article).
        case unsupportedSource(String)
    }

    /// Decodes a `Replay` from its serialized JSON (the export's `.txt` payload),
    /// using the same ISO-8601 date strategy `ReplayDiskStore` writes with.
    static func decode(json: Data) throws -> Replay {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Replay.self, from: json)
    }

    /// Runs `replay` through the article pipeline and returns how faithfully the
    /// pipeline reproduced it. Throws `PlaybackError` only when the replay itself
    /// can't be driven (bad schema/URL/source); a pipeline mismatch is a non-passing
    /// `Outcome`, not a throw, so a regression replay surfaces as a failed assertion.
    static func play(
        _ replay: Replay,
        extractor: ArticleExtractor = ArticleExtractor()
    ) async throws -> Outcome {
        guard replay.schemaVersion == Replay.currentSchemaVersion else {
            throw PlaybackError.unsupportedSchemaVersion(replay.schemaVersion)
        }
        if let note = unsupportedSourceNote(in: replay) {
            throw PlaybackError.unsupportedSource(note)
        }

        let url = try resolvedURL(for: replay)
        let fetcher = ReplayHTMLFetcher(replay: replay)
        let resolution = await ArticleResolver.resolve(url: url, fetcher: fetcher, extractor: extractor)

        let (reproducedState, reproducedContent) = terminalOutcome(from: resolution)
        let expectedState = replay.metadata.state
        let contentDiffs = diff(expected: replay.finalContent, reproduced: reproducedContent,
                                expectedState: expectedState)

        return Outcome(
            matchedExpectedState: statesMatch(reproduced: reproducedState, expected: expectedState),
            reproducedState: reproducedState,
            expectedState: expectedState,
            reproducedContent: reproducedContent,
            contentDiffs: contentDiffs)
    }

    // MARK: - URL & source

    /// The URL the pipeline should resolve: the recorded `unwrap` target when the
    /// save was a news-aggregator wrapper (we honor the recorded unwrap decision
    /// rather than re-running the live unwrap, which issues raw `URLSession`
    /// requests outside the `HTMLFetching` seam and so isn't captured for replay),
    /// else the initial input URL.
    private static func resolvedURL(for replay: Replay) throws -> URL {
        var urlString = replay.input.initialURLString
        for event in replay.events {
            if case let .unwrap(_, toURLString) = event.kind { urlString = toURLString }
        }
        guard let url = URL(string: urlString) else { throw PlaybackError.invalidURL(urlString) }
        return url
    }

    /// A non-article save records a `note` (youtube/platform/document) instead of a
    /// resolvable article. Returns that note when present so `play` can reject it as
    /// an unsupported source rather than mis-resolving a non-article URL.
    private static func unsupportedSourceNote(in replay: Replay) -> String? {
        for event in replay.events {
            guard case let .note(text) = event.kind else { continue }
            let lowercased = text.lowercased()
            if lowercased.hasPrefix("youtube") || lowercased.hasPrefix("platform")
                || lowercased.hasPrefix("document") || lowercased.hasPrefix("product")
                || lowercased.hasPrefix("created price tracker")
                || lowercased.hasPrefix("merged into existing tracker") {
                return text
            }
        }
        return nil
    }

    // MARK: - Outcome mapping & comparison

    /// Maps an `ArticleResolution` to the terminal `(state, content)` the ingestor
    /// would record: a readable resolution is `.success` with content; a paywalled
    /// or unreadable resolution is `.failed` with no content (matching
    /// `ReadingListIngestor.ingest`'s replay termination for the silent path).
    private static func terminalOutcome(
        from resolution: ArticleResolution
    ) -> (Replay.ReplayState, ArticleContent?) {
        switch resolution {
        case let .readable(content, _): return (.success, content)
        case .paywalled, .unreadable: return (.failed, nil)
        }
    }

    /// Whether a reproduced state satisfies the recorded expectation. `success` must
    /// match exactly. `failed`, `userReported`, and `inProgress` are all "not a
    /// clean readable success", so any non-`success` reproduced state satisfies a
    /// non-`success` expectation (a user-reported buggy save is still a failure to
    /// reproduce a readable article).
    private static func statesMatch(
        reproduced: Replay.ReplayState, expected: Replay.ReplayState
    ) -> Bool {
        if expected == .success { return reproduced == .success }
        return reproduced != .success
    }

    /// Field-level differences between the recorded and reproduced content. Only a
    /// success replay (one that recorded `finalContent`) is compared; a failure
    /// replay has no content to match, so an empty diff means "reproduced a failure
    /// as expected".
    private static func diff(
        expected: ArticleContent?, reproduced: ArticleContent?,
        expectedState: Replay.ReplayState
    ) -> [String] {
        guard expectedState == .success, let expected else { return [] }
        guard let reproduced else {
            return ["expected readable content but the pipeline produced none"]
        }

        var diffs: [String] = []
        if reproduced.title != expected.title {
            diffs.append("title: expected \(quoted(expected.title)) got \(quoted(reproduced.title))")
        }
        if reproduced.author != expected.author {
            diffs.append("author: expected \(quoted(expected.author)) got \(quoted(reproduced.author))")
        }
        if reproduced.blocks.count != expected.blocks.count {
            diffs.append("block count: expected \(expected.blocks.count) got \(reproduced.blocks.count)")
        }
        // Compare text on the blocks present in both; the count diff above already
        // flags a structural mismatch. Image local-file names are excluded — they're
        // assigned during the ingestor's image download, which a pure replay of the
        // article path doesn't perform.
        for (index, expectedBlock) in expected.blocks.enumerated() where index < reproduced.blocks.count {
            let reproducedBlock = reproduced.blocks[index]
            if reproducedBlock.kind != expectedBlock.kind {
                diffs.append("block \(index) kind: expected \(expectedBlock.kind.rawValue) "
                    + "got \(reproducedBlock.kind.rawValue)")
            }
            if reproducedBlock.text != expectedBlock.text {
                diffs.append("block \(index) text mismatch")
            }
        }
        return diffs
    }

    private static func quoted(_ value: String?) -> String {
        value.map { "\"\($0)\"" } ?? "nil"
    }
}
