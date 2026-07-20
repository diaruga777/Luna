import LunaMediaDownload
import XCTest

final class SavedMediaStoreTests: XCTestCase {
    private var root: URL!
    private var store: SavedMediaStore!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SavedMediaStoreTests-(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = SavedMediaStore(containerURL: root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        store = nil
        root = nil
    }

    func testUndownloadedLocalAndPhotosTransitionsRoundTrip() throws {
        let id = UUID()
        let urlString = "https://x.com/example/status/1"
        let pending = try store.ensureUndownloaded(
            id: id, sourceURLString: urlString, title: "Example")
        XCTAssertEqual(pending.storageState, .undownloaded)

        let source = root.appendingPathComponent("source.mp4")
        try Data("video".utf8).write(to: source)
        let local = try store.addDownloadedFile(
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

    func testMissingLocalFileRepairsToUndownloaded() throws {
        let source = root.appendingPathComponent("source.jpg")
        try Data("image".utf8).write(to: source)
        let local = try store.addDownloadedFile(
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
            id: UUID(), sourceURLString: "https://www.reddit.com/r/test/comments/abc123/some_title/",
            title: "First shape")
        XCTAssertEqual(first.platformItemID, "abc123")

        // A share-link's resolved permalink for the SAME post, under a fresh id
        // (as if the reading list never recognized it as the same item) — must
        // merge into the existing row instead of creating a second one.
        let second = try store.ensureUndownloaded(
            id: UUID(), sourceURLString: "https://redd.it/abc123", title: nil)
        XCTAssertEqual(second.id, first.id)
        XCTAssertEqual(store.items().count, 1)
    }

    func testAddDownloadedFileDedupesByPlatformItemIDAndPreservesCreator() throws {
        _ = try store.ensureUndownloaded(
            id: UUID(), sourceURLString: "https://www.reddit.com/r/test/comments/xyz789/title/",
            title: "Example", creator: "u/example")

        let source = root.appendingPathComponent("source.mp4")
        try Data("video".utf8).write(to: source)
        let local = try store.addDownloadedFile(
            source, kind: .video, sourceURLString: "https://redd.it/xyz789", title: nil)

        XCTAssertEqual(store.items().count, 1)
        XCTAssertEqual(local.title, "Example")
        XCTAssertEqual(local.creator, "u/example")
        XCTAssertEqual(local.platformItemID, "xyz789")
    }

    func testExistingDownloadedItemMatchesUndownloadedOnlyAfterDownload() throws {
        let urlString = "https://x.com/example/status/42"
        _ = try store.ensureUndownloaded(id: UUID(), sourceURLString: urlString, title: "Example")
        XCTAssertNil(store.existingDownloadedItem(forURLString: urlString))

        let source = root.appendingPathComponent("source.jpg")
        try Data("image".utf8).write(to: source)
        _ = try store.addDownloadedFile(source, kind: .image, sourceURLString: urlString, title: "Example")

        let existing = try XCTUnwrap(store.existingDownloadedItem(forURLString: urlString))
        XCTAssertEqual(existing.sourceURLString, urlString)
    }

    func testExistingDownloadedItemMatchesByPlatformItemID() throws {
        _ = try store.ensureUndownloaded(
            id: UUID(), sourceURLString: "https://www.reddit.com/r/test/comments/dup1/title/",
            title: "Example")
        let source = root.appendingPathComponent("source.jpg")
        try Data("image".utf8).write(to: source)
        _ = try store.addDownloadedFile(
            source, kind: .image,
            sourceURLString: "https://www.reddit.com/r/test/comments/dup1/title/", title: "Example")

        // A share-link token for the same post — different URL text, same platform item.
        let existing = try XCTUnwrap(
            store.existingDownloadedItem(forURLString: "https://redd.it/dup1"))
        XCTAssertEqual(existing.platformItemID, "dup1")
    }

    func testDisplayTitleFallsBackTitleThenCreatorThenURL() throws {
        let urlString = "https://x.com/example/status/99"
        let titled = try store.ensureUndownloaded(
            id: UUID(), sourceURLString: urlString, title: "A title", creator: "A creator")
        XCTAssertEqual(titled.displayTitle, "A title")

        let creatorOnly = try store.ensureUndownloaded(
            id: UUID(), sourceURLString: "https://x.com/example/status/100", creator: "A creator")
        XCTAssertEqual(creatorOnly.displayTitle, "A creator")

        let neither = try store.ensureUndownloaded(
            id: UUID(), sourceURLString: "https://x.com/example/status/101")
        XCTAssertEqual(neither.displayTitle, "https://x.com/example/status/101")
    }

    /// The manifest is written by other flows/processes (share/action extension,
    /// download completion), so `items()`'s in-memory cache must re-stat on every
    /// call and only trust itself when the file is unchanged — never serve a
    /// stale read once another `SavedMediaStore` instance has written to the
    /// same manifest.
    func testItemsCacheRefreshesWhenManifestChangesFromAnotherInstance() throws {
        _ = try store.ensureUndownloaded(
            id: UUID(), sourceURLString: "https://x.com/example/status/200", title: "First")
        XCTAssertEqual(store.items().count, 1, "primes this instance's cache")

        let other = SavedMediaStore(containerURL: root)
        _ = try other.ensureUndownloaded(
            id: UUID(), sourceURLString: "https://x.com/example/status/201", title: "Second")

        XCTAssertEqual(
            store.items().count, 2,
            "a write from another instance must invalidate the stat-token cache")
    }

    func testBackgroundMutationDeliversChangeNotificationOnMainThread() {
        let changed = expectation(description: "saved media changed on main thread")
        let token = NotificationCenter.default.addObserver(
            forName: .savedMediaChanged, object: nil, queue: nil
        ) { _ in
            XCTAssertTrue(Thread.isMainThread)
            changed.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(token) }

        let store = try! XCTUnwrap(store)
        DispatchQueue.global().async {
            _ = try? store.ensureUndownloaded(
                id: UUID(), sourceURLString: "https://x.com/example/status/3")
        }

        wait(for: [changed], timeout: 2)
    }
}
