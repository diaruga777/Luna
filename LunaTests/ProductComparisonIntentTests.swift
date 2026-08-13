//
//  ProductComparisonIntentTests.swift
//  LunaTests
//

import LunaModels
import LunaPriceUI
import XCTest
@testable import Luna

/// The Action Button intents' product leg (`claudedocs/price-comparison.md`,
/// `claudedocs/app-intents.md`): the checkpoint that carries an unfinished
/// summary to Save, the freshness rule that decides whether the printed prices
/// are refetched first, and the seam that keeps every non-product app incurious.
final class ProductComparisonIntentTests: XCTestCase {

    override func tearDown() {
        ActionButtonIntentSupport.productComparison = nil
        super.tearDown()
    }

    /// A stand-in product leg answering with a fixed document URL.
    private struct FakeProductComparison: IntentProductComparisonProviding {
        let documentURL: URL?

        func comparisonDocumentURL(forURLString urlString: String) async -> URL? {
            documentURL
        }
    }

    // MARK: - The checkpoint

    func testTheComparisonPhaseRoundTripsThroughTheOpaqueString() throws {
        let metadata = CaptureIntentMetadata(
            phase: .comparison, currentApp: "Safari",
            resolvedURLString: "https://shop.example/p/1")
        let decoded = try XCTUnwrap(CaptureIntentMetadata.decode(metadata.opaqueString))
        XCTAssertEqual(decoded.phase, .comparison)
        XCTAssertEqual(decoded.resolvedURLString, "https://shop.example/p/1")
        XCTAssertEqual(decoded.schemaVersion, CaptureIntentMetadata.currentSchemaVersion)
    }

    /// A v1 checkpoint sitting in a Shortcut across an app update describes a
    /// save that is genuinely still resumable. Refusing it would silently
    /// restart work the user already waited through.
    func testAV1CheckpointStillDecodes() throws {
        let v1 = """
        {"isDoubleSave":false,"phase":"download","resolvedURLString":\
        "https://example.com/v","schemaVersion":1}
        """
        let decoded = try XCTUnwrap(CaptureIntentMetadata.decode(v1))
        XCTAssertEqual(decoded.schemaVersion, 1)
        XCTAssertEqual(decoded.phase, .download)
        XCTAssertEqual(decoded.resolvedURLString, "https://example.com/v")
    }

    /// A FUTURE schema is refused rather than best-effort decoded: its phase may
    /// name work this build cannot perform, and running the wrong leg is worse
    /// than starting over.
    func testAFutureSchemaIsRefused() {
        let future = """
        {"phase":"save","schemaVersion":\(CaptureIntentMetadata.currentSchemaVersion + 1)}
        """
        XCTAssertNil(CaptureIntentMetadata.decode(future))
    }

    // MARK: - The seam

    /// Reader and Downloader never install the seam, and the intents must not go
    /// looking for a comparison there — `handlesProductComparison` is the one
    /// question they ask before spending any of the deadline on it.
    func testWithNoSeamInstalledTheIntentsProduceNoComparison() async {
        ActionButtonIntentSupport.productComparison = nil
        XCTAssertFalse(ActionButtonIntentSupport.handlesProductComparison)
        let file = await ActionButtonIntentSupport.comparisonFile(for: "https://shop.example/p/1")
        XCTAssertNil(file)
    }

    func testAnInstalledSeamReturnsTheDocumentAsIntentMedia() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).html")
        try Data("<html></html>".utf8).write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        ActionButtonIntentSupport.productComparison = FakeProductComparison(documentURL: fileURL)

        XCTAssertTrue(ActionButtonIntentSupport.handlesProductComparison)
        let produced = await ActionButtonIntentSupport.comparisonFile(
            for: "https://shop.example/p/1")
        let file = try XCTUnwrap(produced)
        XCTAssertEqual(file.filename, fileURL.lastPathComponent)
    }

    /// A non-product save is the ordinary case: the seam is installed (this IS a
    /// product app) and simply has no tracker for the URL.
    func testANonProductSaveGetsNoComparisonEvenWithTheSeamInstalled() async {
        ActionButtonIntentSupport.productComparison = FakeProductComparison(documentURL: nil)
        let file = await ActionButtonIntentSupport.comparisonFile(for: "https://news.example/a")
        XCTAssertNil(file)
    }

    // MARK: - Freshness

    private func tracker(refreshedAgo intervals: [TimeInterval?], now: Date) -> PriceTracker {
        var tracker = PriceTracker(
            productName: "Acme Widget", firstStoreURL: "https://a.example/p/1",
            price: 100, currency: "USD", now: now.addingTimeInterval(-(intervals[0] ?? 0)))
        for (index, ago) in intervals.enumerated() {
            tracker.upsertStore(PriceTrackerStore(
                urlString: "https://s\(index).example/p/1", lastPrice: 100, currency: "USD",
                lastRefreshed: ago.map { now.addingTimeInterval(-$0) }))
        }
        return tracker
    }

    func testATrackerRefreshedWithinTheDayIsNotRefetched() {
        let now = Date()
        XCTAssertFalse(ProductIntentHandoff.isStale(
            tracker(refreshedAgo: [3_600, 7_200], now: now), now: now))
    }

    /// Stale when ANY seller is. The document is a comparison BETWEEN sellers,
    /// so one week-old row doesn't just misreport that row — it can hand the
    /// "Lowest" badge to the wrong shop.
    func testOneStaleSellerMakesTheWholeTrackerStale() {
        let now = Date()
        XCTAssertTrue(ProductIntentHandoff.isStale(
            tracker(refreshedAgo: [3_600, 8 * 86_400.0], now: now), now: now))
    }

    func testASellerThatHasNeverBeenRefreshedCountsAsStale() {
        let now = Date()
        XCTAssertTrue(ProductIntentHandoff.isStale(
            tracker(refreshedAgo: [3_600, nil], now: now), now: now))
    }

    // MARK: - Progress

    /// Finding sellers and downloading are alternatives, never a sequence — a
    /// save is a product or it is media — so they share the wide band rather
    /// than each getting half of it and looking half as far along.
    func testFindingSellersOwnsTheSameBandAsADownload() {
        XCTAssertEqual(
            IntentProgressReporter.Stage.findingSellers.band,
            IntentProgressReporter.Stage.downloading.band)
    }

    func testEnteringFindingSellersMovesPastTheSavingBand() {
        let reporter = IntentProgressReporter()
        reporter.enter(.findingSellers)
        XCTAssertGreaterThanOrEqual(
            reporter.fraction, IntentProgressReporter.Stage.saving.band.upperBound)
    }
}
