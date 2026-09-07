//
//  RescueFailureEvidence.swift
//  LunaURLRescue
//

import Foundation
import LunaModels

/// Compresses a save's diagnostic trace (`SaveDiagnosticsStore.contents(for:)`)
/// into a token-budgeted excerpt the rescue prompt can carry.
///
/// Without it, the model would only get the URL, one canned sentence, and a
/// digest of the page, and would have to re-discover in one shot what the
/// pipeline already knew (which statuses came back, which of the bypass
/// strategies ran, where a redirect landed). This turns that record into a few
/// dozen lines.
///
/// Everything here is UNTRUSTED — the trace quotes server responses and page
/// URLs — so the output is fenced and labeled untrusted by `RescuePrompts` and
/// never reaches the instructions. Degrades to nil whenever the trace is absent
/// (older failures, extension-side failures not yet flushed), and the prompt
/// then falls back to its plain form with no evidence section.
enum RescueFailureEvidence {

    /// One parsed trace line. Timestamps are dropped on the way out — they cost
    /// tokens and the ORDER already carries the only temporal fact that matters.
    struct Line: Equatable {
        var category: String
        var message: String
    }

    /// The evidence body for `trace`, capped at `maxCharacters`, or nil when
    /// there is nothing usable. The caller fences it.
    static func build(trace: String?, maxCharacters: Int) -> String? {
        guard let trace, maxCharacters > 0 else { return nil }
        let parsed = parse(trace)
        guard !parsed.isEmpty else { return nil }
        let attempt = lastAttempt(in: parsed)
        let deduped = deduplicate(attempt)
        let text = fit(deduped, within: maxCharacters)
        return text.isEmpty ? nil : text
    }

    // MARK: - Parsing

    /// Splits `ISO8601 [category] message` lines. A line that doesn't match the
    /// shape is kept verbatim as a category-less message rather than dropped —
    /// an unrecognized writer's line is still evidence.
    static func parse(_ trace: String) -> [Line] {
        trace.split(separator: "\n").compactMap { raw -> Line? in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, line != "…(trimmed)" else { return nil }
            guard let open = line.firstIndex(of: "["),
                  let close = line[open...].firstIndex(of: "]") else {
                return Line(category: "", message: line)
            }
            let category = String(line[line.index(after: open)..<close])
            let message = line[line.index(after: close)...]
                .trimmingCharacters(in: .whitespaces)
            guard !message.isEmpty else { return nil }
            return Line(category: category, message: message)
        }
    }

    /// The LAST attempt's lines. A trace accumulates every retry, and the newest
    /// pass is the one whose evidence is still true; older passes ran against
    /// older code. When no boundary marker is recognizable the whole trace is
    /// returned — the budget trim below keeps the newest end of it anyway.
    static func lastAttempt(in lines: [Line]) -> [Line] {
        guard let index = lines.lastIndex(where: { isAttemptBoundary($0) })
        else { return lines }
        let slice = Array(lines[index...])
        // A boundary as the very last line segments off nothing worth reading;
        // keep the whole trace rather than a lone header.
        return slice.count > 1 ? slice : lines
    }

    /// A boundary is a writer announcing it is starting a pass over the URL.
    ///
    /// Deliberately prefix-matched on a small VERB vocabulary rather than an
    /// exact string, and matched both against the whole message and against
    /// whatever follows a leading `<subsystem>: ` — the shape both real writers
    /// use today is `ingest: begin <url> source=…` (`SavesIngestor` and
    /// `ShareSurfaceDriver`), and that recorder is maintained independently of
    /// this parser. A missed boundary degrades to "keep everything", never to a
    /// wrong split, so the tolerance is free.
    static func isAttemptBoundary(_ line: Line) -> Bool {
        // A previous RESCUE is not a fresh pass over the URL — it is part of the
        // evidence about the pass that preceded it. Its own "start host=…" line
        // would otherwise segment away the fetch and bypass record that is the
        // most useful thing in the file, leaving the next rescue reading nothing
        // but the last rescue's narration of itself.
        guard line.category != "rescue" else { return false }
        return isAttemptBoundary(line.message)
    }

    static func isAttemptBoundary(_ message: String) -> Bool {
        let lower = message.lowercased()
        if Self.boundaryVerbs.contains(where: { lower.hasPrefix($0) }) { return true }
        guard let colon = lower.range(of: ": ") else { return false }
        let body = lower[colon.upperBound...]
        return Self.boundaryVerbs.contains { body.hasPrefix($0) }
    }

    static let boundaryVerbs = ["begin ", "start ", "attempt ", "saving ", "re-ingest ", "retry "]

    // MARK: - Compression

    /// Collapses repeated (category, message) pairs anywhere in the run into one
    /// line with a count. A ladder that tries the same strategy against eight
    /// mirror hosts writes eight near-identical lines; the model needs to know it
    /// happened, not eight times over.
    static func deduplicate(_ lines: [Line]) -> [String] {
        var counts: [String: Int] = [:]
        var order: [String] = []
        for line in lines {
            let text = line.category.isEmpty ? line.message : "[\(line.category)] \(line.message)"
            if counts[text] == nil { order.append(text) }
            counts[text, default: 0] += 1
        }
        return order.map { text in
            let count = counts[text] ?? 1
            return count > 1 ? "\(text) (×\(count))" : text
        }
    }

    /// Fits the lines into `maxCharacters`: low-signal lines go first, then the
    /// OLDEST survivors, so what's left is the most recent and most diagnostic.
    static func fit(_ lines: [String], within maxCharacters: Int) -> String {
        var kept = lines
        if length(of: kept) > maxCharacters {
            kept = kept.filter { hasSignal($0) }
        }
        while length(of: kept) > maxCharacters, !kept.isEmpty {
            kept.removeFirst()
        }
        // A single line longer than the whole budget is still worth a prefix.
        if kept.isEmpty, let last = lines.last {
            return String(last.prefix(maxCharacters))
        }
        return kept.joined(separator: "\n")
    }

    private static func length(of lines: [String]) -> Int {
        guard !lines.isEmpty else { return 0 }
        return lines.reduce(0) { $0 + $1.count } + lines.count - 1
    }

    /// Whether a line says something about WHY the save failed, as opposed to
    /// narrating progress. Substring-matched because the writers phrase things
    /// differently ("status=403", "http 403", "blocked by").
    static func hasSignal(_ line: String) -> Bool {
        let lower = line.lowercased()
        return Self.signalTokens.contains { lower.contains($0) }
    }

    static let signalTokens = [
        "status", "http", "error", "fail", "block", "denied", "refus", "redirect",
        "timeout", "timed out", "bypass", "strateg", "paywall", "captcha", "archive",
        "asset", "resolve", "empty", "reject", "offline", "unreadable", "not readable",
        "403", "401", "404", "410", "429", "5xx", "500", "503", "captured", "no ",
    ]

    // MARK: - The failure sentence

    /// One or two lines naming what already went wrong, built from the RECORDED
    /// reason. The evidence excerpt holds the detail; this is the headline the
    /// model reads even when no trace exists.
    static func failureSentence(
        kind: RescueRequest.FailureKind, reason: SaveFailureReason?
    ) -> String {
        guard let reason else { return fallbackSentence(kind) }
        switch reason {
        case .offline:
            return "the device had no network connection when the save ran"
        case .timedOut:
            return "the fetch timed out"
        case let .httpStatus(code):
            switch code {
            case 401, 403:
                return "the server refused the app's request with HTTP \(code) — a browser identity or a different route may get through"
            case 404, 410:
                return "the server answered HTTP \(code): this exact URL is gone, so any rescue has to find the content elsewhere"
            case 429:
                return "the server answered HTTP 429 (rate limited / bot challenge)"
            case 500...599:
                return "the server answered HTTP \(code) — its own fault, not the request's"
            default:
                return "the server answered HTTP \(code)"
            }
        case let .network(detail):
            return "the connection failed: \(detail)"
        case .notReadable:
            return "the page loaded but carried no article text"
        case .notContent:
            return "the page is a listing or index, not a single piece of content"
        case .notHTML:
            return "the response was not decodable as HTML"
        case .tooLarge:
            return "the response body was too large to hold"
        case .noMediaFound:
            return "no video/image/audio file could be found on the page"
        case .couldNotSave:
            return "the content was read but could not be stored"
        case .subscribeRedirect:
            return "the site redirected the article request to its own subscribe/sign-in page, so the article was never served"
        case .noTranscriptSource:
            return "a transcript was asked for, but no plugin found captions or a recording to transcribe"
        case let .transcriptionFailed(detail):
            return "the recording could not be transcribed: \(detail)"
        case .unknown:
            return fallbackSentence(kind)
        }
    }

    /// A generic sentence for the reason-less case: an older failure recorded
    /// before the sidecar carried a `SaveFailureReason`.
    private static func fallbackSentence(_ kind: RescueRequest.FailureKind) -> String {
        switch kind {
        case .articleFailed:
            return "reading the page as an article produced no usable text"
        case .productNoPrice:
            return "no price could be extracted from the page"
        case .mediaNoAssets:
            return "no video/image/audio file could be found on the page"
        }
    }
}
