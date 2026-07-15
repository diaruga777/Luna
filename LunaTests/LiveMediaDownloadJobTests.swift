@testable import LunaMediaDownload
import XCTest

final class LiveMediaDownloadJobTests: XCTestCase {
    func testDownloaderStartPolicyRestartsMissingAndUndownloadedMedia() {
        XCTAssertTrue(LiveMediaDownloadStartPolicy.downloaderShouldStart(storageState: nil))
        XCTAssertTrue(LiveMediaDownloadStartPolicy.downloaderShouldStart(
            storageState: .undownloaded))
    }

    func testDownloaderStartPolicyDoesNotRedownloadCompletedMedia() {
        XCTAssertFalse(LiveMediaDownloadStartPolicy.downloaderShouldStart(
            storageState: .localFile(fileName: "media.mp4")))
        XCTAssertFalse(LiveMediaDownloadStartPolicy.downloaderShouldStart(
            storageState: .photosReference(
                localIdentifier: "photo-id", pendingLocalFileName: nil,
                pendingThumbnailFileName: nil)))
    }

    func testLegacyJobWithoutOwnershipStillDecodes() throws {
        let json = #"{"id":"1","sourceURLString":"https://www.tiktok.com/@a/video/1","assetURLString":null,"mediaKind":"video","title":"Media","resolveKind":null,"phase":"resolving","progress":0,"thumbnailFileName":null,"fileExtension":null,"errorMessage":null,"errorKind":null,"resolveAttempts":0,"mediaAttempts":0,"suspendDeadline":null}"#
        let job = try JSONDecoder().decode(LiveMediaDownloadJob.self, from: Data(json.utf8))
        XCTAssertNil(job.ownership)
    }

    func testDownloaderOwnershipRoundTrips() throws {
        let job = LiveMediaDownloadJob(
            id: "1", sourceURLString: "https://www.tiktok.com/@a/video/1",
            assetURLString: nil, mediaKind: "video", title: "Media",
            resolveKind: nil, phase: .resolving, progress: 0,
            thumbnailFileName: nil, fileExtension: nil, errorMessage: nil,
            errorKind: nil, resolveAttempts: 0, mediaAttempts: 0,
            suspendDeadline: nil, ownership: .downloader)
        let decoded = try JSONDecoder().decode(
            LiveMediaDownloadJob.self, from: JSONEncoder().encode(job))
        XCTAssertEqual(decoded.ownership, .downloader)
        XCTAssertTrue(decoded.isDownloaderOwned)
    }

    func testResumePolicyRestartsOnlyTransferPhasesWithoutAnActiveTask() {
        XCTAssertTrue(LiveMediaDownloadResumePolicy.shouldRestart(
            phase: .resolving, hasActiveTask: false))
        XCTAssertTrue(LiveMediaDownloadResumePolicy.shouldRestart(
            phase: .downloading, hasActiveTask: false))

        XCTAssertFalse(LiveMediaDownloadResumePolicy.shouldRestart(
            phase: .resolving, hasActiveTask: true))
        XCTAssertFalse(LiveMediaDownloadResumePolicy.shouldRestart(
            phase: .suspended, hasActiveTask: false))
        XCTAssertFalse(LiveMediaDownloadResumePolicy.shouldRestart(
            phase: .saving, hasActiveTask: false))
        XCTAssertFalse(LiveMediaDownloadResumePolicy.shouldRestart(
            phase: .finished, hasActiveTask: false))
        XCTAssertFalse(LiveMediaDownloadResumePolicy.shouldRestart(
            phase: .failed, hasActiveTask: false))
    }

    func testBackgroundProgressNotificationIsDeliveredOnMainThread() {
        let sourceURL = "https://x.com/luna/status/123456789"
        let delivered = expectation(description: "progress delivered on main thread")
        let token = NotificationCenter.default.addObserver(
            forName: .downloaderJobProgressChanged, object: nil, queue: nil
        ) { notification in
            guard notification.userInfo?["sourceURLString"] as? String == sourceURL else { return }
            XCTAssertTrue(Thread.isMainThread)
            delivered.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(token) }

        let job = LiveMediaDownloadJob(
            id: "notification-thread", sourceURLString: sourceURL,
            assetURLString: nil, mediaKind: "unknown", title: "Media",
            resolveKind: "x", phase: .resolving, progress: 0,
            thumbnailFileName: nil, fileExtension: nil, errorMessage: nil,
            errorKind: nil, resolveAttempts: 0, mediaAttempts: 0,
            suspendDeadline: nil, ownership: .downloader)
        DispatchQueue.global(qos: .userInitiated).async {
            postDownloaderJobProgress(job: job, progress: 0)
        }

        wait(for: [delivered], timeout: 2)
    }

    // MARK: - WiFiOnlyDownloadGate

    func testWiFiOnlyGateOnlyDefersDownloaderOwnedAutomaticStartsOffWiFiWhenEnabled() {
        XCTAssertTrue(WiFiOnlyDownloadGate.shouldDefer(
            ownership: .downloader, manual: false, wifiOnlyEnabled: true, isOnWiFi: false))
    }

    func testWiFiOnlyGateNeverDefersManualStarts() {
        XCTAssertFalse(WiFiOnlyDownloadGate.shouldDefer(
            ownership: .downloader, manual: true, wifiOnlyEnabled: true, isOnWiFi: false))
    }

    func testWiFiOnlyGateNeverDefersWhenSettingIsOff() {
        XCTAssertFalse(WiFiOnlyDownloadGate.shouldDefer(
            ownership: .downloader, manual: false, wifiOnlyEnabled: false, isOnWiFi: false))
    }

    func testWiFiOnlyGateNeverDefersWhenAlreadyOnWiFi() {
        XCTAssertFalse(WiFiOnlyDownloadGate.shouldDefer(
            ownership: .downloader, manual: false, wifiOnlyEnabled: true, isOnWiFi: true))
    }

    func testWiFiOnlyGateNeverDefersNonDownloaderOwnership() {
        XCTAssertFalse(WiFiOnlyDownloadGate.shouldDefer(
            ownership: .invokingApp, manual: false, wifiOnlyEnabled: true, isOnWiFi: false))
    }
}
