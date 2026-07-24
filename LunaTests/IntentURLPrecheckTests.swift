//
//  IntentURLPrecheckTests.swift
//  LunaTests
//

import LunaModels
import XCTest
@testable import LunaIntents

/// Pre-validation decides whether a later save failure is an ERROR or a silence,
/// so the app/kind pairing is locked down here per surface.
final class IntentURLPrecheckTests: XCTestCase {

    func testUnusableValuesAreInvalid() {
        for value in ["", "example.com/post", "ftp://example.com/post", "https://"] {
            XCTAssertEqual(
                IntentURLPrecheck.verdict(for: value, current: .luna), .invalid,
                "expected invalid for \(value)")
        }
    }

    func testCentralAppHandlesEveryKind() {
        for value in [
            "https://example.com/article",
            "https://www.tiktok.com/@luna/video/123",
            "https://www.amazon.com/dp/B000000000",
        ] {
            guard case let .handleable(urlString) = IntentURLPrecheck.verdict(
                for: value, current: .luna) else {
                return XCTFail("expected \(value) to be handleable by the central app")
            }
            XCTAssertEqual(urlString, value)
        }
    }

    func testReaderHandlesArticlesAndDisownsMediaAndProducts() {
        guard case .handleable = IntentURLPrecheck.verdict(
            for: "https://www.nytimes.com/2026/07/01/us/politics/story.html", current: .reader)
        else { return XCTFail("expected an article to be handleable in Reader") }

        XCTAssertEqual(
            IntentURLPrecheck.verdict(
                for: "https://www.tiktok.com/@luna/video/123", current: .reader),
            .foreignKind(owner: .downloader))
        XCTAssertEqual(
            IntentURLPrecheck.verdict(
                for: "https://www.amazon.com/dp/B000000000", current: .reader),
            .foreignKind(owner: .priceTracker))
    }

    func testDownloaderHandlesPlatformLinksOnly() {
        guard case .handleable = IntentURLPrecheck.verdict(
            for: "https://www.tiktok.com/@luna/video/123", current: .downloader)
        else { return XCTFail("expected a TikTok link to be handleable in Downloader") }

        XCTAssertEqual(
            IntentURLPrecheck.verdict(
                for: "https://example.com/some/page", current: .downloader),
            .foreignKind(owner: .reader))
    }

    func testUndeterminedPageIsPredictedAsAnArticle() {
        // A plain web page the URL alone can't classify is what the pipeline
        // resolves to an article, so Reader (and the central app) own it.
        XCTAssertEqual(
            IntentURLPrecheck.predictedOwner(forKind: .undetermined), .reader)
        XCTAssertEqual(
            IntentURLPrecheck.predictedOwner(forKind: .document(type: "pdf")), .reader)
        XCTAssertEqual(
            IntentURLPrecheck.predictedOwner(
                forKind: .video(.youtube, itemID: "abc")), .downloader)
        XCTAssertEqual(
            IntentURLPrecheck.predictedOwner(
                forKind: .social(.x, itemID: "1")), .downloader)
        XCTAssertEqual(
            IntentURLPrecheck.predictedOwner(forKind: .product(.knownShopHost)), .priceTracker)
        XCTAssertEqual(
            IntentURLPrecheck.predictedOwner(
                forKind: .paywalledArticle(hardHost: true)), .reader)
    }
}
