//
//  PreloadStoreTests.swift
//  LunaTests
//

import LunaSaves
import LunaReaderUI
import LunaDesignSystem
import LunaModels
import XCTest
@testable import Luna
@testable import LunaStorage

final class PreloadStoreTests: XCTestCase {
    private var dir: URL!
    private var store: PreloadStore!
    private var saves: SavesStore!

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PreloadTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        store = PreloadStore(containerURL: dir)
        // Wired to THIS preload store, so a delete releases the tree in the test's
        // own container rather than the shared one.
        saves = SavesStore(containerURL: dir, preloadStore: store)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    private func url(_ s: String) -> URL { URL(string: s)! }

    /// A root a preloaded page can actually be owned by. Ownership is a `file_refs`
    /// edge now, so a root that is not a save holds nothing — which is the point:
    /// deleting the save is what releases its tree.
    private func makeSave() -> UUID {
        saves.add(urlString: "https://example.com/root-\(UUID().uuidString)").id
    }

    /// The file a page's content is in, as the database records it.
    private func pageFile(_ u: URL) -> String? {
        saves.preloadPageFileName(urlKey: PreloadStore.key(for: u))
    }

    private func pageFileExists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: store.contentURL(fileName: name).path)
    }
    private func article(_ title: String) -> ArticleContent {
        ArticleContent(title: title, blocks: [
            .init(kind: .paragraph, text: String(repeating: "a", count: 1500), links: []),
        ])
    }

    func testKeyCanonicalizationIgnoresFragmentAndHostCase() {
        let a = PreloadStore.key(for: url("https://Example.com/story#section"))
        let b = PreloadStore.key(for: url("https://example.com/story"))
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, PreloadStore.key(for: url("https://example.com/other")))
    }

    func testRecordAndReadBackArticle() {
        let u = url("https://example.com/a")
        store.record(url: u, rootID: makeSave(), kind: .article, content: article("A"))
        XCTAssertEqual(store.articleContent(for: u)?.title, "A")
        XCTAssertEqual(store.entry(for: u)?.kind, .article)
    }

    func testRecordedArticleIsNotImmediatelyRefreshDue() {
        let u = url("https://example.com/fresh")
        store.record(url: u, rootID: makeSave(), kind: .article, content: article("Fresh"))

        XCTAssertFalse(store.articleRefreshDue(for: u, minimumAge: 48 * 60 * 60))
        XCTAssertNotNil(store.entry(for: u)?.lastLoadedAt)
    }

    func testAnArticleIsRefreshDueOnceItPassesTheMinimumAge() {
        let u = url("https://example.com/stale")
        store.record(url: u, rootID: makeSave(), kind: .article, content: article("Stale"))

        XCTAssertFalse(store.articleRefreshDue(for: u, minimumAge: 48 * 60 * 60))
        XCTAssertTrue(store.articleRefreshDue(
            for: u, now: Date(timeIntervalSinceNow: 49 * 60 * 60),
            minimumAge: 48 * 60 * 60))
    }

    func testRefreshingAnArticleResetsItsAge() {
        let u = url("https://example.com/refreshed")
        store.record(url: u, rootID: makeSave(), kind: .article, content: article("First"))
        let later = Date(timeIntervalSinceNow: 49 * 60 * 60)
        XCTAssertTrue(store.articleRefreshDue(for: u, now: later, minimumAge: 48 * 60 * 60))

        store.refreshArticle(for: u, content: article("Refreshed"))

        XCTAssertFalse(store.articleRefreshDue(for: u, minimumAge: 48 * 60 * 60))
        XCTAssertEqual(store.articleContent(for: u)?.title, "Refreshed")
    }

    /// The library is rows now, so the retired JSON index is not read — and the
    /// store clears it away rather than leaving a store nothing consults.
    func testTheRetiredJSONIndexIsDeletedAndNeverRead() throws {
        let u = url("https://example.com/ignored")
        let key = PreloadStore.key(for: u)
        let index = #"{"\#(key)":{"urlString":"\#(u.absoluteString)","kind":"article","children":[]}}"#
        let indexURL = store.contentURL(fileName: "preloads.json")
        try Data(index.utf8).write(to: indexURL, options: .atomic)

        store.releaseTree(rootID: makeSave())

        XCTAssertNil(store.entry(for: u), "a retired index entry is not a page")
        XCTAssertFalse(FileManager.default.fileExists(atPath: indexURL.path))
    }

    // MARK: - Synchronous / in-memory cache (instant, spinner-free opens)

    /// `record` warms the in-memory cache so the very first tap is a synchronous hit.
    func testRecordWarmsSynchronousCache() {
        let u = url("https://example.com/sync")
        store.record(url: u, rootID: makeSave(), kind: .article, content: article("Sync"))
        XCTAssertEqual(store.synchronousArticleContent(for: u)?.title, "Sync")
    }

    /// A fresh store (cold memory, warm disk — i.e. after relaunch) still resolves a
    /// preloaded article synchronously by decoding from disk and warming memory.
    func testSynchronousReadFromDiskOnColdMemory() {
        let u = url("https://example.com/cold")
        store.record(url: u, rootID: makeSave(), kind: .article, content: article("Cold"))
        // A new store instance over the same container has an empty in-memory cache.
        let fresh = PreloadStore(containerURL: dir)
        XCTAssertEqual(fresh.synchronousArticleContent(for: u)?.title, "Cold")
        // Second call is now served from the warmed memory cache (same result).
        XCTAssertEqual(fresh.synchronousArticleContent(for: u)?.title, "Cold")
    }

    func testSynchronousReadMissReturnsNil() {
        XCTAssertNil(store.synchronousArticleContent(for: url("https://example.com/never")))
    }

    /// Releasing the last owner evicts the entry from the in-memory cache too (not just
    /// disk), so a stale page can't be served synchronously after teardown.
    func testReleaseEvictsSynchronousCache() {
        let u = url("https://example.com/evict")
        let root = makeSave()
        store.record(url: u, rootID: root, kind: .article, content: article("E"))
        XCTAssertNotNil(store.synchronousArticleContent(for: u))
        store.releaseTree(rootID: root)
        XCTAssertNil(store.synchronousArticleContent(for: u))
    }

    func testRefcountKeepsSharedCopyUntilLastOwnerReleased() throws {
        let u = url("https://example.com/shared")
        let root1 = makeSave(), root2 = makeSave()
        store.record(url: u, rootID: root1, kind: .article, content: article("S"))
        store.record(url: u, rootID: root2, kind: .article, content: article("S"))
        let file = try XCTUnwrap(pageFile(u))
        XCTAssertEqual(store.entry(for: u)?.contentFile, file,
                       "the index names the file the database handed out")

        // Releasing one owner leaves the shared copy intact.
        store.releaseTree(rootID: root1)
        XCTAssertNotNil(store.entry(for: u))
        XCTAssertTrue(pageFileExists(file))

        // Releasing the last owner deletes the entry and its file.
        store.releaseTree(rootID: root2)
        XCTAssertNil(store.entry(for: u))
        XCTAssertFalse(pageFileExists(file))
    }

    /// Deleting the save is the whole operation: its edges cascade, the page's
    /// last edge frees the file, and the reaper unlinks it.
    func testDeletingTheSaveReleasesItsPreloadedPages() throws {
        let u = url("https://example.com/cascaded")
        let root = saves.add(urlString: "https://example.com/root-article")
        store.record(url: u, rootID: root.id, kind: .article, content: article("C"))
        let file = try XCTUnwrap(pageFile(u))
        XCTAssertTrue(pageFileExists(file))

        saves.delete(root)

        XCTAssertNil(pageFile(u), "the mapping cascaded away with the save")
        XCTAssertFalse(pageFileExists(file))
    }

    /// A released page's path is retired with every other freed artifact, so
    /// preloading the same URL again lands somewhere else.
    func testAPageReloadedAfterReleaseGetsADifferentFile() throws {
        let u = url("https://example.com/reloaded")
        let first = makeSave()
        store.record(url: u, rootID: first, kind: .article, content: article("First"))
        let firstFile = try XCTUnwrap(pageFile(u))
        store.releaseTree(rootID: first)

        store.record(url: u, rootID: makeSave(), kind: .article, content: article("Second"))
        let secondFile = try XCTUnwrap(pageFile(u))

        XCTAssertNotEqual(secondFile, firstFile)
        XCTAssertEqual(store.articleContent(for: u)?.title, "Second")
    }

    func testAddOwnerForDedup() throws {
        let u = url("https://example.com/x")
        let root1 = makeSave(), root2 = makeSave()
        store.record(url: u, rootID: root1, kind: .article, content: article("X"))
        let file = try XCTUnwrap(pageFile(u))

        XCTAssertNotNil(store.addOwner(root2, toKey: PreloadStore.key(for: u)))
        XCTAssertEqual(pageFile(u), file, "extending ownership does not re-file the page")

        store.releaseTree(rootID: root1)
        XCTAssertTrue(pageFileExists(file), "the second root still holds it")
        store.releaseTree(rootID: root2)
        XCTAssertFalse(pageFileExists(file))
    }

    /// `addOwner` extends ownership over a cached page. It never creates one, so a
    /// key the cache has never seen stays unowned.
    func testAddOwnerOnAnUnknownKeyRecordsNothing() {
        let u = url("https://n.example/1")
        XCTAssertNil(store.addOwner(makeSave(), toKey: PreloadStore.key(for: u)))
        XCTAssertNil(pageFile(u))
    }

    func testUnrepresentableStoresNoFile() throws {
        let u = url("https://paywall.example/x")
        let e = try XCTUnwrap(store.record(url: u, rootID: makeSave(), kind: .unrepresentable))
        XCTAssertEqual(e.kind, .unrepresentable)
        XCTAssertFalse(e.loadedSuccessfully)
        XCTAssertNil(e.contentFile)
        XCTAssertNil(store.articleContent(for: u))
    }

    /// A page that caches no content still holds a name, which is what lets one
    /// mechanism count every page. Releasing it drops the entry and writes nothing.
    func testAPageWithNoContentStillReservesAndReleasesAName() throws {
        let u = url("https://paywall.example/reserved")
        let root = makeSave()
        store.record(url: u, rootID: root, kind: .unrepresentable)
        let reserved = try XCTUnwrap(pageFile(u))
        XCTAssertFalse(pageFileExists(reserved), "a reserved name is not a written file")

        store.releaseTree(rootID: root)
        XCTAssertNil(pageFile(u))
        XCTAssertNil(store.entry(for: u))
    }

    /// A root that is not a save has nothing to cascade from, so it can hold
    /// nothing. Only the two sentinels are allowed to own without a save.
    func testARootThatIsNotASaveOwnsNothing() {
        let u = url("https://example.com/unowned")
        XCTAssertNil(store.record(url: u, rootID: UUID(), kind: .article, content: article("U")))
        XCTAssertNil(store.entry(for: u))
        XCTAssertNil(pageFile(u))
    }

    func testOutboundURLsDedupesAndFiltersToHTTP() {
        let content = ArticleContent(title: "T", blocks: [
            .init(kind: .paragraph, text: "x", links: [
                .init(start: 0, length: 1, urlString: "https://a.com/1"),
                .init(start: 0, length: 1, urlString: "https://a.com/1"), // dup
                .init(start: 0, length: 1, urlString: "mailto:x@y.com"),  // non-http
            ]),
            .init(kind: .paragraph, text: "y", links: [
                .init(start: 0, length: 1, urlString: "http://b.com/2"),
            ]),
        ])
        XCTAssertEqual(
            PreloadCoordinator.outboundURLs(from: content).map(\.absoluteString),
            ["https://a.com/1", "http://b.com/2"])
    }

    func testPreloadDepthClamps() {
        let original = ReaderSettings.preloadDepth
        defer { ReaderSettings.preloadDepth = original }
        ReaderSettings.preloadDepth = 9
        XCTAssertEqual(ReaderSettings.preloadDepth, 5)
        ReaderSettings.preloadDepth = -2
        XCTAssertEqual(ReaderSettings.preloadDepth, 0)
    }

    func testPreloadWiFiOnlyDefaultsOffAndRoundTrips() {
        let defaults = UserDefaults(suiteName: ReaderSettings.appGroupID) ?? .standard
        let original = defaults.object(forKey: "preloadWiFiOnly")
        defer {
            if let original { defaults.set(original, forKey: "preloadWiFiOnly") }
            else { defaults.removeObject(forKey: "preloadWiFiOnly") }
        }

        defaults.removeObject(forKey: "preloadWiFiOnly")
        XCTAssertFalse(ReaderSettings.preloadWiFiOnly)

        ReaderSettings.preloadWiFiOnly = true
        XCTAssertTrue(ReaderSettings.preloadWiFiOnly)
        ReaderSettings.preloadWiFiOnly = false
        XCTAssertFalse(ReaderSettings.preloadWiFiOnly)
    }

    // MARK: - Session ownership — the two owners that are not saves

    /// The pasteboard candidate has no save to cascade from, so it holds through
    /// `file_holders` instead — and releasing it still frees the page.
    func testSessionOnlyOwnedEntryDeletedOnRelease() throws {
        let u = url("https://example.com/speculative")
        let session = PreloadStore.pasteboardOwner
        store.record(url: u, rootID: session, kind: .article, content: article("S"))
        XCTAssertNotNil(store.articleContent(for: u))
        let file = try XCTUnwrap(pageFile(u))

        store.releaseTree(rootID: session)
        XCTAssertNil(store.entry(for: u))
        XCTAssertFalse(pageFileExists(file))
    }

    func testWithinDepthEntrySurvivesSessionRelease() throws {
        let u = url("https://example.com/durable")
        let root = makeSave()
        let session = PreloadStore.pasteboardOwner
        // A within-depth page is owned by BOTH the durable root and the session.
        store.record(url: u, rootID: root, kind: .article, content: article("D"))
        store.record(url: u, rootID: session, kind: .article, content: article("D"))
        let file = try XCTUnwrap(pageFile(u))

        store.releaseTree(rootID: session)
        // Session gone, durable root remains → page survives.
        XCTAssertTrue(pageFileExists(file))
        XCTAssertNotNil(store.articleContent(for: u))

        store.releaseTree(rootID: root)
        XCTAssertFalse(pageFileExists(file))
    }

    /// A tapped link outlives the save that surfaced it: the user reached it, so
    /// its own owner keeps the page after the save's edges cascade away.
    func testATappedLinkSurvivesTheSaveThatSurfacedIt() throws {
        let u = url("https://example.com/tapped")
        let root = saves.add(urlString: "https://example.com/surfacing-article")
        store.record(url: u, rootID: root.id, kind: .article, content: article("T"))
        store.addOwner(PreloadStore.tappedLinkOwner, toKey: PreloadStore.key(for: u))
        let file = try XCTUnwrap(pageFile(u))

        saves.delete(root)

        XCTAssertTrue(pageFileExists(file))
        XCTAssertEqual(store.articleContent(for: u)?.title, "T")
    }

    // MARK: - Image reference counting via the preload lifecycle

    /// `PreloadStore(containerURL:)` counts its image ownership in the saves
    /// database in the SAME container, so a preloaded page's images live in
    /// `<dir>/Articles` beside a save's.
    private var articlesDir: URL { dir.appendingPathComponent("Articles", isDirectory: true) }

    private func makeImageFile(_ name: String) {
        try? FileManager.default.createDirectory(at: articlesDir, withIntermediateDirectories: true)
        try? Data("x".utf8).write(to: articlesDir.appendingPathComponent(name))
    }

    private func imageExists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: articlesDir.appendingPathComponent(name).path)
    }

    private func articleWithImage(_ file: String) -> ArticleContent {
        ArticleContent(title: "A", blocks: [
            .init(kind: .image, text: "", links: [], imageFileName: file),
            .init(kind: .paragraph, text: String(repeating: "a", count: 1500), links: []),
        ])
    }

    func testReleasingLastOwnerDeletesPreloadImages() {
        makeImageFile("img-pre.jpg")
        let u = url("https://example.com/withimage")
        let root = makeSave()
        store.record(url: u, rootID: root, kind: .article,
                     content: articleWithImage("img-pre.jpg"))
        XCTAssertTrue(imageExists("img-pre.jpg"))
        store.releaseTree(rootID: root)
        XCTAssertFalse(imageExists("img-pre.jpg"))
    }

    func testSharedPreloadImageKeptWhileAnotherPageOwnsIt() {
        makeImageFile("img-shared.jpg")
        let a = url("https://example.com/a"), b = url("https://example.com/b")
        let r1 = makeSave(), r2 = makeSave()
        // Two distinct preloaded pages reference the same downloaded image.
        store.record(url: a, rootID: r1, kind: .article,
                     content: articleWithImage("img-shared.jpg"))
        store.record(url: b, rootID: r2, kind: .article,
                     content: articleWithImage("img-shared.jpg"))
        store.releaseTree(rootID: r1)
        XCTAssertTrue(imageExists("img-shared.jpg"))   // page B still owns it
        store.releaseTree(rootID: r2)
        XCTAssertFalse(imageExists("img-shared.jpg"))  // last page gone → image deleted
    }
}
