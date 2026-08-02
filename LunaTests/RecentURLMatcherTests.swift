//
//  RecentURLMatcherTests.swift
//  LunaTests
//

import LunaAppConfig
import XCTest
@testable import Luna

/// The Safari-trail suggestions in the left tray hold a per-surface cache of
/// verdicts that `IngestPipeline` produced. Those verdicts are DERIVED, so when
/// the pipeline changes they are simply wrong — and `refresh` only evaluates URLs
/// missing from the cache, so nothing re-derives them on its own.
///
/// That is how a Google search page kept its row after the classifier learned to
/// reject search-results URLs: the tray was replaying a verdict from an older
/// build. Both defences are pinned here.
@MainActor
final class RecentURLMatcherTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "RecentURLMatcherTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        RecentURLMatcher.testDefaultsOverride = defaults
    }

    override func tearDown() {
        RecentURLMatcher.testDefaultsOverride = nil
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    /// The exact URL from the report.
    private let googleSearch =
        "https://www.google.com/search?q=spark+catcher+mina&ie=UTF-8&oe=UTF-8&hl=en-us&client=safari"

    private func preview(
        _ urlString: String, kind: RecentURLPreview.Kind = .article
    ) -> RecentURLPreview {
        RecentURLPreview(
            urlString: urlString, title: "Whatever", subtitle: nil,
            kind: kind, imageData: nil)
    }

    // MARK: - The cached verdict can't outlive the code that produced it

    func testCacheFromAnotherBuildIsDiscardedRatherThanReplayed() {
        RecentURLMatcher.shared.writeCacheForTesting(
            urlStrings: [googleSearch, "https://example.com/story"],
            version: "0.0.0-stale")

        XCTAssertEqual(
            RecentURLMatcher.shared.cachedVerdictCount(), 0,
            "A cache written by an older build must be re-derived, not trusted")
    }

    func testCacheFromThisBuildIsKept() {
        RecentURLMatcher.shared.writeCacheForTesting(
            urlStrings: ["https://example.com/story"], version: AppConfig.appVersion)

        XCTAssertEqual(RecentURLMatcher.shared.cachedVerdictCount(), 1)
    }

    // MARK: - …and a stale positive can't reach the screen inside one build either

    func testSearchResultsPreviewIsDroppedOnTheWayToTheScreen() {
        XCTAssertTrue(RecentURLMatcher.isObviouslyNonContent(
            preview: preview(googleSearch), historyKey: googleSearch))
    }

    /// The trail key and the preview's URL diverge once a URL unwraps, so either
    /// one naming a search page is enough to drop the row.
    func testEitherTheTrailKeyOrTheCanonicalURLCanCondemnTheRow() {
        XCTAssertTrue(RecentURLMatcher.isObviouslyNonContent(
            preview: preview("https://example.com/looks-fine"),
            historyKey: googleSearch))
        XCTAssertTrue(RecentURLMatcher.isObviouslyNonContent(
            preview: preview(googleSearch),
            historyKey: "https://news.example.com/redirector"))
    }

    func testShopSearchGridIsDroppedOnlyForAProductPreview() {
        let amazonSearch = "https://www.amazon.com/s?k=headphones"
        XCTAssertTrue(RecentURLMatcher.isObviouslyNonContent(
            preview: preview(amazonSearch, kind: .product), historyKey: amazonSearch))
        // The commerce listing table reads a leading `s` segment as a search, which
        // is right for Amazon and wrong for `medium.com/s/<publication>` — so it is
        // scoped to a product verdict, exactly as `IngestPipeline` scopes it.
        let medium = "https://medium.com/s/a-publication/a-real-essay-abc123"
        XCTAssertFalse(RecentURLMatcher.isObviouslyNonContent(
            preview: preview(medium, kind: .article), historyKey: medium))
    }

    func testOrdinaryRowsSurvive() {
        for candidate in [
            "https://www.nytimes.com/2026/07/28/us/politics/a-story.html",
            "https://blog.example.com/posts/thing",
            "https://www.amazon.com/dp/B0000000",
        ] {
            XCTAssertFalse(
                RecentURLMatcher.isObviouslyNonContent(
                    preview: preview(candidate), historyKey: candidate),
                "\(candidate) should still be offered")
        }
    }

    func testSavedRecentIsRemovedAndDeletingSaveRevealsItAgain() {
        let recent = preview("https://example.com/story")
        let candidates = [recent, preview("https://example.com/other")]

        XCTAssertEqual(
            RecentURLMatcher.deduplicated(
                candidates, savedURLStrings: [recent.urlString]),
            [candidates[1]],
            "A newly committed save must disappear from recents immediately")
        XCTAssertEqual(
            RecentURLMatcher.deduplicated(candidates, savedURLStrings: []),
            candidates,
            "Deleting the save must reveal the cached recent without a relaunch")
    }
}
