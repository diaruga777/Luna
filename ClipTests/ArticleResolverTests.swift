//
//  ArticleResolverTests.swift
//  ClipTests
//

import XCTest
@testable import Clip

final class ArticleResolverTests: XCTestCase {

    /// A paragraph block of `length` characters.
    private func content(title: String, bodyLength: Int) -> ArticleContent {
        let body = String(repeating: "a", count: bodyLength)
        return ArticleContent(title: title, blocks: [.init(kind: .paragraph, text: body, links: [])])
    }

    func testDirectReadableWinsAndSkipsArchive() {
        let direct = content(title: "Real", bodyLength: 1000)
        let result = ArticleResolver.resolution(
            direct: (direct, "<html>direct</html>"), archived: nil)
        XCTAssertEqual(result, .readable(direct, html: "<html>direct</html>"))
    }

    func testArchiveReadableUsedWhenDirectIsStub() {
        let directStub = content(title: "Paywalled", bodyLength: 50)
        let archived = content(title: "Paywalled", bodyLength: 1000)
        let result = ArticleResolver.resolution(
            direct: (directStub, "<stub>"), archived: (archived, "<archive>"))
        XCTAssertEqual(result, .readable(archived, html: "<archive>"))
    }

    /// FT-shaped: the direct fetch returns a titled subscription stub and the
    /// archive fetch fails entirely — the title must survive as `.paywalled`.
    func testDirectStubTitleSurvivesWhenArchiveFails() {
        let directStub = content(title: "FT Headline", bodyLength: 80)
        let result = ArticleResolver.resolution(direct: (directStub, "<stub>"), archived: nil)
        XCTAssertEqual(result, .paywalled(title: "FT Headline"))
    }

    /// WSJ-shaped: the direct fetch 401s (no content at all) but the archive
    /// snapshot, while itself paywalled, still carries the real title.
    func testArchiveTitleUsedWhenDirectFails() {
        let archivedStub = content(title: "WSJ Headline", bodyLength: 120)
        let result = ArticleResolver.resolution(direct: nil, archived: (archivedStub, "<archive>"))
        XCTAssertEqual(result, .paywalled(title: "WSJ Headline"))
    }

    func testDirectTitlePreferredOverArchiveTitle() {
        let directStub = content(title: "Canonical", bodyLength: 40)
        let archivedStub = content(title: "Archive Copy", bodyLength: 60)
        let result = ArticleResolver.resolution(
            direct: (directStub, "<stub>"), archived: (archivedStub, "<archive>"))
        XCTAssertEqual(result, .paywalled(title: "Canonical"))
    }

    func testPlaceholderTitleIsNotTreatedAsReal() {
        let directStub = content(title: "Untitled", bodyLength: 40)
        let result = ArticleResolver.resolution(direct: (directStub, "<stub>"), archived: nil)
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

        func run(_ strategy: BypassStrategy, url: URL, directHTML: String?) async -> (ArticleContent, String)? {
            attempted.append(strategy)
            return strategy == succeedOn ? (readable, html) : nil
        }
    }

    /// The resolver must keep WALKING the silent strategy list past strategies that
    /// fail (return nil) and return the first one that yields a readable article —
    /// not stop early, not skip the rest. NYT's rule leads with trailing-dot; we make
    /// only `.waybackRaw` (a later strategy) succeed.
    func testResolverAdvancesPastFailingStrategiesToReadableOne() async {
        let articleURL = URL(string: "https://www.nytimes.com/2026/06/20/story.html")!
        let fetcher = MockArticleFetcher()
        fetcher.htmlByURL[articleURL.absoluteString] = lockedHTML   // direct read = locked
        let readable = ArticleContent(title: "Real", blocks: [
            .init(kind: .paragraph, text: String(repeating: "a", count: 1000), links: []),
        ])
        let runner = StubRunner(succeedOn: .waybackRaw, readable: readable, html: readableHTML("wayback"))

        let result = await ArticleResolver.resolve(url: articleURL, fetcher: fetcher, runner: runner)
        guard case let .readable(content, _) = result else {
            return XCTFail("expected a readable resolution, got \(result)")
        }
        XCTAssertEqual(content.title, "Real")
        // It must have ATTEMPTED the earlier strategies before reaching waybackRaw.
        XCTAssertTrue(runner.attempted.contains(.trailingDotHost), "should have tried trailing-dot first")
        XCTAssertTrue(runner.attempted.contains(.waybackRaw), "should have advanced to waybackRaw")
        // It must STOP at the first success — nothing after waybackRaw is attempted.
        if let successIndex = runner.attempted.firstIndex(of: .waybackRaw) {
            XCTAssertEqual(successIndex, runner.attempted.count - 1, "must stop at the first readable result")
        }
    }

    /// A strategy that yields an UNREADABLE (locked) result is rejected and the loop
    /// continues — the resolver never accepts a locked result as readable.
    func testResolverRejectsUnreadableStrategyResultAndAdvances() async {
        let articleURL = URL(string: "https://www.nytimes.com/2026/06/20/story.html")!
        let fetcher = MockArticleFetcher()
        fetcher.htmlByURL[articleURL.absoluteString] = lockedHTML

        // A runner that returns a LOCKED pair for the first strategy, readable later.
        final class LockedThenReadableRunner: BypassRunning {
            let lockedHTML: String
            let readable: (ArticleContent, String)
            private(set) var attempts = 0
            init(lockedHTML: String, readable: (ArticleContent, String)) {
                self.lockedHTML = lockedHTML
                self.readable = readable
            }
            func run(_ strategy: BypassStrategy, url: URL, directHTML: String?) async -> (ArticleContent, String)? {
                attempts += 1
                // First strategy: a body that's long enough but declares locked → must be rejected.
                if attempts == 1 {
                    return (ArticleContent(title: "Locked", blocks: [
                        .init(kind: .paragraph, text: String(repeating: "a", count: 1000), links: []),
                    ]), lockedHTML)
                }
                return readable
            }
        }
        let readable = (ArticleContent(title: "Real", blocks: [
            .init(kind: .paragraph, text: String(repeating: "a", count: 1000), links: []),
        ]), readableHTML("ok"))
        let runner = LockedThenReadableRunner(lockedHTML: lockedHTML, readable: readable)

        let result = await ArticleResolver.resolve(url: articleURL, fetcher: fetcher, runner: runner)
        guard case let .readable(content, _) = result else {
            return XCTFail("expected readable (advanced past the locked result), got \(result)")
        }
        XCTAssertEqual(content.title, "Real")
        XCTAssertGreaterThanOrEqual(runner.attempts, 2, "must reject the locked result and advance")
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
        let result = await ArticleResolver.resolve(url: articleURL, fetcher: fetcher)
        // WSJ's title survives; the body never became readable.
        XCTAssertEqual(result, .paywalled(title: "WSJ Story"))
    }
}
