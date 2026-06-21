//
//  ReplayHTMLFetcher.swift
//  ReaderKit
//

import Foundation

/// A deterministic `HTMLFetching` that answers every fetch from a `Replay`'s
/// recorded `networkRequest`/`networkResponse` events instead of touching the
/// network — the network seam the integration harness drives. It is the inverse of
/// `RecordingHTMLFetcher`: that decorator WRITES request/response pairs into a
/// replay; this one READS them back to reproduce the same fetches.
///
/// Matching: responses are keyed by request URL. The same URL can be fetched more
/// than once in a save (e.g. a direct read then an AMP/archive variant), so a URL's
/// recorded responses are consumed in recorded order — the first unconsumed
/// response for a URL answers the next fetch of that URL. A fetch with no recorded
/// response (or a recorded transport error / non-2xx status) throws the way the
/// recording shows, so a replay reproduces failures as faithfully as successes.
///
/// `RecordingHTMLFetcher` records every `HTMLFetching` variant as a plain `GET`
/// with the response HTML as a verbatim text body, so this player matches on URL
/// alone and decodes the recorded body (text verbatim, base64 decoded to UTF-8).
actor ReplayHTMLFetcher: HTMLFetching {

    /// Why a recorded fetch could not be replayed as a successful HTML body.
    enum ReplayFetchError: Error, Equatable {
        /// No recorded response remained for this URL (an un-recorded request).
        case noRecordedResponse(urlString: String)
        /// The recording captured a transport error (statusCode -1) for this URL.
        case recordedTransportError(urlString: String, message: String)
        /// The recording captured a non-success HTTP status for this URL.
        case recordedHTTPError(urlString: String, statusCode: Int)
        /// The recorded response carried no body (or a non-text/omitted body) to
        /// hand back as HTML.
        case recordedResponseHadNoTextBody(urlString: String)
    }

    /// One recorded response, in the order it appeared in the replay.
    private struct RecordedResponse {
        var response: NetworkResponse
        var consumed: Bool
    }

    /// Recorded responses grouped by URL, each list consumed front-to-back.
    private var responsesByURL: [String: [RecordedResponse]]

    /// Builds a player from a replay's events. Only `networkResponse` events are
    /// used; requests are informational. Responses keep their recorded order per URL.
    init(replay: Replay) {
        var grouped: [String: [RecordedResponse]] = [:]
        for event in replay.events {
            guard case let .networkResponse(response) = event.kind else { continue }
            grouped[response.urlString, default: []].append(
                RecordedResponse(response: response, consumed: false))
        }
        self.responsesByURL = grouped
    }

    // MARK: - HTMLFetching

    func fetchHTML(from url: URL) async throws -> String {
        try answer(for: url)
    }

    func fetchHTML(from url: URL, userAgent: String, xForwardedFor: String?) async throws -> String {
        try answer(for: url)
    }

    func fetchHTML(from url: URL, referer: String) async throws -> String {
        try answer(for: url)
    }

    func fetchHTMLWithoutCookies(from url: URL) async throws -> String {
        try answer(for: url)
    }

    func fetchWaybackRawHTML(for url: URL) async throws -> String {
        try answer(for: url)
    }

    func fetchJinaReader(for url: URL) async throws -> String {
        try answer(for: url)
    }

    // MARK: - Recorded-response replay

    /// Consumes the next recorded response for `url` and reproduces its outcome:
    /// returns the recorded HTML body on a 2xx, or throws the recorded transport /
    /// HTTP / missing-body failure.
    private func answer(for url: URL) throws -> String {
        let key = url.absoluteString
        guard let index = responsesByURL[key]?.firstIndex(where: { !$0.consumed }) else {
            throw ReplayFetchError.noRecordedResponse(urlString: key)
        }
        responsesByURL[key]?[index].consumed = true
        let response = responsesByURL[key]![index].response

        if response.statusCode == -1 {
            throw ReplayFetchError.recordedTransportError(
                urlString: key, message: response.error ?? "transport error")
        }
        guard (200..<300).contains(response.statusCode) else {
            throw ReplayFetchError.recordedHTTPError(urlString: key, statusCode: response.statusCode)
        }
        return try html(from: response)
    }

    /// Decodes a recorded response body into HTML text: a text body is verbatim, a
    /// base64 body is decoded as UTF-8, and anything else (omitted/none) has no HTML.
    private func html(from response: NetworkResponse) throws -> String {
        switch response.body {
        case let .text(value, _):
            return value
        case let .base64(value):
            guard let data = Data(base64Encoded: value),
                  let decoded = String(data: data, encoding: .utf8)
            else { throw ReplayFetchError.recordedResponseHadNoTextBody(urlString: response.urlString) }
            return decoded
        case .omitted, .none:
            throw ReplayFetchError.recordedResponseHadNoTextBody(urlString: response.urlString)
        }
    }
}
