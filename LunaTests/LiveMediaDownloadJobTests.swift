import LunaModels
@testable import LunaMediaDownload
import XCTest

final class LiveMediaDownloadJobTests: XCTestCase {
    private static var managerSource: String {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        return (try? String(
            contentsOf: repoRoot.appendingPathComponent(
                "LunaLibraries/Sources/LunaMediaDownload/LiveMediaDownloadManager.swift"),
            encoding: .utf8)) ?? ""
    }

    func testFacebookReelBackgroundResolutionStartsWithVideoPlugin() throws {
        let source = try XCTUnwrap(URL(string:
            "https://www.facebook.com/reel/1610065874019369/?fs=e&mibextid=wwXIfr&fs=e"))

        let resolve = try XCTUnwrap(LiveMediaDownloadManager.resolveRequest(for: source))

        XCTAssertEqual(resolve.kind, "facebookPlugin")
        XCTAssertEqual(
            resolve.request.value(forHTTPHeaderField: "User-Agent"),
            MediaDownloadHTTP.desktopBrowserUserAgent)
        XCTAssertEqual(resolve.request.url?.host, "www.facebook.com")
        XCTAssertEqual(resolve.request.url?.path, "/plugins/video.php")
        XCTAssertEqual(resolve.request.httpShouldHandleCookies, false)
        XCTAssertEqual(resolve.request.cachePolicy, .reloadIgnoringLocalCacheData)
        let href = resolve.request.url.flatMap {
            URLComponents(url: $0, resolvingAgainstBaseURL: false)
        }?.queryItems?.first(where: { $0.name == "href" })?.value
        XCTAssertEqual(href, "https://www.facebook.com/reel/1610065874019369/")
    }

    /// The durable engine must open on the same stage the foreground resolver does —
    /// the persisted GraphQL query, the only keyless source still returning a reel's
    /// `video_url`. It has to be a GET: a background `URLSession` cannot upload a
    /// request body, and the endpoint refuses a bodyless POST.
    func testInstagramReelBackgroundResolutionStartsWithGraphQLQuery() throws {
        let source = try XCTUnwrap(URL(string:
            "https://www.instagram.com/jonfilipko/reel/DbripgRKlb_/"))

        let resolve = try XCTUnwrap(LiveMediaDownloadManager.resolveRequest(for: source))

        XCTAssertEqual(resolve.kind, "instagramGraphQL")
        XCTAssertNil(resolve.request.httpBody)
        XCTAssertEqual(resolve.request.httpMethod, "GET")
        XCTAssertEqual(resolve.request.httpShouldHandleCookies, false)
        XCTAssertEqual(
            resolve.request.value(forHTTPHeaderField: "X-IG-App-ID"),
            MediaDownloadHTTP.instagramWebAppID)
        let components = try XCTUnwrap(resolve.request.url.flatMap {
            URLComponents(url: $0, resolvingAgainstBaseURL: false)
        })
        XCTAssertEqual(components.host, "www.instagram.com")
        XCTAssertEqual(components.path, "/graphql/query/")
        XCTAssertEqual(
            components.queryItems?.first(where: { $0.name == "variables" })?.value,
            #"{"shortcode":"DbripgRKlb_"}"#)
    }

    func testYouTubeBackgroundResolutionCanonicalizesCommonURLForms() throws {
        let mobile = try XCTUnwrap(URL(string:
            "https://m.youtube.com/watch?v=dQw4w9WgXcQ&t=90s"))
        let resolve = try XCTUnwrap(LiveMediaDownloadManager.resolveRequest(for: mobile))
        XCTAssertEqual(resolve.kind, "youtubeWatch")
        let components = try XCTUnwrap(resolve.request.url.flatMap {
            URLComponents(url: $0, resolvingAgainstBaseURL: false)
        })
        XCTAssertEqual(components.scheme, "https")
        XCTAssertEqual(components.host, "www.youtube.com")
        XCTAssertEqual(components.path, "/watch")
        XCTAssertEqual(
            components.queryItems?.first(where: { $0.name == "v" })?.value,
            "dQw4w9WgXcQ")
        XCTAssertEqual(
            components.queryItems?.first(where: { $0.name == "bpctr" })?.value,
            "9999999999")
        XCTAssertEqual(
            components.queryItems?.first(where: { $0.name == "has_verified" })?.value,
            "1")
        XCTAssertEqual(resolve.request.httpShouldHandleCookies, true)
        XCTAssertEqual(
            resolve.request.value(forHTTPHeaderField: "User-Agent"),
            YouTubeMediaResolver.webSafariUserAgent)
        XCTAssertEqual(
            resolve.request.value(forHTTPHeaderField: "Cookie"),
            "PREF=hl=en&tz=UTC; SOCS=CAI")

        let clip = try XCTUnwrap(URL(string:
            "https://www.youtube.com/clip/UgkxOpaqueClipToken"))
        let clipResolve = try XCTUnwrap(LiveMediaDownloadManager.resolveRequest(for: clip))
        XCTAssertEqual(clipResolve.kind, "youtubeClip")
        XCTAssertEqual(clipResolve.request.url, clip)
    }

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
        XCTAssertEqual(job.mediaKind, .video)
    }

    func testRedditCompanionURLsSurviveJobPersistence() throws {
        let audio = "https://v.redd.it/clip/audio"
        let manifest = "https://v.redd.it/clip/DASHPlaylist.mpd"
        let job = LiveMediaDownloadJob(
            id: "reddit", sourceURLString: "https://reddit.com/comments/abc",
            assetURLString: "https://v.redd.it/clip/DASH_720.mp4",
            mediaKind: .video, title: "Clip", resolveKind: .reddit,
            phase: .downloading, progress: 0.25,
            resolveAttempts: 0, mediaAttempts: 0, ownership: .downloader,
            audioURLString: audio, dashManifestURLString: manifest)

        let restored = try JSONDecoder().decode(
            LiveMediaDownloadJob.self, from: JSONEncoder().encode(job))

        XCTAssertEqual(restored.audioURLString, audio)
        XCTAssertEqual(restored.dashManifestURLString, manifest)
    }

    /// Safari returns once the destination and recoverable job are durable. The
    /// optional size probe must not hold the foreground bounce open; its generic
    /// tracked-work wrapper supplies the brief background execution window until
    /// the named URLSession owns the transfer.
    func testResolvedSafariDownloadPersistsThenStartsTrackedPreparationWithoutAwaitingIt() {
        let method = Self.managerSource
            .components(separatedBy: "public func startWithResolvedAssets(").last?
            .components(separatedBy: "private func createAndStartJob(").first ?? ""
        let destination = method.range(of: "SavedMediaStore.shared.ensureUndownloaded")
        let job = method.range(of: "store.upsert(job)")
        let task = method.range(of: "startMediaDownload(for: job, asset: asset)")
        XCTAssertNotNil(destination)
        XCTAssertNotNil(job)
        XCTAssertNotNil(task)
        XCTAssertFalse(method.contains("await prepareAndStartMediaDownload"))
        if let destination, let job, let task {
            XCTAssertLessThan(destination.lowerBound, job.lowerBound)
            XCTAssertLessThan(job.lowerBound, task.lowerBound)
        }
    }

    func testEveryTrackedMediaTransitionHoldsApplicationBackgroundTime() {
        let tracked = Self.managerSource
            .components(separatedBy: "private func startTrackedBackgroundWork(").last?
            .components(separatedBy: "private func finishTrackedBackgroundWork(").first ?? ""
        XCTAssertTrue(tracked.contains("MediaBackgroundTaskLease"))
        XCTAssertTrue(tracked.contains("await operation()"))
        XCTAssertTrue(tracked.contains("appBackgroundLease.end()"))
    }

    func testRedditSplitStreamsStayOnTheNamedBackgroundSession() {
        let reddit = Self.managerSource
            .components(separatedBy: "private func startRedditMuxedDownload(").last?
            .components(separatedBy: "private func reportProgress(").first ?? ""
        XCTAssertTrue(reddit.contains("role: .redditVideo"))
        XCTAssertTrue(reddit.contains("role: .redditAudio"))
        XCTAssertTrue(reddit.contains("role: .redditManifest"))
        XCTAssertFalse(reddit.contains("URLSession.shared"))
    }

    /// `mediaKind` used to be a bare `String` that three producers wrote three
    /// incompatible encodings for: `MediaAsset.Kind.rawValue` ("gif"), the old
    /// widget-facing `liveActivityKind` ("animatedImage"), and a literal
    /// "unknown" sentinel for a job with no resolved asset yet. All must still
    /// decode off disk into the one typed field.
    func testLegacyMediaKindStringsDecodeIntoTypedKind() throws {
        func decodedKind(forLegacyMediaKind raw: String) throws -> MediaAsset.Kind? {
            let json = #"{"id":"1","sourceURLString":"https://example.com","assetURLString":null,"#
                + #""mediaKind":"\#(raw)","title":"Media","resolveKind":null,"phase":"resolving","#
                + #""progress":0,"thumbnailFileName":null,"fileExtension":null,"errorMessage":null,"#
                + #""errorKind":null,"resolveAttempts":0,"mediaAttempts":0,"suspendDeadline":null}"#
            return try JSONDecoder().decode(LiveMediaDownloadJob.self, from: Data(json.utf8)).mediaKind
        }
        XCTAssertEqual(try decodedKind(forLegacyMediaKind: "gif"), .gif)
        XCTAssertEqual(try decodedKind(forLegacyMediaKind: "animatedImage"), .gif)
        XCTAssertEqual(try decodedKind(forLegacyMediaKind: "video"), .video)
        XCTAssertEqual(try decodedKind(forLegacyMediaKind: "audio"), .audio)
        XCTAssertEqual(try decodedKind(forLegacyMediaKind: "image"), .image)
        XCTAssertNil(try decodedKind(forLegacyMediaKind: "unknown"))
    }

    /// `timeRange` used to be shredded into two top-level `rangeStartSeconds`/
    /// `rangeEndSeconds` fields. An in-flight job written before the update
    /// must still decode its range (and a job with neither key decodes nil,
    /// not a zero-start range).
    func testLegacyRangeSecondsKeysDecodeIntoTimeRange() throws {
        let withRange = #"{"id":"1","sourceURLString":"https://example.com","assetURLString":null,"#
            + #""mediaKind":"video","title":"Media","resolveKind":null,"phase":"resolving","#
            + #""progress":0,"thumbnailFileName":null,"fileExtension":null,"#
            + #""rangeStartSeconds":12.5,"rangeEndSeconds":42,"#
            + #""errorMessage":null,"errorKind":null,"resolveAttempts":0,"mediaAttempts":0,"#
            + #""suspendDeadline":null}"#
        let job = try JSONDecoder().decode(LiveMediaDownloadJob.self, from: Data(withRange.utf8))
        XCTAssertEqual(job.timeRange, MediaTimeRange(startSeconds: 12.5, endSeconds: 42))

        let withoutRange = #"{"id":"1","sourceURLString":"https://example.com","assetURLString":null,"#
            + #""mediaKind":"video","title":"Media","resolveKind":null,"phase":"resolving","#
            + #""progress":0,"thumbnailFileName":null,"fileExtension":null,"#
            + #""errorMessage":null,"errorKind":null,"resolveAttempts":0,"mediaAttempts":0,"#
            + #""suspendDeadline":null}"#
        let bare = try JSONDecoder().decode(LiveMediaDownloadJob.self, from: Data(withoutRange.utf8))
        XCTAssertNil(bare.timeRange)
    }

    /// `resolveKind` used to be a bare `String`, and two producers (the
    /// URL-rescue and direct-URL starts) wrote "rescue"/"direct" literals that
    /// matched none of the enum's cases at the time — every read site's
    /// `flatMap(ResolveKind.init(rawValue:))` silently produced nil for them.
    /// Both are now real cases, and any other legacy value still safely
    /// decodes to nil rather than throwing.
    func testLegacyResolveKindStringsDecodeIntoTypedKind() throws {
        func decodedKind(forLegacyResolveKind raw: String) throws -> LiveMediaDownloadJob.ResolveKind? {
            let json = #"{"id":"1","sourceURLString":"https://example.com","assetURLString":null,"#
                + #""mediaKind":null,"title":"Media","resolveKind":"\#(raw)","phase":"resolving","#
                + #""progress":0,"thumbnailFileName":null,"fileExtension":null,"errorMessage":null,"#
                + #""errorKind":null,"resolveAttempts":0,"mediaAttempts":0,"suspendDeadline":null}"#
            return try JSONDecoder().decode(LiveMediaDownloadJob.self, from: Data(json.utf8)).resolveKind
        }
        XCTAssertEqual(try decodedKind(forLegacyResolveKind: "rescue"), .rescue)
        XCTAssertEqual(try decodedKind(forLegacyResolveKind: "direct"), .direct)
        XCTAssertEqual(try decodedKind(forLegacyResolveKind: "youtubeClip"), .youtubeClip)
        XCTAssertNil(try decodedKind(forLegacyResolveKind: "somethingUnrecognized"))
    }

    func testResumePolicyRestartsOnlyTransferPhasesWithoutAnActiveTask() {
        XCTAssertTrue(LiveMediaDownloadResumePolicy.shouldRestart(
            phase: .resolving, hasActiveTask: false))
        XCTAssertTrue(LiveMediaDownloadResumePolicy.shouldRestart(
            phase: .downloading, hasActiveTask: false))
        XCTAssertTrue(LiveMediaDownloadResumePolicy.shouldRestart(
            phase: .waiting, hasActiveTask: false))

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
            assetURLString: nil, mediaKind: nil, title: "Media",
            resolveKind: .x, phase: .resolving, progress: 0,
            thumbnailFileName: nil, fileExtension: nil,
            expectedByteCount: nil, receivedByteCount: nil,
            resumeDataFileName: nil, timeRange: nil,
            resolvedVideoID: nil, youtubeVisitorData: nil, errorMessage: nil,
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

    func testIntentSizePolicyOnlyAwaitsKnownFilesAtOrBelowLimit() {
        XCTAssertTrue(IntentMediaDownloadPolicy.shouldAwait(
            expectedByteCount: IntentMediaDownloadPolicy.inlineByteLimit))
        XCTAssertFalse(IntentMediaDownloadPolicy.shouldAwait(
            expectedByteCount: IntentMediaDownloadPolicy.inlineByteLimit + 1))
        XCTAssertFalse(IntentMediaDownloadPolicy.shouldAwait(expectedByteCount: nil))
    }

    func testStoragePolicyIncludesReserveAndTransferOverhead() {
        let expected: Int64 = 1_000_000_000
        let required = MediaStoragePolicy.requiredByteCount(expectedByteCount: expected)
        XCTAssertFalse(MediaStoragePolicy.hasCapacity(
            expectedByteCount: expected, availableByteCount: required - 1))
        XCTAssertTrue(MediaStoragePolicy.hasCapacity(
            expectedByteCount: expected, availableByteCount: required))
        XCTAssertEqual(
            MediaStoragePolicy.requiredByteCount(
                expectedByteCount: expected, requiresProcessingCopy: true),
            required + expected)
    }
}
