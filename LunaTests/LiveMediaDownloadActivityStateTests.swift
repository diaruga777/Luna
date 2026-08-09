//
//  LiveMediaDownloadActivityStateTests.swift
//  LunaTests
//

import LunaURLClassification
@testable import LunaMediaDownload
import XCTest

#if canImport(ActivityKit)
import ActivityKit
#endif

/// `LiveMediaDownloadManager.activityState(for:)`: the view URL Feature 2c
/// adds for tap-to-view, populated for every phase including `.finished` (so
/// the completion alert's tap target works within its normal dismissal
/// window — the window itself is UNCHANGED, see `claudedocs/media-download.md`).
@available(iOS 16.1, *)
final class LiveMediaDownloadActivityStateTests: XCTestCase {

    private func job(phase: LiveMediaDownloadJob.Phase, sourceURLString: String = "https://example.com/video") -> LiveMediaDownloadJob {
        LiveMediaDownloadJob(
            id: "job-1", sourceURLString: sourceURLString,
            assetURLString: nil, mediaKind: .video, title: "A Video",
            resolveKind: nil, phase: phase, progress: 0.5,
            thumbnailFileName: nil, fileExtension: nil,
            expectedByteCount: nil, receivedByteCount: nil,
            resumeDataFileName: nil, rangeStartSeconds: nil, rangeEndSeconds: nil,
            resolvedVideoID: nil, youtubeVisitorData: nil, errorMessage: nil,
            errorKind: nil, resolveAttempts: 0, mediaAttempts: 0, suspendDeadline: nil)
    }

    func testViewURLIsPresentWhileDownloading() {
        #if canImport(ActivityKit)
        let state = LiveMediaDownloadManager.shared.activityState(for: job(phase: .downloading))
        XCTAssertEqual(
            state.viewURLString,
            LunaDeepLink.mediaViewLink(sourceURLString: "https://example.com/video")?.absoluteString)
        #endif
    }

    /// The completion state is exactly the one `endActivity` sends its final
    /// alert with — the tap target must survive into `.finished`, not just
    /// the in-progress phases.
    func testViewURLSurvivesIntoTheFinishedState() {
        #if canImport(ActivityKit)
        let state = LiveMediaDownloadManager.shared.activityState(
            for: job(phase: .finished, sourceURLString: "https://example.com/clip"))
        XCTAssertNotNil(state.viewURLString)
        XCTAssertTrue(state.viewURLString?.contains("clip") ?? false)
        #endif
    }

    /// Pins `endActivity`'s finished-state dismissal window at its EXISTING
    /// 20s default — Feature 2c's tap-to-view work rides the alert
    /// `endActivity` already sends on the final `.finished`/`.failed` update,
    func testViewURLEncodesTheSourceURLAsAQueryItem() {
        #if canImport(ActivityKit)
        let state = LiveMediaDownloadManager.shared.activityState(
            for: job(phase: .downloading, sourceURLString: "https://example.com/a b"))
        guard let urlString = state.viewURLString, let url = URL(string: urlString) else {
            XCTFail("no view URL")
            return
        }
        XCTAssertEqual(LunaDeepLink.mediaViewURLString(from: url), "https://example.com/a b")
        #endif
    }
}
