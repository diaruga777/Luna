//
//  MockArticleFetcher.swift
//  LunaTests
//

import LunaArticleIngest
import LunaPaywallBypass
import LunaFetch
import Foundation
@testable import Luna

/// A test double for `HTMLFetching` that records every call (URL + headers it was
/// asked to send) and returns canned HTML keyed by the requested URL, so
/// `BypassRunner` / `ArticleResolver` can be exercised without the network.
final class MockArticleFetcher: HTMLFetching {

    /// One recorded fetch and the request shape it was made with.
    struct Call: Equatable {
        var url: URL
        var userAgent: String?
        var referer: String?
        var xForwardedFor: String?
        var noCookies: Bool
        var kind: Kind

        enum Kind: String, Equatable {
            case plain, userAgent, referer, freshSession, waybackRaw, waybackPrePaywall, jina
        }
    }

    private(set) var calls: [Call] = []
    /// HTML returned for a given absolute URL string. A missing entry throws.
    var htmlByURL: [String: String] = [:]
    /// HTML returned specifically for a referer-spoofed fetch of a URL (so a test can
    /// serve a readable page to the Drudge/Google referer while the direct read stays
    /// locked). Falls back to `htmlByURL` when absent.
    var refererHTMLByURL: [String: String] = [:]
    /// HTML returned specifically for the OLDEST-snapshot Wayback fetch of a URL (so a
    /// test can serve a pre-paywall archive capture while the direct read and the newest
    /// capture stay walled). Falls back to `htmlByURL` when absent.
    var prePaywallHTMLByURL: [String: String] = [:]
    /// URLs (absolute strings) that should throw a fetch error instead of returning.
    var failingURLs: Set<String> = []
    /// URLs (absolute strings) that should throw a SPECIFIC `ArticleFetcher.FetchError`
    /// — e.g. the `.subscribeRedirect` a premium News Corp article answers with, which
    /// callers treat differently from a generic failure.
    var fetchErrorsByURL: [String: ArticleFetcher.FetchError] = [:]

    enum MockError: Error { case noStub }

    private func html(for url: URL) throws -> String {
        if let error = fetchErrorsByURL[url.absoluteString] { throw error }
        if failingURLs.contains(url.absoluteString) { throw MockError.noStub }
        guard let html = htmlByURL[url.absoluteString] else { throw MockError.noStub }
        return html
    }

    func fetchHTML(from url: URL) async throws -> String {
        calls.append(.init(url: url, userAgent: nil, referer: nil, xForwardedFor: nil,
                           noCookies: false, kind: .plain))
        return try html(for: url)
    }

    func fetchHTML(from url: URL, userAgent: String, xForwardedFor: String?) async throws -> String {
        calls.append(.init(url: url, userAgent: userAgent, referer: nil,
                           xForwardedFor: xForwardedFor, noCookies: false, kind: .userAgent))
        return try html(for: url)
    }

    func fetchHTML(from url: URL, referer: String) async throws -> String {
        calls.append(.init(url: url, userAgent: nil, referer: referer, xForwardedFor: nil,
                           noCookies: false, kind: .referer))
        if let refererHTML = refererHTMLByURL[url.absoluteString] { return refererHTML }
        return try html(for: url)
    }

    func fetchHTMLWithoutCookies(from url: URL) async throws -> String {
        calls.append(.init(url: url, userAgent: nil, referer: nil, xForwardedFor: nil,
                           noCookies: true, kind: .freshSession))
        return try html(for: url)
    }

    func fetchWaybackRawHTML(for url: URL) async throws -> String {
        calls.append(.init(url: url, userAgent: nil, referer: nil, xForwardedFor: nil,
                           noCookies: false, kind: .waybackRaw))
        return try html(for: url)
    }

    func fetchWaybackPrePaywallHTML(for url: URL) async throws -> String {
        calls.append(.init(url: url, userAgent: nil, referer: nil, xForwardedFor: nil,
                           noCookies: false, kind: .waybackPrePaywall))
        if let prePaywallHTML = prePaywallHTMLByURL[url.absoluteString] { return prePaywallHTML }
        return try html(for: url)
    }

    func fetchJinaReader(for url: URL) async throws -> String {
        calls.append(.init(url: url, userAgent: nil, referer: nil, xForwardedFor: nil,
                           noCookies: false, kind: .jina))
        return try html(for: url)
    }

}
