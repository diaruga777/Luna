//
//  RecentURLMatcherTests.swift
//  LunaTests
//

import LunaAppConfig
import UIKit
import XCTest
@testable import Luna

/// The Safari-trail suggestions in the util card hold a per-surface cache of
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

    // MARK: - …and the candidates are collapsed against each other

    /// The trail is newest-first, so the FIRST occurrence is the recent visit.
    func testRepeatedPageIsOfferedOnceKeepingTheMostRecentVisit() {
        let newest = preview("https://example.com/story?utm_source=share")
        let older = preview("https://example.com/story")
        let other = preview("https://example.com/other")

        XCTAssertEqual(
            RecentURLMatcher.deduplicated([newest, older, other], savedURLStrings: []),
            [newest, other],
            "One page must not take two rows")
    }

    func testSamenessIgnoresSchemeCaseWWWTrailingSlashAndFragment() {
        let variants = [
            "https://www.example.com/story",
            "https://example.com/story/",
            "http://EXAMPLE.com/story#section-2",
            // Tracking params come off through `URLCanonicalizer`, so a row can
            // never disagree with what the store considers one page.
            "https://example.com/story?fbclid=abc123",
        ]
        XCTAssertEqual(
            Set(variants.map(RecentURLMatcher.identityKey(for:))).count, 1)
        XCTAssertEqual(
            RecentURLMatcher.deduplicated(variants.map { preview($0) }, savedURLStrings: []),
            [preview(variants[0])])
    }

    /// A query is what distinguishes one video or product from the next, so two
    /// paths that differ only there stay two rows.
    func testDistinctQueriesRemainDistinctRows() {
        let candidates = [
            preview("https://www.youtube.com/watch?v=aaaaaaaaaaa"),
            preview("https://www.youtube.com/watch?v=bbbbbbbbbbb"),
        ]
        XCTAssertEqual(
            RecentURLMatcher.deduplicated(candidates, savedURLStrings: []), candidates)
    }

    /// The saved-URL filter compares by the same key, so a save whose stored form
    /// differs cosmetically from the trail's still removes its row.
    func testSavedURLMatchesItsRecentByTheSameKey() {
        let candidates = [preview("https://www.example.com/story/")]
        XCTAssertTrue(
            RecentURLMatcher.deduplicated(
                candidates, savedURLStrings: ["https://example.com/story"]).isEmpty)
    }

    // MARK: - A row's artwork survives being stored

    /// Site marks are routinely dark artwork on transparency. JPEG has no alpha
    /// to keep, so compressing one that way composites it onto black — and the
    /// row it is drawn on is black, which reads as "no artwork was fetched"
    /// rather than as an encoding bug.
    func testATransparentSiteMarkKeepsItsTransparency() throws {
        let mark = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64)).image { context in
            UIColor.green.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 32))
        }
        let stored = try XCTUnwrap(RecentURLMatcher.compressedData(mark))

        let alphas = try alphaChannel(of: try XCTUnwrap(UIImage(data: stored)))
        XCTAssertEqual(alphas.min(), 0, "The transparent half must still be transparent")
        XCTAssertEqual(alphas.max(), 255, "…and the mark itself must still be there")
    }

    /// The photographs (a product shot, a video still) stay JPEGs — the PNG
    /// above is for the artwork that needs it, not a switch of the whole path.
    func testAnOpaquePreviewImageStaysAJPEG() throws {
        let opaque = UIGraphicsImageRendererFormat.preferred()
        opaque.opaque = true
        let photo = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64), format: opaque)
            .image { context in
                UIColor.systemBlue.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
            }
        let stored = try XCTUnwrap(RecentURLMatcher.compressedData(photo))

        XCTAssertEqual(Array(stored.prefix(2)), [0xFF, 0xD8], "JPEG start-of-image marker")
    }

    /// Every alpha byte of `image`, read back out of its bitmap.
    private func alphaChannel(of image: UIImage) throws -> [UInt8] {
        let cgImage = try XCTUnwrap(image.cgImage)
        let width = cgImage.width, height = cgImage.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = try XCTUnwrap(CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return stride(from: 3, to: pixels.count, by: 4).map { pixels[$0] }
    }
}
