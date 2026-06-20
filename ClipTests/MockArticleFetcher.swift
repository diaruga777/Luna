//
//  MockArticleFetcher.swift
//  ClipTests
//

import Foundation
@testable import Clip

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
            case plain, userAgent, referer, freshSession, waybackRaw, jina, archived
        }
    }

    private(set) var calls: [Call] = []
    /// HTML returned for a given absolute URL string. A missing entry throws.
    var htmlByURL: [String: String] = [:]
    /// URLs (absolute strings) that should throw a fetch error instead of returning.
    var failingURLs: Set<String> = []

    enum MockError: Error { case noStub }

    private func html(for url: URL) throws -> String {
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

    func fetchJinaReader(for url: URL) async throws -> String {
        calls.append(.init(url: url, userAgent: nil, referer: nil, xForwardedFor: nil,
                           noCookies: false, kind: .jina))
        return try html(for: url)
    }

    func fetchArchivedHTML(for url: URL) async throws -> String {
        calls.append(.init(url: url, userAgent: nil, referer: nil, xForwardedFor: nil,
                           noCookies: false, kind: .archived))
        return try html(for: url)
    }
}
