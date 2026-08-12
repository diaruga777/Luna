//
//  URLRescueTestFakes.swift
//  LunaTests
//

import Foundation
import LunaFetch
import LunaIngest
import LunaMediaDownload
import LunaModels
@testable import LunaURLRescue

/// An HTML fetcher that returns a canned string for any URL (nil ⇒ throws).
final class FakeRescueHTMLFetcher: HTMLFetching {
    var html: String?
    init(html: String? = nil) { self.html = html }
    private func result() throws -> String {
        guard let html else { throw CocoaError(.fileNoSuchFile) }
        return html
    }
    func fetchHTML(from url: URL) async throws -> String { try result() }
    func fetchHTML(from url: URL, userAgent: String, xForwardedFor: String?) async throws -> String { try result() }
    func fetchHTML(from url: URL, referer: String) async throws -> String { try result() }
    func fetchHTMLWithoutCookies(from url: URL) async throws -> String { try result() }
    func fetchWaybackRawHTML(for url: URL) async throws -> String { try result() }
    func fetchWaybackPrePaywallHTML(for url: URL) async throws -> String { try result() }
    func fetchJinaReader(for url: URL) async throws -> String { try result() }
}

/// A scripted model session — returns the next queued response per call, records
/// what it was asked. Mirrors `FakeTrimModelSession`'s style.
final class FakeRescueModelSession: RescueModelSession {
    enum Response {
        case plan(RescuePlanResponse)
        case article(RescueArticleResponse)
        case failure(RescueModelError)
    }

    var available: Bool
    var articleSupported: Bool
    private var responses: [Response]
    private(set) var prewarmCount = 0
    private(set) var beginAttemptCount = 0
    private(set) var prewarmInstructions: [String] = []
    private(set) var planPrompts: [String] = []
    private(set) var planInstructions: [String] = []
    private(set) var articlePrompts: [String] = []

    init(available: Bool = true, supportsArticlePayload: Bool = false, responses: [Response] = []) {
        self.available = available
        self.articleSupported = supportsArticlePayload
        self.responses = responses
    }

    var isAvailable: Bool { available }
    var supportsArticlePayload: Bool { articleSupported }
    func beginAttempt() { beginAttemptCount += 1 }
    func prewarm(instructions: String) {
        prewarmCount += 1
        prewarmInstructions.append(instructions)
    }

    func requestPlan(instructions: String, prompt: String) async throws -> RescuePlanResponse {
        planInstructions.append(instructions)
        planPrompts.append(prompt)
        return try nextPlan()
    }

    func requestArticlePayload(instructions: String, prompt: String) async throws -> RescueArticleResponse {
        articlePrompts.append(prompt)
        guard !responses.isEmpty else { throw RescueModelError.modelUnavailable }
        switch responses.removeFirst() {
        case .article(let a): return a
        case .failure(let e): throw e
        case .plan: throw RescueModelError.modelUnavailable
        }
    }

    private func nextPlan() throws -> RescuePlanResponse {
        guard !responses.isEmpty else { throw RescueModelError.modelUnavailable }
        switch responses.removeFirst() {
        case .plan(let p): return p
        case .failure(let e): throw e
        case .article: throw RescueModelError.modelUnavailable
        }
    }
}

/// A JS runner returning a canned string, recording what it ran.
final class FakeRescueScriptRunner: RescueScriptRunning {
    var result: String?
    private(set) var ranScripts: [RescueScript] = []
    init(result: String? = nil) { self.result = result }
    func run(_ script: RescueScript) async -> String? {
        ranScripts.append(script)
        return result
    }
}

/// Records every re-entered IngestInput and returns scripted results in order
/// (last result repeats).
final class RecordingPipeline {
    private(set) var inputs: [IngestInput] = []
    private var results: [IngestResult]
    init(results: [IngestResult]) { self.results = results }
    func run(_ input: IngestInput) async -> IngestResult {
        inputs.append(input)
        if results.count > 1 { return results.removeFirst() }
        return results.first ?? IngestResult(url: input.url, outcome: .failed(nil))
    }
}

/// A per-save diagnostic trace held in memory. `contents` returns nil until
/// something is put there — which is the state a real install is in for every
/// failure recorded before the trace file existed, so BOTH cases have to be
/// exercised against the same fake.
final class FakeRescueTraceStore: RescueTraceStoring {
    private var traces: [UUID: String]
    private(set) var appended: [(itemID: UUID, line: String)] = []

    init(traces: [UUID: String] = [:]) { self.traces = traces }

    func contents(for itemID: UUID) -> String? { traces[itemID] }

    func appendLine(_ line: String, for itemID: UUID) {
        appended.append((itemID, line))
        traces[itemID, default: ""] += line + "\n"
    }

    /// Every line this store was handed for `itemID`, joined.
    func appendedText(for itemID: UUID) -> String {
        appended.filter { $0.itemID == itemID }.map(\.line).joined(separator: "\n")
    }
}

/// A search provider returning canned results and recording each query.
final class FakeRescueSearch {
    var results: [RescueSearchResult]
    private(set) var queries: [String] = []
    init(results: [RescueSearchResult] = []) { self.results = results }
    func run(_ query: String) async -> [RescueSearchResult] {
        queries.append(query)
        return results
    }
}

/// A media resolver returning canned assets.
final class FakeMediaResolver: SocialMediaResolving {
    var assets: [MediaAsset]
    private(set) var resolvedURLs: [URL] = []
    init(assets: [MediaAsset] = []) { self.assets = assets }
    func resolveAssets(for url: URL) async -> [MediaAsset] {
        resolvedURLs.append(url)
        return assets
    }
}
