//
//  ResolvedMediaStoreTests.swift
//  LunaTests
//

import LunaModels
import LunaStorage
import XCTest

/// The two App-Group stores that carry Safari's in-page player across processes:
/// `ResolvedMediaCache` (what the extension just resolved, so the page never has
/// to hold a `[MediaAsset]`) and `PendingResolvedMediaStore` (what the user asked
/// to download, waiting for the app to open).
final class ResolvedMediaStoreTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!

    /// A fixed "now" so every expiry assertion is arithmetic, not wall clock.
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() {
        super.setUp()
        suiteName = "ResolvedMediaStoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    private func record(
        _ urlString: String, ago: TimeInterval = 0, assets: [MediaAsset]? = nil
    ) -> ResolvedMediaRecord {
        ResolvedMediaRecord(
            sourceURLString: urlString, title: "A post",
            assets: assets ?? [MediaAsset(url: URL(string: "https://cdn.example.com/a.mp4")!, kind: .video)],
            dateWritten: now.addingTimeInterval(-ago))
    }

    // MARK: - The cache

    private func cache(now offset: TimeInterval = 0) -> ResolvedMediaCache {
        ResolvedMediaCache(defaults: defaults, now: { self.now.addingTimeInterval(offset) })
    }

    func testCacheReturnsWhatWasStoredForThatPage() {
        cache().store(record("https://x.com/a/status/1"))
        let found = cache().record(forURLString: "https://x.com/a/status/1")
        XCTAssertEqual(found?.assets.first?.url.absoluteString, "https://cdn.example.com/a.mp4")
        XCTAssertEqual(found?.title, "A post")
    }

    func testCacheAnswersNothingForAnotherPage() {
        cache().store(record("https://x.com/a/status/1"))
        XCTAssertNil(cache().record(forURLString: "https://x.com/a/status/2"))
    }

    /// A lookup is non-destructive: the user watches the video, then decides to
    /// download it, and both taps read the same entry.
    func testCacheLookupDoesNotConsume() {
        cache().store(record("https://x.com/a/status/1"))
        XCTAssertNotNil(cache().record(forURLString: "https://x.com/a/status/1"))
        XCTAssertNotNil(cache().record(forURLString: "https://x.com/a/status/1"))
    }

    /// Re-resolving the same page replaces the old entry rather than stacking —
    /// a CDN URL that expired must not be found ahead of its replacement.
    func testCacheReplacesTheEntryForTheSamePage() {
        cache().store(record("https://x.com/a/status/1"))
        cache().store(record(
            "https://x.com/a/status/1",
            assets: [MediaAsset(url: URL(string: "https://cdn.example.com/fresh.mp4")!, kind: .video)]))
        XCTAssertEqual(cache().peekCount(defaults: defaults), 1)
        XCTAssertEqual(
            cache().record(forURLString: "https://x.com/a/status/1")?.assets.first?.url.absoluteString,
            "https://cdn.example.com/fresh.mp4")
    }

    func testCacheDropsAnEntryPastItsLifetime() {
        cache().store(record("https://x.com/a/status/1", ago: 0))
        let later = cache(now: ResolvedMediaCache.lifetime + 1)
        XCTAssertNil(later.record(forURLString: "https://x.com/a/status/1"))
    }

    func testCacheKeepsAnEntryJustInsideItsLifetime() {
        cache().store(record("https://x.com/a/status/1", ago: 0))
        let later = cache(now: ResolvedMediaCache.lifetime - 1)
        XCTAssertNotNil(later.record(forURLString: "https://x.com/a/status/1"))
    }

    /// Browsing a lot of posts must not grow the cache without bound; the
    /// OLDEST fall off, so the page the user is on is always the one retained.
    func testCacheKeepsOnlyTheMostRecentEntries() {
        let store = cache()
        for index in 0..<(ResolvedMediaCache.capacity + 4) {
            store.store(record("https://x.com/a/status/\(index)"))
        }
        XCTAssertEqual(store.peekCount(defaults: defaults), ResolvedMediaCache.capacity)
        XCTAssertNil(store.record(forURLString: "https://x.com/a/status/0"))
        XCTAssertNotNil(store.record(
            forURLString: "https://x.com/a/status/\(ResolvedMediaCache.capacity + 3)"))
    }

    // MARK: - The pending download queue

    private func pending(now offset: TimeInterval = 0) -> PendingResolvedMediaStore {
        PendingResolvedMediaStore(defaults: defaults, now: { self.now.addingTimeInterval(offset) })
    }

    func testQueueKeepsEveryPendingDownload() {
        pending().append(record("https://x.com/a/status/1"))
        pending().append(record("https://www.tiktok.com/@a/video/2"))
        XCTAssertEqual(pending().peek().count, 2)
    }

    /// Take-semantics: the app drains once, and a second drain (foreground after
    /// the deep link already fired) must not download everything again.
    func testTakeAllClearsTheQueue() {
        pending().append(record("https://x.com/a/status/1"))
        XCTAssertEqual(pending().takeAll().count, 1)
        XCTAssertTrue(pending().takeAll().isEmpty)
        XCTAssertTrue(pending().peek().isEmpty)
    }

    func testTappingTheSamePageTwiceQueuesItOnce() {
        pending().append(record("https://x.com/a/status/1"))
        pending().append(record(
            "https://x.com/a/status/1",
            assets: [MediaAsset(url: URL(string: "https://cdn.example.com/fresh.mp4")!, kind: .video)]))
        let taken = pending().takeAll()
        XCTAssertEqual(taken.count, 1)
        XCTAssertEqual(taken.first?.assets.first?.url.absoluteString, "https://cdn.example.com/fresh.mp4")
    }

    /// Nothing to download is not a queue entry — it would start a job with no
    /// asset and surface as a failed download the user never asked for.
    func testAnAssetlessRecordIsNotQueued() {
        pending().append(record("https://x.com/a/status/1", assets: []))
        XCTAssertTrue(pending().peek().isEmpty)
    }

    /// A tap the user abandons for a day still lands; one abandoned for a week
    /// does not (its CDN URLs are long dead).
    func testQueueExpiry() {
        pending().append(record("https://x.com/a/status/1"))
        XCTAssertEqual(pending(now: 24 * 60 * 60).peek().count, 1)
        XCTAssertTrue(pending(now: PendingResolvedMediaStore.lifetime + 1).peek().isEmpty)
    }

    // MARK: - Tolerance

    /// Neither store may throw or crash on a value it didn't write — a partial
    /// write, a rolled-back build, or another key colliding.
    func testCorruptDataReadsAsEmpty() {
        defaults.set(Data("not json".utf8), forKey: "media.pendingResolvedDownloads")
        defaults.set(Data("not json".utf8), forKey: "safari.resolvedMediaCache")
        XCTAssertTrue(pending().peek().isEmpty)
        XCTAssertTrue(pending().takeAll().isEmpty)
        XCTAssertNil(cache().record(forURLString: "https://x.com/a/status/1"))

        // And a write over the corruption still works.
        pending().append(record("https://x.com/a/status/1"))
        XCTAssertEqual(pending().peek().count, 1)
    }

    /// Every field the app needs to start a download survives the round trip
    /// through the shared defaults — including the ones the in-page player never
    /// sees (a split audio stream is download-only, and must still arrive).
    func testEveryAssetFieldSurvivesTheRoundTrip() throws {
        let asset = MediaAsset(
            url: URL(string: "https://v.redd.it/abc/DASH_720.mp4")!, kind: .video,
            audioURL: URL(string: "https://v.redd.it/abc/DASH_audio.mp4"),
            dashManifestURL: URL(string: "https://v.redd.it/abc/DASHPlaylist.mpd"),
            thumbnailURL: URL(string: "https://preview.redd.it/abc.jpg"),
            estimatedByteCount: 12_345,
            timeRange: MediaTimeRange(startSeconds: 3, endSeconds: 9))
        pending().append(record("https://www.reddit.com/r/a/comments/b/c/", assets: [asset]))

        let restored = try XCTUnwrap(pending().takeAll().first?.assets.first)
        XCTAssertEqual(restored, asset)
    }
}

private extension ResolvedMediaCache {
    /// The cache exposes only a keyed lookup (the extension never enumerates it),
    /// so the capacity/replacement tests count the stored array directly.
    func peekCount(defaults: UserDefaults) -> Int {
        guard let data = defaults.data(forKey: "safari.resolvedMediaCache"),
              let all = try? JSONDecoder().decode([ResolvedMediaRecord].self, from: data)
        else { return 0 }
        return all.count
    }
}
