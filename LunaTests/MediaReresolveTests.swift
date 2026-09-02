//
//  MediaReresolveTests.swift
//  LunaTests
//

import XCTest
import LunaMediaDownload
import LunaModels
import LunaPluginIngest
import LunaPluginKit
import LunaStorage

/// The re-resolution seam and the plugin fields that route it
/// (`claudedocs/plans/plugin-platform.md` §7.6).
final class MediaReresolveTests: XCTestCase {

    private func asset(
        _ path: String, kind: MediaAsset.Kind, quality: String? = nil
    ) -> MediaAsset {
        MediaAsset(url: URL(string: "https://cdn.test/\(path)")!, kind: kind, quality: quality)
    }

    // MARK: - Matching

    func testAnAssetIsMatchedByKindAndQuality() {
        let assets = [
            asset("a.mp4", kind: .video, quality: "720p"),
            asset("b.mp4", kind: .video, quality: "1080p"),
            asset("c.m4a", kind: .audio, quality: "audio-128k"),
        ]
        XCTAssertEqual(
            MediaReresolveMatching.pick(kind: .video, quality: "1080p", from: assets)?.url
                .lastPathComponent, "b.mp4")
        XCTAssertEqual(
            MediaReresolveMatching.pick(kind: .audio, quality: nil, from: assets)?.url
                .lastPathComponent, "c.m4a")
    }

    func testAnUnknownQualityFallsBackToTheFirstAssetOfTheSameKind() {
        let assets = [
            asset("a.mp4", kind: .video, quality: "720p"),
            asset("b.mp4", kind: .video, quality: "1080p"),
        ]
        XCTAssertEqual(
            MediaReresolveMatching.pick(kind: .video, quality: "4k", from: assets)?.url
                .lastPathComponent, "a.mp4",
            "display order is the tiebreak — it is the order the save itself chose from")
    }

    func testAKindThatIsGoneFallsBackToTheWholeSet() {
        let assets = [asset("a.jpg", kind: .image)]
        XCTAssertEqual(
            MediaReresolveMatching.pick(kind: .video, quality: nil, from: assets)?.url
                .lastPathComponent, "a.jpg",
            "a plugin that changed the leg's kind is still better than no download")
    }

    func testNothingMatchesAnEmptyAnswer() {
        XCTAssertNil(MediaReresolveMatching.pick(kind: .video, quality: "1080p", from: []))
    }

    // MARK: - Staleness

    func testOnlyAPluginOwnedJobIsEverStale() {
        var job = LiveMediaDownloadJob(
            id: "j", sourceURLString: "https://example.com/p", title: "T",
            phase: .downloading, progress: 0, resolveAttempts: 0, mediaAttempts: 0)
        job.expiresAt = Date(timeIntervalSince1970: 0)
        XCTAssertFalse(
            LiveMediaDownloadManager.pluginURLsAreStale(job),
            "a Swift-resolved job has no plugin to ask, so it is never re-resolved")

        job.pluginID = "app.luna.ig"
        XCTAssertTrue(LiveMediaDownloadManager.pluginURLsAreStale(job))
    }

    func testAnUnexpiredJobIsNotStale() {
        var job = LiveMediaDownloadJob(
            id: "j", sourceURLString: "https://example.com/p", title: "T",
            phase: .downloading, progress: 0, resolveAttempts: 0, mediaAttempts: 0)
        job.pluginID = "app.luna.ig"
        job.expiresAt = Date().addingTimeInterval(3600)
        XCTAssertFalse(LiveMediaDownloadManager.pluginURLsAreStale(job))
    }

    // MARK: - Statuses

    func testOnlyTheStaleURLStatusesInviteAReresolve() {
        for status in [401, 403, 410] {
            XCTAssertTrue(LiveMediaDownloadManager.statusInvitesReresolve(status), "\(status)")
        }
        for status in [200, 404, 429, 500] {
            XCTAssertFalse(LiveMediaDownloadManager.statusInvitesReresolve(status), "\(status)")
        }
    }

    // MARK: - Headers round-trip

    func testRequestHeadersSurviveTheJobColumn() {
        let headers = ["Referer": "https://example.com/", "Cookie": "a=b"]
        let json = LiveMediaDownloadManager.headersJSON(headers)
        XCTAssertNotNil(json)
        XCTAssertEqual(LiveMediaDownloadManager.headers(fromJSON: json), headers)
        XCTAssertNil(
            LiveMediaDownloadManager.headersJSON([:]),
            "an asset with no headers writes no column value")
        XCTAssertEqual(LiveMediaDownloadManager.headers(fromJSON: nil), [:])
        XCTAssertEqual(LiveMediaDownloadManager.headers(fromJSON: "not json"), [:])
    }

    // MARK: - The resolver's walk

    func testTheResolverAsksOnlyTheNamedPluginOnReresolve() async {
        let invoker = FakePluginInvoker()
        invoker.loadedPlugins = [.fake(id: "owner"), .fake(id: "other")]
        for id in ["owner", "other"] {
            invoker.classifyAnswers[id] = .json(#"{"kind":"media","itemId":"abc"}"#)
            invoker.ingestAnswers[id] = .json("""
                {"kind":"media","assets":[
                  {"url":"https://cdn.test/fresh.mp4","type":"video","quality":"1080p"}]}
                """)
        }
        let scope = PluginAdopterScope()
        defer { scope.restore() }
        PluginModelAdopters.media = MediaModelAdopter()

        let resolver = PluginMediaResolver(invoker: invoker, processKind: .app)
        let assets = await resolver.reresolve(
            sourceURL: URL(string: "https://example.com/p/abc")!,
            pluginID: "owner", saveID: "job-1")

        XCTAssertEqual(assets?.first?.url.absoluteString, "https://cdn.test/fresh.mp4")
        XCTAssertEqual(assets?.first?.quality, "1080p")
        XCTAssertTrue(
            invoker.calls.allSatisfy { $0.pluginID == "owner" },
            "a job's re-resolution goes back to its own plugin, never to another")
        XCTAssertEqual(invoker.ingestReasons, ["reresolve"])
    }
}
