import LunaMediaDownload
import LunaStorage
import UIKit
import XCTest

final class SavedMediaStoreTests: XCTestCase {
    private var root: URL!
    private var store: SavedMediaStore!
    private var saves: SavesStore!

    override func setUpWithError() throws {
        // The interpolation here was missing its backslash, so every test in this class
        // — in every process — shared one directory literally named
        // "SavedMediaStoreTests-(UUID().uuidString)". `tearDown` hid it while runs
        // completed, but a process killed mid-suite (a WebKit jetsam `signal kill` is
        // enough) leaves the manifest behind, and the next run's FIRST test inherits it:
        // `testAddDownloadedFileDedupes…` then counted 2 items where it saved 1, while
        // every later test in the class passed on the directory its own tearDown had
        // just cleaned. Per-test isolation now actually happens.
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SavedMediaStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = SavedMediaStore(containerURL: root)
        saves = SavesStore(containerURL: root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        store = nil
        saves = nil
        root = nil
    }

    /// The save a download's files belong to. Ownership is a `file_refs` edge, so
    /// a media row whose id is not a save's owns nothing and frees nothing — which
    /// is why every row here is backed by a real one.
    private func makeSave(_ urlString: String) -> UUID {
        saves.reserveSaveAttempt(urlString: urlString, at: Date()).item.id
    }

    func testUndownloadedLocalAndPhotosTransitionsRoundTrip() async throws {
        let urlString = "https://x.com/example/status/1"
        let id = makeSave(urlString)
        let pending = try store.ensureUndownloaded(
            id: id, sourceURLString: urlString, title: "Example")
        XCTAssertEqual(pending.storageState, .undownloaded)

        let source = root.appendingPathComponent("source.mp4")
        try Data("video".utf8).write(to: source)
        let local = try await store.addDownloadedFile(
            source, kind: .video, sourceURLString: urlString, title: "Example")
        guard case .localFile(let fileName) = local.storageState else {
            return XCTFail("Expected local backing")
        }
        XCTAssertEqual(local.id, id)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: store.mediaDirectory.appendingPathComponent(fileName).path))

        let photos = try XCTUnwrap(try store.transitionToPhotosReference(
            id, localIdentifier: "photos-id", kind: .video))
        XCTAssertEqual(photos.photosLocalIdentifier, "photos-id")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: store.mediaDirectory.appendingPathComponent(fileName).path))

        let reloaded = try XCTUnwrap(
            SavedMediaStore(containerURL: root).items().first(where: { $0.id == id }))
        XCTAssertEqual(reloaded.storageState, photos.storageState)
        XCTAssertEqual(reloaded.kind, .video)
    }

    func testLegacyFileNameManifestDecodesAsLocalFile() throws {
        let directory = root.appendingPathComponent("SavedMedia", isDirectory: true)
        let files = directory.appendingPathComponent("Files", isDirectory: true)
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        let id = UUID()
        let fileName = "legacy.mp4"
        try Data("video".utf8).write(to: files.appendingPathComponent(fileName))
        let json = """
        [{
          "id":"\(id.uuidString)",
          "sourceURLString":"https://x.com/example/status/2",
          "title":"Legacy",
          "dateSaved":"2026-01-01T00:00:00Z",
          "kind":"video",
          "fileName":"\(fileName)"
        }]
        """
        try Data(json.utf8).write(to: directory.appendingPathComponent("savedMedia.json"))

        let item = try XCTUnwrap(store.items().first(where: { $0.id == id }))
        XCTAssertEqual(item.storageState, .localFile(fileName: fileName))
        XCTAssertEqual(item.kind, .video)
    }

    func testMissingLocalFileRepairsToUndownloaded() async throws {
        let source = root.appendingPathComponent("source.jpg")
        try Data("image".utf8).write(to: source)
        let local = try await store.addDownloadedFile(
            source, kind: .image, sourceURLString: "https://instagram.com/p/example", title: nil)
        let fileName = try XCTUnwrap(local.fileName)
        try FileManager.default.removeItem(
            at: store.mediaDirectory.appendingPathComponent(fileName))

        let repaired = try XCTUnwrap(store.items().first(where: { $0.id == local.id }))
        XCTAssertEqual(repaired.storageState, .undownloaded)
        XCTAssertNil(repaired.thumbnailFileName)
    }

    func testEnsureUndownloadedDedupesByPlatformItemIDAcrossDifferentlyShapedURLs() throws {
        let first = try store.ensureUndownloaded(
            id: makeSave("https://www.reddit.com/r/test/comments/abc123/some_title/"),
            sourceURLString: "https://www.reddit.com/r/test/comments/abc123/some_title/",
            title: "First shape")
        XCTAssertEqual(first.platformItemID, "abc123")

        // A share-link's resolved permalink for the SAME post, under a fresh id
        // (as if the saves list never recognized it as the same item) — must
        // merge into the existing row instead of creating a second one.
        let second = try store.ensureUndownloaded(
            id: makeSave("https://redd.it/abc123"),
            sourceURLString: "https://redd.it/abc123", title: nil)
        XCTAssertEqual(second.id, first.id)
        XCTAssertEqual(store.items().count, 1)
    }

    func testAddDownloadedFileDedupesByPlatformItemIDAndPreservesTitle() async throws {
        _ = try store.ensureUndownloaded(
            id: makeSave("https://www.reddit.com/r/test/comments/xyz789/title/"),
            sourceURLString: "https://www.reddit.com/r/test/comments/xyz789/title/",
            title: "Example")

        let source = root.appendingPathComponent("source.mp4")
        try Data("video".utf8).write(to: source)
        let local = try await store.addDownloadedFile(
            source, kind: .video, sourceURLString: "https://redd.it/xyz789", title: nil)

        XCTAssertEqual(store.items().count, 1)
        XCTAssertEqual(local.title, "Example")
        XCTAssertEqual(local.platformItemID, "xyz789")
    }

    func testExistingDownloadedItemMatchesUndownloadedOnlyAfterDownload() async throws {
        let urlString = "https://x.com/example/status/42"
        _ = try store.ensureUndownloaded(
            id: makeSave(urlString), sourceURLString: urlString, title: "Example")
        XCTAssertNil(store.existingDownloadedItem(forURLString: urlString))

        let source = root.appendingPathComponent("source.jpg")
        try Data("image".utf8).write(to: source)
        _ = try await store.addDownloadedFile(source, kind: .image, sourceURLString: urlString, title: "Example")

        let existing = try XCTUnwrap(store.existingDownloadedItem(forURLString: urlString))
        XCTAssertEqual(existing.sourceURLString, urlString)
    }

    func testExistingDownloadedItemMatchesByPlatformItemID() async throws {
        _ = try store.ensureUndownloaded(
            id: makeSave("https://www.reddit.com/r/test/comments/dup1/title/"),
            sourceURLString: "https://www.reddit.com/r/test/comments/dup1/title/",
            title: "Example")
        let source = root.appendingPathComponent("source.jpg")
        try Data("image".utf8).write(to: source)
        _ = try await store.addDownloadedFile(
            source, kind: .image,
            sourceURLString: "https://www.reddit.com/r/test/comments/dup1/title/", title: "Example")

        // A share-link token for the same post — different URL text, same platform item.
        let existing = try XCTUnwrap(
            store.existingDownloadedItem(forURLString: "https://redd.it/dup1"))
        XCTAssertEqual(existing.platformItemID, "dup1")
    }

    /// The user deleting the asset out of Photos leaves the row pointing at
    /// nothing, so the URL is no longer "already downloaded" — every save
    /// surface asking this question (App Intent handoff, extension preview, the
    /// awaited-transfer poll) must be told to download again, in whichever
    /// process it runs. The stale save is DISCARDED, exactly as the card deck's
    /// foreground reconcile discards it, and the incoming save makes a new one.
    func testExistingDownloadedItemDiscardsPhotosSaveWhoseAssetWasDeleted() async throws {
        let urlString = "https://x.com/example/status/500"
        let item = try await makePhotosBackedItem(urlString: urlString, localIdentifier: "gone-id")
        let thumbnail = try XCTUnwrap(item.thumbnailFileName)
        store.photosBackingProbe = StubBackingProbe(.deleted)

        XCTAssertNil(store.existingDownloadedItem(forURLString: urlString))
        XCTAssertTrue(store.items().isEmpty, "the stale save is gone, not repaired in place")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: store.thumbnailDirectory.appendingPathComponent(thumbnail).path))
    }

    /// The archive tray's rule is the deck's too: a missing asset leaves an
    /// archived row in place, downloadable, with its poster intact.
    func testArchivedPhotosSaveSurvivesAsUndownloadedWhenAssetWasDeleted() async throws {
        let urlString = "https://x.com/example/status/504"
        let item = try await makePhotosBackedItem(urlString: urlString, localIdentifier: "archived-id")
        let thumbnail = try XCTUnwrap(item.thumbnailFileName)
        store.setArchived(true, for: item.id, at: Date(timeIntervalSince1970: 789))
        store.photosBackingProbe = StubBackingProbe(.deleted)

        XCTAssertNil(store.existingDownloadedItem(forURLString: urlString))
        let kept = try XCTUnwrap(store.items().first(where: { $0.id == item.id }))
        XCTAssertEqual(kept.storageState, .undownloaded)
        XCTAssertTrue(kept.isArchived)
        XCTAssertEqual(kept.thumbnailFileName, thumbnail)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: store.thumbnailDirectory.appendingPathComponent(thumbnail).path))
    }

    /// Without FULL read authorization an empty fetch means "not in the selected
    /// set", not "deleted" — a Photos row must survive that verdict untouched.
    func testExistingDownloadedItemKeepsPhotosRowUnlessDeletionIsConfirmed() async throws {
        let urlString = "https://x.com/example/status/501"
        let item = try await makePhotosBackedItem(urlString: urlString, localIdentifier: "kept-id")

        for presence in [PhotosBackingPresence.present, .indeterminate] {
            store.photosBackingProbe = StubBackingProbe(presence)
            let existing = try XCTUnwrap(
                store.existingDownloadedItem(forURLString: urlString),
                "\(presence) must not be read as a deletion")
            XCTAssertEqual(existing.photosLocalIdentifier, "kept-id")
            XCTAssertEqual(
                try XCTUnwrap(store.items().first(where: { $0.id == item.id })).storageState,
                .photosReference(localIdentifier: "kept-id"))
        }
    }

    /// `ensureUndownloaded` is the call every download path makes before it
    /// starts, so discarding there is what turns the start gate's
    /// `.alreadyDownloaded` rejection back into a real transfer — and the legacy
    /// URL marker, the other dedup gate, has to go with it.
    func testEnsureUndownloadedReplacesDeletedPhotosSaveAndClearsDedupMarker() async throws {
        let urlString = "https://x.com/example/status/502"
        let stale = try await makePhotosBackedItem(urlString: urlString, localIdentifier: "stale-id")
        let wasMarked = AutoDownloadSettings.wasDownloaded(urlString)
        AutoDownloadSettings.markDownloaded(urlString)
        defer { if !wasMarked { AutoDownloadSettings.unmarkDownloaded(urlString) } }
        store.photosBackingProbe = StubBackingProbe(.deleted)

        let freshID = UUID()
        let ensured = try store.ensureUndownloaded(
            id: freshID, sourceURLString: urlString, title: "Example")
        XCTAssertEqual(ensured.id, freshID, "a new save, not the discarded one")
        XCTAssertEqual(ensured.storageState, .undownloaded)
        XCTAssertNil(ensured.thumbnailFileName)
        XCTAssertTrue(LiveMediaDownloadStartPolicy.downloaderShouldStart(
            storageState: ensured.storageState))
        XCTAssertEqual(store.items().count, 1, "the stale save didn't survive alongside it")
        XCTAssertNil(store.items().first(where: { $0.id == stale.id }))
        XCTAssertFalse(AutoDownloadSettings.wasDownloaded(urlString))
    }

    /// A local-file row never touches PhotoKit — the probe is only for rows that
    /// gave their bytes away to Photos.
    func testExistingDownloadedItemDoesNotProbePhotosForLocalRows() async throws {
        let urlString = "https://x.com/example/status/503"
        let source = root.appendingPathComponent("local.jpg")
        try makeJPEG().write(to: source)
        _ = try await store.addDownloadedFile(
            source, kind: .image, sourceURLString: urlString, title: "Local")
        let probe = StubBackingProbe(.deleted)
        store.photosBackingProbe = probe

        XCTAssertNotNil(store.existingDownloadedItem(forURLString: urlString))
        XCTAssertEqual(probe.queryCount, 0)
    }

    /// A row whose bytes moved into Photos, with the transition's file cleanup
    /// already settled.
    private func makePhotosBackedItem(
        urlString: String, localIdentifier: String
    ) async throws -> SavedMediaItem {
        let source = root.appendingPathComponent("\(UUID().uuidString).jpg")
        try makeJPEG().write(to: source)
        let local = try await store.addDownloadedFile(
            source, kind: .image, sourceURLString: urlString, title: "Example")
        return try XCTUnwrap(try store.transitionToPhotosReference(
            local.id, localIdentifier: localIdentifier, kind: .image))
    }

    func testDisplayTitleFallsBackFromTitleToURL() throws {
        let urlString = "https://x.com/example/status/99"
        let titled = try store.ensureUndownloaded(
            id: makeSave(urlString), sourceURLString: urlString, title: "A title")
        XCTAssertEqual(titled.displayTitle, "A title")

        let neither = try store.ensureUndownloaded(
            id: makeSave("https://x.com/example/status/101"),
            sourceURLString: "https://x.com/example/status/101")
        XCTAssertEqual(neither.displayTitle, "https://x.com/example/status/101")
    }

    /// The manifest is written by other flows/processes (share/action extension,
    /// download completion), so `items()`'s in-memory cache must re-stat on every
    /// call and only trust itself when the file is unchanged — never serve a
    /// stale read once another `SavedMediaStore` instance has written to the
    /// same manifest.
    func testItemsCacheRefreshesWhenManifestChangesFromAnotherInstance() throws {
        _ = try store.ensureUndownloaded(
            id: makeSave("https://x.com/example/status/200"),
            sourceURLString: "https://x.com/example/status/200", title: "First")
        XCTAssertEqual(store.items().count, 1, "primes this instance's cache")

        let other = SavedMediaStore(containerURL: root)
        _ = try other.ensureUndownloaded(
            id: makeSave("https://x.com/example/status/201"),
            sourceURLString: "https://x.com/example/status/201", title: "Second")

        XCTAssertEqual(
            store.items().count, 2,
            "a write from another instance must invalidate the stat-token cache")
    }

    func testBackgroundMutationDeliversChangeNotificationOnMainThread() {
        let changed = expectation(description: "saved media changed on main thread")
        // The observer is unscoped (`object: nil`), so it sees `.savedMediaChanged` from
        // every store alive in this process, and one mutation can also post more than
        // once. What's under test is the THREAD each delivery arrives on, not how many
        // there are — and over-fulfilling raised `NSInternalInconsistencyException`,
        // aborting the whole test process (reproducible when this class runs alone,
        // where the run reported "12 tests, 0 failures" AND a failed process).
        changed.assertForOverFulfill = false
        let token = NotificationCenter.default.addObserver(
            forName: .savedMediaChanged, object: nil, queue: nil
        ) { _ in
            XCTAssertTrue(Thread.isMainThread)
            changed.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(token) }

        let store = try! XCTUnwrap(store)
        let urlString = "https://x.com/example/status/3"
        let id = makeSave(urlString)
        DispatchQueue.global().async {
            _ = try? store.ensureUndownloaded(id: id, sourceURLString: urlString)
        }

        wait(for: [changed], timeout: 2)
    }

    func testArchiveDropsFullLocalMediaButKeepsThumbnailAndCanUnarchive() async throws {
        let urlString = "https://x.com/example/status/archive"
        let source = root.appendingPathComponent("source.jpg")
        try makeJPEG().write(to: source)
        let local = try await store.addDownloadedFile(
            source, kind: .image, sourceURLString: urlString, title: "Archived")
        let fileName = try XCTUnwrap(local.fileName)
        let thumbnail = try XCTUnwrap(local.thumbnailFileName)

        store.setArchived(true, for: local.id, at: Date(timeIntervalSince1970: 456))
        let archived = try XCTUnwrap(store.items().first(where: { $0.id == local.id }))
        XCTAssertTrue(archived.isArchived)
        XCTAssertEqual(archived.storageState, .undownloaded)
        XCTAssertEqual(archived.thumbnailFileName, thumbnail)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: store.mediaDirectory.appendingPathComponent(fileName).path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: store.thumbnailDirectory.appendingPathComponent(thumbnail).path))

        store.setArchived(false, for: local.id)
        XCTAssertFalse(try XCTUnwrap(store.items().first).isArchived)
    }

    func testRedownloadKeepsItemArchivedAndRefreshesRetentionDate() async throws {
        let urlString = "https://x.com/example/status/redownload"
        let firstSource = root.appendingPathComponent("first.jpg")
        try makeJPEG().write(to: firstSource)
        let first = try await store.addDownloadedFile(
            firstSource, kind: .image, sourceURLString: urlString, title: nil,
            dateSaved: Date(timeIntervalSince1970: 100))
        store.setArchived(true, for: first.id)

        let secondSource = root.appendingPathComponent("second.jpg")
        try makeJPEG().write(to: secondSource)
        let redownloaded = try await store.addDownloadedFile(
            secondSource, kind: .image, sourceURLString: urlString, title: nil,
            dateSaved: Date(timeIntervalSince1970: 900))

        XCTAssertTrue(redownloaded.isArchived)
        XCTAssertEqual(redownloaded.dateSaved, Date(timeIntervalSince1970: 900))
        XCTAssertNotNil(redownloaded.fileName)
        XCTAssertNotNil(redownloaded.thumbnailFileName)
    }

    func testRequiredPendingRowCannotBeResurrectedAfterDeletion() async throws {
        let urlString = "https://x.com/example/status/deleted-during-download"
        let pending = try store.ensureUndownloaded(
            id: makeSave(urlString), sourceURLString: urlString, title: "Pending")
        store.delete(pending)
        let source = root.appendingPathComponent("deleted-during-download.jpg")
        try makeJPEG().write(to: source)

        do {
            _ = try await store.addDownloadedFile(
                source, kind: .image, sourceURLString: urlString, title: "Pending",
                requiringItemID: pending.id)
            XCTFail("a deleted pending row must not be resurrectable")
        } catch {}
        XCTAssertTrue(store.items().isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    func testPhotosTransitionRetainsOpportunisticThumbnail() async throws {
        let source = root.appendingPathComponent("photos.jpg")
        try makeJPEG().write(to: source)
        let local = try await store.addDownloadedFile(
            source, kind: .image, sourceURLString: "https://instagram.com/p/photos", title: nil)
        let thumbnail = try XCTUnwrap(local.thumbnailFileName)

        let photos = try XCTUnwrap(try store.transitionToPhotosReference(
            local.id, localIdentifier: "photos-id", kind: .image))
        XCTAssertEqual(photos.thumbnailFileName, thumbnail)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: store.thumbnailDirectory.appendingPathComponent(thumbnail).path))
    }

    func testRetentionExpiryKeepsArchivedThumbnail() async throws {
        let previous = MediaRetentionSettings.option
        MediaRetentionSettings.option = .oneDay
        defer { MediaRetentionSettings.option = previous }
        let source = root.appendingPathComponent("expired.jpg")
        try makeJPEG().write(to: source)
        let local = try await store.addDownloadedFile(
            source, kind: .image, sourceURLString: "https://instagram.com/p/expired",
            title: nil, dateSaved: Date(timeIntervalSince1970: 100))
        store.setArchived(true, for: local.id)
        let firstThumbnail = try XCTUnwrap(store.items().first?.thumbnailFileName)

        // Re-download produces a local file while preserving archive state. Each
        // download generates its own poster name, so the replaced one is released.
        let redownload = root.appendingPathComponent("expired-again.jpg")
        try makeJPEG().write(to: redownload)
        _ = try await store.addDownloadedFile(
            redownload, kind: .image, sourceURLString: local.sourceURLString,
            title: nil, dateSaved: Date(timeIntervalSince1970: 200))
        let thumbnail = try XCTUnwrap(store.items().first?.thumbnailFileName)
        XCTAssertNotEqual(thumbnail, firstThumbnail)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: store.thumbnailDirectory
                    .appendingPathComponent(firstThumbnail).path),
            "the poster the re-download replaced is freed")

        store.purgeExpired(now: Date(timeIntervalSince1970: 200 + 2 * 86_400))

        let expired = try XCTUnwrap(store.items().first)
        XCTAssertTrue(expired.isArchived)
        XCTAssertEqual(expired.storageState, .undownloaded)
        XCTAssertEqual(expired.thumbnailFileName, thumbnail)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: store.thumbnailDirectory.appendingPathComponent(thumbnail).path))
    }

    private func makeJPEG() -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 40))
        return renderer.jpegData(withCompressionQuality: 0.9) { context in
            UIColor.systemPurple.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 40, height: 40))
        }
    }
}

/// States one verdict for every identifier, and counts the questions asked — the
/// simulator's photo library can't be made to hold (or lose) a specific asset.
private final class StubBackingProbe: PhotosBackingProbing {
    private let verdict: PhotosBackingPresence
    private(set) var queryCount = 0

    init(_ verdict: PhotosBackingPresence) {
        self.verdict = verdict
    }

    func presence(ofAssetWithLocalIdentifier _: String) -> PhotosBackingPresence {
        queryCount += 1
        return verdict
    }
}
