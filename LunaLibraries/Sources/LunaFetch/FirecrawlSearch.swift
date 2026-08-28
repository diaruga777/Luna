//
//  FirecrawlSearch.swift
//  LunaFetch
//

import Foundation
import LunaModels

/// Keyless web search through Firecrawl's `/v2/search` endpoint — the preferred
/// Layer-2 leg of the alternative-seller fan-out
/// (`claudedocs/price-comparison.md`).
///
/// It answers with structured JSON rather than a results page, so there is no
/// markup shape to drift under us and no bot-challenge page to recognize. The
/// price is a budget: keyless traffic is metered PER IP against two independent
/// daily caps (requests and credits — a ten-result search costs two credits)
/// plus a per-minute cap, and every cap answers 429. `FirecrawlSearchCooldown`
/// holds that refusal across processes so the whole device stops asking, and
/// `WebSearchChain` falls back to `DuckDuckGoSearch` for the run.
public enum FirecrawlSearch {

    /// One search result. Firecrawl also returns a `position`, which the array
    /// order already carries.
    public struct Entry: Equatable, Sendable {
        public let url: URL
        public let title: String?
        public let description: String?

        public init(url: URL, title: String?, description: String? = nil) {
            self.url = url
            self.title = title
            self.description = description
        }
    }

    /// What one search attempt produced. `rateLimited` is separate from
    /// `unavailable` because only it may extend the cooldown — a transport
    /// failure or a bad body says nothing about the IP's remaining budget.
    public enum Outcome: Equatable, Sendable {
        case results([Entry])
        case rateLimited(retryAfter: TimeInterval?)
        case unavailable
    }

    public static let endpointURLString = "https://api.firecrawl.dev/v2/search"

    /// Ten results, which is two credits against the keyless daily allowance.
    public static let resultLimit = 10

    /// The deadline Firecrawl applies server-side, in milliseconds. It stays
    /// under the request timeout below, so a slow search returns an answer
    /// rather than dying in transport.
    public static let serverTimeoutMilliseconds = 10_000

    /// The transport deadline, matching `DuckDuckGoSearch`'s.
    public static let requestTimeout: TimeInterval = 12

    /// Runs one search. `location` biases results to a market (e.g. "Australia").
    public static func results(
        forQuery query: String, location: String? = nil
    ) async -> Outcome {
        guard let url = URL(string: endpointURLString),
              let body = requestBody(forQuery: query, location: location),
              LiveNetworkPolicy.allows(url, context: "FirecrawlSearch.results")
        else { return .unavailable }
        var request = URLRequest(url: url, timeoutInterval: requestTimeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = body
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse
        else { return .unavailable }
        return outcome(
            statusCode: http.statusCode,
            retryAfterHeader: http.value(forHTTPHeaderField: "Retry-After"),
            body: data)
    }

    /// The request body. `sources: ["web"]` drops the news and image tiers,
    /// which cost credits the fan-out has no use for.
    public static func requestBody(forQuery query: String, location: String?) -> Data? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var payload: [String: Any] = [
            "query": trimmed,
            "limit": resultLimit,
            "sources": ["web"],
            "timeout": serverTimeoutMilliseconds,
        ]
        if let location, !location.isEmpty { payload["location"] = location }
        return try? JSONSerialization.data(withJSONObject: payload)
    }

    /// Status + headers + body → one outcome. Pure, so the mapping is asserted
    /// without a server: only `results(forQuery:location:)` above touches the
    /// network.
    public static func outcome(
        statusCode: Int, retryAfterHeader: String?, body: Data?, now: Date = Date()
    ) -> Outcome {
        if statusCode == rateLimitStatusCode {
            return .rateLimited(retryAfter: retryAfterSeconds(retryAfterHeader, now: now))
        }
        guard (200..<300).contains(statusCode), let body,
              let entries = entries(inJSON: body)
        else { return .unavailable }
        return .results(entries)
    }

    /// The status every keyless cap answers with — the per-minute one and both
    /// daily ones.
    static let rateLimitStatusCode = 429

    /// The results in `data`, deduplicated by URL and in response order, or nil
    /// when the body is not a successful Firecrawl answer.
    ///
    /// Firecrawl reports failure in the BODY (`"success": false`) as well as in
    /// the status, so a 200 carrying a failure must not read as an empty search.
    public static func entries(inJSON data: Data) -> [Entry]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["success"] as? Bool != false,
              let payload = root["data"] as? [String: Any]
        else { return nil }
        guard let web = payload["web"] as? [[String: Any]] else { return [] }
        var seen: Set<String> = []
        return web.compactMap { result -> Entry? in
            guard let urlString = result["url"] as? String,
                  seen.insert(urlString).inserted,
                  let url = URL(string: urlString), url.host != nil
            else { return nil }
            return Entry(
                url: url,
                title: nonEmpty(result["title"] as? String),
                description: nonEmpty(result["description"] as? String))
        }
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }

    /// `Retry-After` in either of its two spellings: a count of seconds, or an
    /// HTTP date. An unparseable value answers nil, and the cooldown then falls
    /// back to its own escalation.
    static func retryAfterSeconds(_ raw: String?, now: Date = Date()) -> TimeInterval? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        if let seconds = TimeInterval(trimmed) {
            return seconds > 0 ? seconds : nil
        }
        guard let date = httpDateFormatter.date(from: trimmed) else { return nil }
        let interval = date.timeIntervalSince(now)
        return interval > 0 ? interval : nil
    }

    private static let httpDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter
    }()
}
