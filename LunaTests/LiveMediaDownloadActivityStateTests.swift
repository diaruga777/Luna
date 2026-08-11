//
//  LiveMediaDownloadActivityStateTests.swift
//  LunaTests
//

import LunaModels
import LunaURLClassification
@testable import LunaMediaDownload
import XCTest

#if canImport(ActivityKit)
import ActivityKit
#endif

/// `LiveMediaDownloadManager.activityState(for:)`: the prebuilt deep links the
/// widget renders — tap-to-view (every phase, including `.finished`) and the
/// finished card's Share button. Both are strings rather than `LunaDeepLink`
/// calls because a widget target cannot import `LunaURLClassification`; see
/// `claudedocs/media-download.md`.
@available(iOS 16.1, *)
final class LiveMediaDownloadActivityStateTests: XCTestCase {

    private func job(phase: LiveMediaDownloadJob.Phase, sourceURLString: String = "https://example.com/video") -> LiveMediaDownloadJob {
        LiveMediaDownloadJob(
            id: "job-1", sourceURLString: sourceURLString,
            assetURLString: nil, mediaKind: .video, title: "A Video",
            resolveKind: nil, phase: phase, progress: 0.5,
            thumbnailFileName: nil, fileExtension: nil,
            expectedByteCount: nil, receivedByteCount: nil,
            resumeDataFileName: nil, timeRange: nil,
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

    /// The completion state is the one the finished card renders during its
    /// five-second live hold — the tap target must survive into `.finished`,
    /// not just the in-progress phases.
    func testViewURLSurvivesIntoTheFinishedState() {
        #if canImport(ActivityKit)
        let state = LiveMediaDownloadManager.shared.activityState(
            for: job(phase: .finished, sourceURLString: "https://example.com/clip"))
        XCTAssertNotNil(state.viewURLString)
        XCTAssertTrue(state.viewURLString?.contains("clip") ?? false)
        #endif
    }

    /// The finished card's Share button target: the same `media` route as the
    /// Play link, plus `&share=1` — so it centers the same card AND asks for
    /// the share sheet, and the Play link beside it never does.
    func testShareURLIsTheViewRoutePlusTheShareFlag() throws {
        #if canImport(ActivityKit)
        let state = LiveMediaDownloadManager.shared.activityState(
            for: job(phase: .finished, sourceURLString: "https://example.com/clip?id=7"))
        let shareURL = try XCTUnwrap(state.shareURLString.flatMap(URL.init(string:)))
        let viewURL = try XCTUnwrap(state.viewURLString.flatMap(URL.init(string:)))
        XCTAssertEqual(
            LunaDeepLink.mediaViewURLString(from: shareURL), "https://example.com/clip?id=7")
        XCTAssertTrue(LunaDeepLink.mediaShareRequested(from: shareURL))
        XCTAssertFalse(LunaDeepLink.mediaShareRequested(from: viewURL))
        #endif
    }

    /// Every phase carries the share link, for the same reason the view link is
    /// unconditional: the widget decides which phase renders a Share button,
    /// and a state re-sent from a resumed job must not lose it.
    func testShareURLIsPresentWhileDownloading() {
        #if canImport(ActivityKit)
        let state = LiveMediaDownloadManager.shared.activityState(for: job(phase: .downloading))
        XCTAssertNotNil(state.shareURLString)
        #endif
    }

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
