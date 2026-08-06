//
//  LinkPreviewFetcher.swift
//  LunaFetch
//

import Foundation
import LunaHTMLClassification

/// What a link looks like before Luna has saved it: the headline, the publisher,
/// and a cover image URL. Any of the three may be missing.
public struct LinkPreview: Equatable, Sendable {
    public var title: String?
    public var siteName: String?
    public var imageURL: URL?

    public init(title: String? = nil, siteName: String? = nil, imageURL: URL? = nil) {
        self.title = title
        self.siteName = siteName
        self.imageURL = imageURL
    }

    public var isEmpty: Bool { title == nil && siteName == nil && imageURL == nil }
}

/// One `<head>`-shaped read that answers "what IS this link" — for a list of URLs
/// Luna hasn't saved yet, which is the import review sheet's whole problem.
///
/// Deliberately one fetch and two pure parses: `PageMetadataFetcher`'s title/site
/// reading and `LeadImageExtractor`'s `og:image` walk, over the same HTML, so a
/// row costs a single request. `PageMetadataFetcher` alone would cost a second
/// one for the image, and its homepage fallback (which exists to NAME a failed
/// save) is deliberately not used here: a review row headed by the publisher's
/// homepage title would be a wrong answer dressed as a right one, and the row
/// already falls back to showing the URL.
public struct LinkPreviewFetcher {

    private let fetcher: HTMLFetching

    public init(fetcher: HTMLFetching = ArticleFetcher()) {
        self.fetcher = fetcher
    }

    /// Best-effort preview for `url`. Throws only what the fetch throws, so a
    /// caller can tell "this page didn't answer" (leave the row as a URL) from
    /// "there is no network" (stop asking).
    public func fetchPreview(for url: URL) async throws -> LinkPreview {
        let html = try await fetcher.fetchHTML(from: url)
        let metadata = PageMetadataFetcher.metadata(inHTML: html)
        return LinkPreview(
            title: metadata.title,
            siteName: metadata.siteName,
            imageURL: LeadImageExtractor.imageURL(in: html, baseURL: url))
    }
}
