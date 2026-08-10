//
//  PendingResolvedMediaDownloadsTests.swift
//  LunaTests
//

@testable import LunaMediaDownload
import LunaModels
import LunaStorage
import XCTest

final class PendingResolvedMediaDownloadsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func record(_ urlString: String, returnOffset: TimeInterval?) -> ResolvedMediaRecord {
        ResolvedMediaRecord(
            sourceURLString: urlString, title: nil,
            assets: [MediaAsset(
                url: URL(string: "https://cdn.example.com/video.mp4")!, kind: .video)],
            dateWritten: now,
            returnToSourceUntil: returnOffset.map { now.addingTimeInterval($0) })
    }

    func testFreshQueuedMarkerSurvivesLifecycleDrainBeforeDeepLinkDelivery() {
        let url = "https://x.com/luna/status/1"
        XCTAssertEqual(
            PendingResolvedMediaReturnPolicy.sourceURLString(
                records: [record(url, returnOffset: 60)],
                deepLinkFlagged: false, now: now),
            url)
    }

    func testExpiredMarkerDoesNotBounceALaterManualLaunch() {
        XCTAssertNil(PendingResolvedMediaReturnPolicy.sourceURLString(
            records: [record("https://x.com/luna/status/1", returnOffset: -1)],
            deepLinkFlagged: false, now: now))
    }

    func testDeliveredDeepLinkStillReturnsWhenQueueMarkerExpired() {
        let url = "https://x.com/luna/status/1"
        XCTAssertEqual(
            PendingResolvedMediaReturnPolicy.sourceURLString(
                records: [record(url, returnOffset: -1)],
                deepLinkFlagged: true, now: now),
            url)
    }
}
