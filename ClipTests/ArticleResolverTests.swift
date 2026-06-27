//
//  ArticleResolverTests.swift
//  ClipTests
//

import ClipModels
import XCTest
@testable import Clip

final class ArticleResolverTests: XCTestCase {

    /// A paragraph block of `length` characters.
    private func content(title: String, bodyLength: Int) -> ArticleContent {
        let body = String(repeating: "a", count: bodyLength)
        return ArticleContent(title: title, blocks: [.init(kind: .paragraph, text: body, links: [])])
    }

    /// An `ExtractedArticle` of `bodyLength` characters with `title`.
    private func extracted(title: String, bodyLength: Int, html: String) -> ExtractedArticle {
        ExtractedArticle(content: content(title: title, bodyLength: bodyLength), sourceHTML: html)
    }

    func testDirectReadableWinsAndSkipsArchive() {
        let direct = content(title: "Real", bodyLength: 2000)
        let result = ArticleResolver.resolution(
            direct: ExtractedArticle(content: direct, sourceHTML: "<html>direct</html>"), archived: nil)
        XCTAssertEqual(result, .readable(direct, html: "<html>direct</html>"))
    }

    func testArchiveReadableUsedWhenDirectIsStub() {
        let directStub = extracted(title: "Paywalled", bodyLength: 50, html: "<stub>")
        let archived = content(title: "Paywalled", bodyLength: 2000)
        let result = ArticleResolver.resolution(
            direct: directStub, archived: ExtractedArticle(content: archived, sourceHTML: "<archive>"))
        XCTAssertEqual(result, .readable(archived, html: "<archive>"))
    }

    /// FT-shaped: the direct fetch returns a titled subscription stub and the
    /// archive fetch fails entirely — the title must survive as `.paywalled`.
    func testDirectStubTitleSurvivesWhenArchiveFails() {
        let directStub = extracted(title: "FT Headline", bodyLength: 80, html: "<stub>")
        let result = ArticleResolver.resolution(direct: directStub, archived: nil)
        XCTAssertEqual(result, .paywalled(title: "FT Headline"))
    }

    /// WSJ-shaped: the direct fetch 401s (no content at all) but the archive
    /// snapshot, while itself paywalled, still carries the real title.
    func testArchiveTitleUsedWhenDirectFails() {
        let archivedStub = extracted(title: "WSJ Headline", bodyLength: 120, html: "<archive>")
        let result = ArticleResolver.resolution(direct: nil, archived: archivedStub)
        XCTAssertEqual(result, .paywalled(title: "WSJ Headline"))
    }

    func testDirectTitlePreferredOverArchiveTitle() {
        let directStub = extracted(title: "Canonical", bodyLength: 40, html: "<stub>")
        let archivedStub = extracted(title: "Archive Copy", bodyLength: 60, html: "<archive>")
        let result = ArticleResolver.resolution(direct: directStub, archived: archivedStub)
        XCTAssertEqual(result, .paywalled(title: "Canonical"))
    }

    func testPlaceholderTitleIsNotTreatedAsReal() {
        let directStub = extracted(title: "Untitled", bodyLength: 40, html: "<stub>")
        let result = ArticleResolver.resolution(direct: directStub, archived: nil)
        XCTAssertEqual(result, .unreadable)
    }

    func testNothingReachableIsUnreadable() {
        let result = ArticleResolver.resolution(direct: nil, archived: nil)
        XCTAssertEqual(result, .unreadable)
    }

    // MARK: - silent-strategy loop: advance-on-failure (GOAL 2 routing reliability)

    /// A long readable article body so extraction clears the readability gate.
    private func readableHTML(_ marker: String) -> String {
        let paragraph = "<p>" + String(repeating: "An ordinary readable sentence about \(marker). ", count: 30) + "</p>"
        return "<html><head><title>Real \(marker)</title></head><body><article>\(paragraph)\(paragraph)</article></body></html>"
    }

    /// A locked teaser (short body + schema.org lock) that must be REJECTED.
    private let lockedHTML = "<html><head><title>NYT Headline</title></head><body><p>Lede only.</p>"
        + #"<script type="application/ld+json">{"@type":"NewsArticle","isAccessibleForFree":false}</script>"#
        + "</body></html>"

    /// A `BypassRunning` stub that returns readable HTML ONLY for a designated
    /// strategy and nil (failure) for every earlier one — so the resolver loop's
    /// advance-on-failure is asserted deterministically without the network.
    private final class StubRunner: BypassRunning {
        let succeedOn: BypassStrategy
        let readable: ArticleContent
        let html: String
        private(set) var attempted: [BypassStrategy] = []

        init(succeedOn: BypassStrategy, readable: ArticleContent, html: String) {
            self.succeedOn = succeedOn
            self.readable = readable
            self.html = html
        }

        func run(_ strategy: BypassStrategy, url: URL, directHTML: String?) async -> ExtractedArticle? {
            attempted.append(strategy)
            return strategy == succeedOn ? ExtractedArticle(content: readable, sourceHTML: html) : nil
        }
    }

    /// A paywalled article runs the first-party silent chain IN ORDER and stops at
    /// the first readable result — here the Googlebot read (the WSJ fix), so the
    /// later strategies and the archive flow are never reached.
    func testResolverRunsSilentChainAndStopsAtFirstSuccess() async {
        let articleURL = URL(string: "https://www.wsj.com/articles/x_199845b1.html")!
        let fetcher = MockArticleFetcher()
        fetcher.htmlByURL[articleURL.absoluteString] = lockedHTML   // direct read = locked
        let runner = StubRunner(
            succeedOn: .userAgent(.googlebotDesktop),
            readable: ArticleContent(title: "Real", blocks: [
                .init(kind: .paragraph, text: String(repeating: "a", count: 2000), links: []),
            ]), html: readableHTML("googlebot"))

        let result = await ArticleResolver.resolve(
            url: articleURL, fetcher: fetcher, runner: runner, nonArchiveBypass: true)
        if case .readable = result {} else { XCTFail("expected readable, got \(result)") }
        // jsonLDBody first (failed), then the Googlebot read (succeeded) — and stop.
        XCTAssertEqual(runner.attempted, [.jsonLDBody, .userAgent(.googlebotDesktop)])
    }

    func testResolverRejectsLockedSilentResultAndAdvances() async {
        let articleURL = URL(string: "https://www.wsj.com/articles/x_199845b1.html")!
        let fetcher = MockArticleFetcher()
        fetcher.htmlByURL[articleURL.absoluteString] = lockedHTML

        // A silent strategy can still return a long-but-locked page; it must be
        // rejected and the loop must advance to the next strategy.
        final class LockedThenReadableRunner: BypassRunning {
            let lockedHTML: String
            let readable: ExtractedArticle
            private(set) var attempts = 0
            init(lockedHTML: String, readable: ExtractedArticle) {
                self.lockedHTML = lockedHTML
                self.readable = readable
            }
            func run(_ strategy: BypassStrategy, url: URL, directHTML: String?) async -> ExtractedArticle? {
                attempts += 1
                // First strategy: a body that's long enough but declares locked → must be rejected.
                if attempts == 1 {
                    return ExtractedArticle(content: ArticleContent(title: "Locked", blocks: [
                        .init(kind: .paragraph, text: String(repeating: "a", count: 2000), links: []),
                    ]), sourceHTML: lockedHTML)
                }
                return readable
            }
        }
        let readable = ExtractedArticle(content: ArticleContent(title: "Real", blocks: [
            .init(kind: .paragraph, text: String(repeating: "a", count: 2000), links: []),
        ]), sourceHTML: readableHTML("ok"))
        let runner = LockedThenReadableRunner(lockedHTML: lockedHTML, readable: readable)

        let result = await ArticleResolver.resolve(
            url: articleURL, fetcher: fetcher, runner: runner, nonArchiveBypass: true)
        // First silent attempt = long-but-locked (rejected); second = readable (taken).
        XCTAssertEqual(result, .readable(readable.content, html: readable.sourceHTML))
        XCTAssertEqual(runner.attempts, 2)
    }

    /// When EVERY silent strategy fails (no readable result anywhere) on a host that
    /// carries a title, the resolver parks it as `.paywalled(title)` — it does NOT
    /// stop early or return readable. The archive fallback also fails here.
    func testResolverFallsAllTheWayToPaywalledWhenEveryStrategyFails() async {
        let articleURL = URL(string: "https://www.wsj.com/articles/secret_199845b1.html")!
        let fetcher = MockArticleFetcher()
        // Direct returns a titled locked teaser; every silent strategy + archive fail.
        fetcher.htmlByURL[articleURL.absoluteString] =
            "<html><head><title>WSJ Story</title></head><body><p>Lede only. Subscribe to read.</p></body></html>"
        let result = await ArticleResolver.resolve(
            url: articleURL, fetcher: fetcher, nonArchiveBypass: true)
        // WSJ's title survives; the body never became readable.
        XCTAssertEqual(result, .paywalled(title: "WSJ Story"))
    }
}
