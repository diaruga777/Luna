import LunaModels
//
//  UndownloadedMediaCardTests.swift
//  LunaTests
//
//  Download progress is drawn INSIDE the card of the item that is downloading —
//  there is no app-level floating download bar any more. These tests pin both
//  halves of that contract: the bar is a subview of the card, and it is a pure
//  observer of the job notification (so tearing the card down cannot touch the
//  transfer, and a card recreated mid-transfer picks the bar back up).
//

import LunaDesignSystem
import LunaStorage
import UIKit
import XCTest
@testable import Luna
@testable import LunaMediaDownload

final class UndownloadedMediaCardTests: XCTestCase {

    private let sourceURL = "https://x.com/luna/status/424242"

    private func makeItem() -> SavedMediaItem {
        SavedMediaItem(
            id: UUID(), sourceURLString: sourceURL, title: "Clip",
            dateSaved: Date(), kind: nil, storageState: .undownloaded,
            thumbnailFileName: nil)
    }

    /// Built through the production path so the card can never drift from the
    /// status line the Live Activity shows.
    private func makeSnapshot(
        phase: LiveMediaDownloadJob.Phase, progress: Double,
        errorMessage: String? = nil, errorKind: LiveMediaDownloadJob.ErrorKind? = nil
    ) -> DownloaderJobSnapshot {
        LiveMediaDownloadJob(
            id: "job", sourceURLString: sourceURL, assetURLString: nil,
            mediaKind: .video, title: "Clip", resolveKind: .x, phase: phase,
            progress: progress, thumbnailFileName: nil, fileExtension: nil,
            expectedByteCount: nil, receivedByteCount: nil, resumeDataFileName: nil,
            timeRange: nil, resolvedVideoID: nil,
            youtubeVisitorData: nil, errorMessage: errorMessage, errorKind: errorKind,
            resolveAttempts: 0, mediaAttempts: 0, suspendDeadline: nil,
            ownership: .downloader).downloaderSnapshot
    }

    @MainActor
    private func makeCard() -> UndownloadedMediaCardContentViewController {
        let card = UndownloadedMediaCardContentViewController(
            item: makeItem(), download: {})
        card.view.frame = CGRect(x: 0, y: 0, width: 320, height: 560)
        card.loadViewIfNeeded()
        return card
    }

    /// Posts on the notification's real path, then drains the main queue the
    /// handler hops onto (progress originates on URLSession delegate queues).
    @MainActor
    private func post(_ snapshot: DownloaderJobSnapshot?, urlString: String? = nil) {
        var userInfo: [AnyHashable: Any] = ["sourceURLString": urlString ?? sourceURL]
        if let snapshot { userInfo["snapshot"] = snapshot }
        NotificationCenter.default.post(
            name: .downloaderJobProgressChanged, object: nil, userInfo: userInfo)
        let drained = expectation(description: "main queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 2)
    }

    @MainActor
    func testIdleCardShowsNoDownloadBar() {
        let card = makeCard()
        XCTAssertFalse(card.isDownloadBarVisibleForTesting)
        XCTAssertTrue(card.isRetryGlyphVisibleForTesting)
    }

    @MainActor
    func testDownloadBarIsEmbeddedInTheCardAndNotHostChrome() {
        let card = makeCard()
        post(makeSnapshot(phase: .downloading, progress: 0.5))

        XCTAssertTrue(card.isDownloadBarVisibleForTesting)
        // The bar's ancestor chain must terminate at this card's own view: a
        // floating bar would live on the host controller's view instead.
        XCTAssertTrue(card.downloadBarForTesting.isDescendant(of: card.view))
        card.view.layoutIfNeeded()
        let barFrame = card.downloadBarForTesting.frame
        XCTAssertTrue(card.view.bounds.contains(barFrame), "\(barFrame) escapes the card")
    }

    @MainActor
    func testBarMirrorsPhaseProgressAndPercentage() {
        let card = makeCard()

        post(makeSnapshot(phase: .resolving, progress: 0))
        XCTAssertEqual(card.statusTextForTesting, "Fetching video")
        // No bytes are moving yet, so a percentage would be a fiction.
        XCTAssertNil(card.percentTextForTesting)

        post(makeSnapshot(phase: .downloading, progress: 0.426))
        XCTAssertEqual(card.statusTextForTesting, "Fetching video…")
        XCTAssertEqual(card.percentTextForTesting, "43%")
        XCTAssertEqual(card.progressForTesting, 0.426, accuracy: 0.001)

        post(makeSnapshot(phase: .waiting, progress: 0.426))
        XCTAssertEqual(card.statusTextForTesting, "Waiting to resume")
        XCTAssertNil(card.percentTextForTesting)
    }

    @MainActor
    func testFailureKeepsTheReasonAndRestoresTheRetryGlyph() {
        let card = makeCard()
        post(makeSnapshot(phase: .downloading, progress: 0.3))
        XCTAssertFalse(card.isRetryGlyphVisibleForTesting)

        post(makeSnapshot(
            phase: .failed, progress: 0.3, errorMessage: "No media found",
            errorKind: .noMedia))

        XCTAssertTrue(card.isDownloadBarVisibleForTesting)
        XCTAssertEqual(card.statusTextForTesting, "No media found")
        XCTAssertNil(card.percentTextForTesting)
        XCTAssertTrue(card.isRetryGlyphVisibleForTesting)
    }

    @MainActor
    func testAnotherItemsJobIsIgnored() {
        let card = makeCard()
        post(
            makeSnapshot(phase: .downloading, progress: 0.9),
            urlString: "https://x.com/someone/status/999")

        XCTAssertFalse(card.isDownloadBarVisibleForTesting)
    }

    /// The hand-off's state belongs to the STORE, not to the tap that started
    /// it: a card built while a reply is outstanding says which file to look
    /// for, and one whose reply was refused says why
    /// (`claudedocs/llm-handoff.md`).
    @MainActor
    func testARecordedHandoffRendersItsHintWithoutATap() {
        let handoffs = LLMHandoffStore.shared
        let record = handoffs.begin(
            .recovery(itemID: UUID(), urlString: sourceURL), provider: .chatGPT)
        defer { handoffs.clear(id: record.id) }

        let card = makeCard()
        post(makeSnapshot(
            phase: .failed, progress: 0.3, errorMessage: "No media found",
            errorKind: .noMedia))

        XCTAssertTrue(card.isHandoffRowVisibleForTesting)
        XCTAssertEqual(card.handoffHintForTesting, LLMHandoffRowView.waitingHint())

        handoffs.markRefused(id: record.id, reason: "Luna could not read the content.")
        post(makeSnapshot(
            phase: .failed, progress: 0.3, errorMessage: "No media found",
            errorKind: .noMedia))

        XCTAssertEqual(card.handoffHintForTesting, "Luna could not read the content.")
    }

    /// No hand-off, no hint: the row is the offer and nothing else.
    @MainActor
    func testAFailureWithNoHandoffShowsNoHint() {
        let card = makeCard()
        post(makeSnapshot(
            phase: .failed, progress: 0.3, errorMessage: "No media found",
            errorKind: .noMedia))

        XCTAssertTrue(card.isHandoffRowVisibleForTesting)
        XCTAssertNil(card.handoffHintForTesting)
    }

    /// A job that ends with no result to show (a suspension reaped past its
    /// grace period) posts no snapshot: the card returns to its static state
    /// rather than freezing a stale bar on screen.
    @MainActor
    func testJobEndedWithoutSnapshotResetsToStaticState() {
        let card = makeCard()
        post(makeSnapshot(phase: .downloading, progress: 0.6))
        XCTAssertTrue(card.isDownloadBarVisibleForTesting)

        post(nil)

        XCTAssertFalse(card.isDownloadBarVisibleForTesting)
        XCTAssertTrue(card.isRetryGlyphVisibleForTesting)
    }
}
