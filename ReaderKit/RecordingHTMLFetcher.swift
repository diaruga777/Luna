//
//  RecordingHTMLFetcher.swift
//  ReaderKit
//

import Foundation

/// A `HTMLFetching` decorator that records every fetch as a request/response pair
/// on a `Replay`, then forwards to the wrapped fetcher. Used to capture the
/// network traffic of `ArticleResolver`/`BypassRunner` without those types knowing
/// about replays — they just receive a `HTMLFetching`.
///
/// The decorator records the request URL/method/headers (the headers each fetch
/// variant sets, mirrored from `ArticleFetcher`) and, on success, the returned HTML
/// as a verbatim text body; on failure, a response with `statusCode == -1` and the
/// error description. Bodies are capped by the recorder. NO media bytes flow
/// through `HTMLFetching`, so none are ever captured here.
struct RecordingHTMLFetcher: HTMLFetching {
    let wrapped: HTMLFetching
    let recorder: ReplayRecording
    let replayID: UUID

    init(wrapping wrapped: HTMLFetching, recorder: ReplayRecording, replayID: UUID) {
        self.wrapped = wrapped
        self.recorder = recorder
        self.replayID = replayID
    }

    func fetchHTML(from url: URL) async throws -> String {
        try await record(
            url: url, headers: ["User-Agent": "Googlebot|Safari (chain)"],
            fetch: { try await wrapped.fetchHTML(from: url) })
    }

    func fetchHTML(from url: URL, userAgent: String, xForwardedFor: String?) async throws -> String {
        var headers = ["User-Agent": userAgent]
        if let xForwardedFor { headers["X-Forwarded-For"] = xForwardedFor }
        return try await record(
            url: url, headers: headers,
            fetch: { try await wrapped.fetchHTML(from: url, userAgent: userAgent, xForwardedFor: xForwardedFor) })
    }

    func fetchHTML(from url: URL, referer: String) async throws -> String {
        try await record(
            url: url, headers: ["Referer": referer],
            fetch: { try await wrapped.fetchHTML(from: url, referer: referer) })
    }

    func fetchHTMLWithoutCookies(from url: URL) async throws -> String {
        try await record(
            url: url, headers: ["Cookie": "(ephemeral session — none sent)"],
            fetch: { try await wrapped.fetchHTMLWithoutCookies(from: url) })
    }

    func fetchWaybackRawHTML(for url: URL) async throws -> String {
        try await record(
            url: url, headers: [:], note: "waybackRaw",
            fetch: { try await wrapped.fetchWaybackRawHTML(for: url) })
    }

    func fetchJinaReader(for url: URL) async throws -> String {
        try await record(
            url: url, headers: [:], note: "jinaReader",
            fetch: { try await wrapped.fetchJinaReader(for: url) })
    }

    func fetchArchivedHTML(for url: URL) async throws -> String {
        try await record(
            url: url, headers: [:], note: "archivedHTML",
            fetch: { try await wrapped.fetchArchivedHTML(for: url) })
    }

    /// Records the request, runs `fetch`, records the response (HTML on success,
    /// error on failure), then returns/rethrows the result unchanged.
    private func record(
        url: URL, headers: [String: String], note: String? = nil,
        fetch: () async throws -> String
    ) async throws -> String {
        var requestHeaders = headers
        if let note { requestHeaders["X-Replay-Fetch"] = note }
        await recorder.record(
            .networkRequest(NetworkRequest(
                urlString: url.absoluteString, method: "GET", headers: requestHeaders, body: nil)),
            for: replayID)
        do {
            let html = try await fetch()
            await recorder.record(
                .networkResponse(NetworkResponse(
                    urlString: url.absoluteString, statusCode: 200, headers: [:],
                    body: .text(html, truncatedBytes: 0), error: nil)),
                for: replayID)
            return html
        } catch {
            await recorder.record(
                .networkResponse(NetworkResponse(
                    urlString: url.absoluteString, statusCode: -1, headers: [:],
                    body: nil, error: String(describing: error))),
                for: replayID)
            throw error
        }
    }
}
