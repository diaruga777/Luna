//
//  RescueSearch.swift
//  LunaURLRescue
//

import Foundation
import LunaFetch
import LunaModels

/// One live web-search result offered to the model. Deliberately a plain DTO:
/// the search PROVIDER is an injected closure so the engine's search leg is
/// testable without a network, and so nothing about DuckDuckGo's shape leaks
/// into the prompt code.
public struct RescueSearchResult: Equatable {
    public let url: URL
    public let title: String?

    public init(url: URL, title: String? = nil) {
        self.url = url
        self.title = title
    }
}

/// Runs the search leg's one web query. Injected so a test can hand the engine a
/// fixed result list instead of reaching the live web.
public protocol RescueSearching {
    func searchResults(forQuery query: String) async -> [RescueSearchResult]
}

/// The default provider: the keyless DuckDuckGo HTML search LunaFetch already
/// owns (the same primitive the seller fan-out and the post finder use).
public struct DuckDuckGoRescueSearch: RescueSearching {
    public init() {}

    public func searchResults(forQuery query: String) async -> [RescueSearchResult] {
        await DuckDuckGoSearch.entries(forQuery: query)
            .map { RescueSearchResult(url: $0.url, title: $0.title) }
    }
}

/// Host policy for the search leg.
///
/// The model never invents a URL here — it SELECTS from a list the engine built
/// from live results, and the validator relaxes its reroute-host rule only for a
/// URL in that list. Which results reach the list is this type's job, and it is
/// deliberately stricter than "anything the search returned":
///
/// - **Same registrable domain**: always allowed. A different path on the same
///   site is the ordinary reroute case, arrived at by search instead of by
///   reading the digest.
/// - **Cross-domain**: allowed only when the result title strongly matches the
///   title Luna recovered for the failed page. A syndicated copy or a canonical
///   home is the same article; a title that does not match is a different
///   THING — another seller's listing, another creator's post — and never
///   crosses a domain.
enum RescueSearchCandidates {

    /// At most this many results are shown to the model — the on-device window
    /// is small and a longer list buys nothing but tokens.
    static let maxResults = 5

    static func filter(
        _ results: [RescueSearchResult], request: RescueRequest,
        registrableDomain: (String) -> String
    ) -> [RescueSearchResult] {
        let originalDomain = registrableDomain(request.url.host?.lowercased() ?? "")
        var kept: [RescueSearchResult] = []
        for result in results {
            guard result.url.scheme?.lowercased() == "https" else { continue }
            guard result.url.absoluteString != request.url.absoluteString else { continue }
            let domain = registrableDomain(result.url.host?.lowercased() ?? "")
            if !domain.isEmpty, domain == originalDomain {
                kept.append(result)
            } else if titlesMatch(result.title, request.pageTitle) {
                kept.append(result)
            }
            if kept.count >= maxResults { break }
        }
        return kept
    }

    /// Whether a search result is recognizably the SAME piece of writing: at
    /// least `minimumOverlap` of the shorter title's significant words appear in
    /// the other. Word-set overlap rather than string equality because a
    /// syndicated copy re-headlines ("… | The Guardian" vs "… - Reuters") while
    /// keeping the sentence.
    static func titlesMatch(_ candidate: String?, _ known: String?) -> Bool {
        guard let candidate, let known else { return false }
        let a = significantWords(candidate)
        let b = significantWords(known)
        guard a.count >= minimumWords, b.count >= minimumWords else { return false }
        let shared = a.intersection(b).count
        let smaller = min(a.count, b.count)
        return Double(shared) / Double(smaller) >= minimumOverlap
    }

    static let minimumOverlap = 0.6
    static let minimumWords = 3

    /// Lowercased words of 3+ characters, minus the stop words every headline
    /// shares — otherwise "the a of to" alone can carry a match.
    static func significantWords(_ title: String) -> Set<String> {
        Set(title.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { $0.count >= 3 && !stopWords.contains($0) })
    }

    static let stopWords: Set<String> = [
        "the", "and", "for", "with", "that", "this", "you", "your", "are",
        "was", "were", "has", "have", "from", "but", "not", "its", "his", "her",
        "com", "www", "html", "how", "why", "what", "when",
    ]
}
