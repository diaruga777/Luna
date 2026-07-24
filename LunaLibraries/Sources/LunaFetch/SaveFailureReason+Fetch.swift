//
//  SaveFailureReason+Fetch.swift
//  LunaFetch
//

import Foundation
import LunaModels

public extension SaveFailureReason {

    /// Classifies whatever a fetch threw into the coarse reason a failed card
    /// shows. Lives in LunaFetch (not LunaModels) so the model tier never has to
    /// know about `ArticleFetcher.FetchError`; every fetch-then-extract caller
    /// maps through this ONE function so two surfaces can't word the same
    /// failure differently.
    init(fetchError error: Error) {
        if let fetchError = error as? ArticleFetcher.FetchError {
            switch fetchError {
            case let .badResponse(status):
                self = status.map { .httpStatus($0) } ?? .unknown
            case .notHTML:
                self = .notHTML
            case .tooLarge:
                self = .tooLarge
            }
            return
        }
        let urlError = error as? URLError
        switch urlError?.code {
        case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff:
            self = .offline
        case .timedOut:
            self = .timedOut
        case .none:
            self = .unknown
        case .some(let code):
            // Everything else transport-level (DNS, TLS, refused, redirect
            // loops) keeps its localized description: it's already a sentence,
            // and inventing a case per URLError code buys nothing.
            _ = code
            self = .network(error.localizedDescription)
        }
    }
}
