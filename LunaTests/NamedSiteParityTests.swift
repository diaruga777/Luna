//
//  NamedSiteParityTests.swift
//  LunaTests
//

import LunaIngest
import LunaHTMLClassification
import LunaURLClassification
import LunaModels
import XCTest
@testable import Luna

/// Stage-4 named-site fixtures + the SINGLE data-driven parity table. Every row is a
/// real-shaped fixture/URL → its expected `Outcome`, driven through the REAL
/// `IngestPipeline` (so `URLUnwrapper` → `Classifier` → per-kind processing all run)
/// with a mock fetcher and a nil render tier — no live network. The headline
/// guarantee: each row produces the IDENTICAL `Outcome` regardless of the
/// `IngestInput.source`, because there is one pipeline shared by every surface.
///
/// Coverage:
///   • Shops → `.product` with the right price + currency: amazon (.com buy-box-vs-
///     list-price AND .com.au TLD-currency), target, walmart.
///   • News → `.article` (readable variant) or `.needsArchive` (hard-paywall stub):
///     nytimes, washingtonpost, wsj, smh.com.au.
///   • Social / video / audio → `.social` / `.video` / `.audio`, NEVER `.article`:
///     youtube, x, instagram, tiktok, facebook, reddit, bluesky, spotify, apple.
final class NamedSiteParityTests: XCTestCase {

    // MARK: - Expectation model

    /// What a fixture/URL must classify into. Mirrors the `Outcome` cases the parity
    /// table asserts (the price-bearing ones carry the expected amount + currency).
    private enum Expected: Equatable {
        case product(amount: String, currency: String)
        case article
        case needsArchive
        case social(ContentPlatform, itemID: String?)
        case video(ContentPlatform, itemID: String?)
        case audio(ContentPlatform, service: MusicProvider?)
    }

    /// One row of the parity table: a named site, its URL, the fixture HTML (nil for
    /// platform URLs decided by URL alone), and the expected outcome.
    private struct Row {
        let site: String
        let url: String
        let fixture: String?
        let expected: Expected
    }

    private func url(_ string: String) -> URL {
        guard let url = URL(string: string) else { fatalError("bad test URL: \(string)") }
        return url
    }

    private func fixtureHTML(_ name: String?) -> String? {
        guard let name else { return nil }
        return BypassFixtures.html(name)
    }

    /// Asserts the produced `Outcome` matches the row's `Expected`.
    private func assertMatches(_ outcome: Outcome, _ expected: Expected, _ site: String) {
        switch (outcome, expected) {
        case let (.product(info, _), .product(amount, currency)):
            XCTAssertEqual(info.priceAmount, Decimal(string: amount), "\(site): price amount")
            XCTAssertEqual(info.priceCurrency, currency, "\(site): currency")
        case (.article, .article):
            break
        case (.needsArchive, .needsArchive):
            break
        case let (.social(platform, itemID), .social(expPlatform, expID)):
            XCTAssertEqual(platform, expPlatform, "\(site): social platform")
            XCTAssertEqual(itemID, expID, "\(site): social itemID")
        case let (.video(platform, itemID), .video(expPlatform, expID)):
            XCTAssertEqual(platform, expPlatform, "\(site): video platform")
            XCTAssertEqual(itemID, expID, "\(site): video itemID")
        case let (.audio(platform, service, _), .audio(expPlatform, expService)):
            XCTAssertEqual(platform, expPlatform, "\(site): audio platform")
            XCTAssertEqual(service, expService, "\(site): audio service")
        default:
            XCTFail("\(site): expected \(expected), got \(outcome)")
        }
    }

    // MARK: - The parity table

    /// Shops → `.product` with the right price + currency. Buy-box (not list price)
    /// for amazon; TLD-derived currency for amazon.com.au.
    private let shops: [Row] = [
        .init(site: "amazon.com.au (buy-box, TLD currency)",
              url: "https://www.amazon.com.au/Mrisata-Rotating-Electric-Machine-Conveyor/dp/B0CWRSYTTK",
              fixture: "Products/amazon-dp.html",
              expected: .product(amount: "39.99", currency: "AUD")),
        .init(site: "amazon.com (buy-box wins over list price)",
              url: "https://www.amazon.com/Acme-Widget/dp/B0ACME1234",
              fixture: "Products/amazon-listprice.html",
              expected: .product(amount: "42.50", currency: "USD")),
        .init(site: "target",
              url: "https://www.target.com/p/mug/-/A-54321",
              fixture: "Products/target-nextdata.html",
              expected: .product(amount: "24.99", currency: "USD")),
        .init(site: "walmart",
              url: "https://www.walmart.com/ip/cooker/123456789",
              fixture: "Products/walmart-nextdata.html",
              expected: .product(amount: "17.88", currency: "USD")),
    ]

    /// News → `.article` (readable) or `.needsArchive` (hard-paywall stub).
    private let news: [Row] = [
        .init(site: "nytimes readable", url: "https://www.nytimes.com/2026/06/20/story.html",
              fixture: "Readable/nytimes-readable.html", expected: .article),
        .init(site: "nytimes paywalled", url: "https://www.nytimes.com/2026/06/20/story.html",
              fixture: "Readable/nytimes-paywalled.html", expected: .needsArchive),
        .init(site: "washingtonpost readable", url: "https://www.washingtonpost.com/2026/06/20/story.html",
              fixture: "Readable/washingtonpost-readable.html", expected: .article),
        .init(site: "washingtonpost paywalled", url: "https://www.washingtonpost.com/2026/06/20/story.html",
              fixture: "Readable/washingtonpost-paywalled.html", expected: .needsArchive),
        .init(site: "wsj readable", url: "https://www.wsj.com/articles/apple-prices",
              fixture: "Readable/wsj-readable.html", expected: .article),
        .init(site: "wsj paywalled", url: "https://www.wsj.com/articles/apple-prices",
              fixture: "Readable/wsj-paywalled.html", expected: .needsArchive),
        .init(site: "smh.com.au readable", url: "https://www.smh.com.au/national/story-20260620.html",
              fixture: "Readable/smh-readable.html", expected: .article),
        .init(site: "smh.com.au paywalled", url: "https://www.smh.com.au/national/story-20260620.html",
              fixture: "Readable/smh-paywalled.html", expected: .needsArchive),
    ]

    /// Social / video / audio → recognized by URL alone, NEVER article-extracted.
    private let platforms: [Row] = [
        .init(site: "youtube", url: "https://www.youtube.com/watch?v=dQw4w9WgXcQ", fixture: nil,
              expected: .video(.youtube, itemID: "dQw4w9WgXcQ")),
        .init(site: "x", url: "https://x.com/jack/status/20", fixture: nil,
              expected: .social(.x, itemID: "20")),
        .init(site: "instagram", url: "https://www.instagram.com/reel/Cx/", fixture: nil,
              expected: .social(.instagram, itemID: "Cx")),
        .init(site: "tiktok", url: "https://www.tiktok.com/@u/video/7212345678901234567", fixture: nil,
              expected: .video(.tiktok, itemID: "7212345678901234567")),
        .init(site: "facebook", url: "https://www.facebook.com/watch/?v=123", fixture: nil,
              expected: .video(.facebook, itemID: "123")),
        .init(site: "reddit", url: "https://www.reddit.com/r/swift/comments/abc/t/", fixture: nil,
              expected: .social(.reddit, itemID: "abc")),
        .init(site: "bluesky", url: "https://bsky.app/profile/a.bsky.social/post/xyz", fixture: nil,
              expected: .social(.bluesky, itemID: "xyz")),
        .init(site: "spotify", url: "https://open.spotify.com/track/abc", fixture: nil,
              expected: .audio(.music, service: .spotify)),
        .init(site: "apple music", url: "https://music.apple.com/us/album/x/1?i=2", fixture: nil,
              expected: .audio(.music, service: .apple)),
    ]

    private var allRows: [Row] { shops + news + platforms }

    // MARK: - Per-site outcome (one source)

    /// Drives one row through the pipeline from `.manual`, asserting the named outcome.
    func testEachNamedSiteProducesExpectedOutcome() async {
        for row in allRows {
            let outcome = await process(row, source: .manual)
            assertMatches(outcome, row.expected, row.site)
        }
    }

    /// A platform URL must NEVER become an article even when article-shaped HTML is
    /// attached — recognition is the classifier's first branch.
    func testPlatformURLsNeverBecomeArticles() async {
        let readableHTML = "<html><head><title>Not An Article</title></head><body><article>"
            + String(repeating: "<p>A long readable paragraph about the subject matter here. </p>", count: 30)
            + "</article></body></html>"
        for row in platforms {
            let outcome = await IngestPipeline.process(
                IngestInput(url: url(row.url), source: .manual, prefetchedHTML: readableHTML),
                timeout: 10, fetcher: MockArticleFetcher())
            if case .article = outcome {
                XCTFail("\(row.site): platform URL was article-extracted — got \(outcome)")
            }
        }
    }

    // MARK: - PARITY: same input, every source → identical Outcome

    /// THE headline guarantee, asserted on the WHOLE named-site table: for each row,
    /// the `Outcome` is identical across every `CaptureSource` (there is one pipeline).
    func testParityAcrossAllSourcesForEveryNamedSite() async {
        for row in allRows {
            var outcomes: [Outcome] = []
            for source in CaptureSource.allCases {
                outcomes.append(await process(row, source: source))
            }
            guard let first = outcomes.first else { return XCTFail("\(row.site): no sources") }
            for outcome in outcomes {
                XCTAssertEqual(outcome, first,
                               "\(row.site): outcome must be identical across all capture sources")
            }
            // And the agreed-upon outcome is the expected one.
            assertMatches(first, row.expected, row.site)
        }
    }

    // MARK: - Driver

    /// Runs the real pipeline for a row from `source`. The fixture HTML is supplied
    /// BOTH as `prefetchedHTML` and keyed in the mock fetcher (so the silent-bypass
    /// leg of a paywalled stub finds no readable HTML and parks for archive), with a
    /// nil render tier (extension-safe). No live network.
    private func process(_ row: Row, source: CaptureSource) async -> Outcome {
        let html = fixtureHTML(row.fixture)
        let fetcher = MockArticleFetcher()
        if let html { fetcher.htmlByURL[row.url] = html }
        return await IngestPipeline.process(
            IngestInput(url: url(row.url), source: source, prefetchedHTML: html),
            timeout: 10, fetcher: fetcher)
    }
}
