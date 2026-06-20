//
//  ContentKind.swift
//  ReaderKit
//

import Foundation

/// The single classification result for a saved URL — exhaustive over every kind a
/// saved URL can be, so no surface can "forget" a kind (the compiler forces a
/// switch to handle each). Carries only the MINIMAL evidence that named the kind —
/// never extracted content, never a fetched price, never bypass state (those belong
/// to the processing stage). Produced by `Classifier.classify`; consumed by the
/// per-kind processing components (a later stage).
enum ContentKind: Equatable {
    /// An ordinary, readable web article.
    case article
    /// A known-locked article. `hardHost` ⇒ a hard-paywall host that only the
    /// archive-CAPTCHA route can read (vs a soft/metered wall detected from HTML).
    case paywalledArticle(hardHost: Bool)
    /// A purchasable product page. `signal` records HOW it was named (a trusted
    /// known-shop host vs structured data vs a fuzzy heuristic score).
    case product(ProductSignal)
    /// A social post (X, Bluesky, Reddit, Instagram). `itemID` is nil for an
    /// opaque/short link that still classifies as the platform.
    case social(ContentPlatform, itemID: String?)
    /// A video (YouTube today; TikTok / Facebook video also map here).
    case video(ContentPlatform, itemID: String?)
    /// A music track / podcast episode. `service` is the streaming provider when
    /// known; `itemID` may be nil for an opaque page.
    case audio(ContentPlatform, MusicProvider?, itemID: String?)
    /// An imported file (pdf / epub / …). Carries the document type string the save
    /// flow stamped, which always wins over any URL/HTML signal.
    case document(type: String)
    /// Table miss + heuristics inconclusive — the caller proceeds to web processing
    /// (fetch + re-classify with HTML, resolve, price, bypass).
    case undetermined
}

/// How a product page was named — a deterministic table hit vs structured markup
/// vs a fuzzy heuristic score. Lets the processing stage trust a table/structured
/// hit and re-confirm a low-confidence heuristic hit.
enum ProductSignal: Equatable {
    /// The host is a known shop (deterministic table row) — most trusted.
    case knownShopHost
    /// Machine-readable price markup (JSON-LD `Product` / OG / microdata).
    case structuredData
    /// A combination of fuzzy retail signals scored at least the minimum.
    case heuristicScore(Int)
}
