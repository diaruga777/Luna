//
//  SavedFileOwnershipTests.swift
//  LunaTests
//
//  Who owns the files beside the database, and what happens when the last owner
//  goes: the triggers that free a `files` row, the queue that survives a crash
//  between commit and unlink, and the reaper that does the unlinking.
//
//  Every assertion here reads the database through a SECOND connection, the way
//  another process would.
//

import LunaModels
@testable import LunaStorage
import XCTest

final class SavedFileOwnershipTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileOwnershipTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: articlesDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        // A test that locked the directory to fail an unlink has to hand it back
        // before the tree can be removed.
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: articlesDirectory.path)
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    // MARK: - Fixtures

    private func makeStore() -> SavesStore {
        SavesStore(containerURL: directory)
    }

    private var articlesDirectory: URL {
        directory.appendingPathComponent("Articles", isDirectory: true)
    }

    private func openDatabase() throws -> SavesDatabase {
        try SavesDatabase(fileURL: directory.appendingPathComponent("saves.sqlite"))
    }

    private func makeImage(_ name: String) {
        try? Data("x".utf8).write(to: articlesDirectory.appendingPathComponent(name))
    }

    /// A downloaded image's owned path, through the one constructor production
    /// uses — a test cannot hand the ownership tables a raw string either.
    private func image(_ name: String) -> OwnedFilePath {
        SavedFileOwnership.imagePath(name)!
    }

    private func exists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: articlesDirectory.appendingPathComponent(name).path)
    }

    private func illustrated(_ title: String, images: [String]) -> ArticleContent {
        ArticleContent(
            title: title,
            blocks: [.init(kind: .paragraph, text: "Prose.", links: [])]
                + images.map { .init(kind: .image, text: "", links: [], imageFileName: $0) })
    }

    /// The ownership edges as another process sees them.
    private func ownedPaths(of itemID: UUID) throws -> Set<String> {
        let database = try openDatabase()
        return try database.perform { db in
            var paths: Set<String> = []
            try db.query(
                """
                SELECT files.relative_path FROM file_refs
                JOIN files ON files.id = file_refs.file_id WHERE file_refs.save_id = ?
                """,
                { try $0.bind(1, uuid: itemID) }
            ) { row in
                if let path = row.string(0) { paths.insert(path) }
            }
            return paths
        }
    }

    private func knownPaths() throws -> Set<String> {
        let database = try openDatabase()
        return try database.perform { db in
            var paths: Set<String> = []
            try db.query("SELECT relative_path FROM files") { row in
                if let path = row.string(0) { paths.insert(path) }
            }
            return paths
        }
    }

    private func pendingDeletes() throws -> [String: Int] {
        let database = try openDatabase()
        return try database.perform { db in
            var rows: [String: Int] = [:]
            try db.query("SELECT relative_path, attempts FROM pending_deletes") { row in
                if let path = row.string(0) { rows[path] = row.int(1) ?? 0 }
            }
            return rows
        }
    }

    // MARK: - The invariant

    /// The whole point of the trigger: a `files` row never sits at zero edges. The
    /// last edge to go takes the row with it and leaves the path queued.
    func testLastEdgeDeletedDropsTheFileRowAndQueuesThePath() throws {
        let database = try openDatabase()
        let store = makeStore()
        let one = store.add(urlString: "https://example.com/one")
        let two = store.add(urlString: "https://example.com/two")
        try database.transaction { db in
            try SavedFileOwnership.attach(
                path: image("img-shared.jpg"), kind: .image, to: one.id, in: db)
            try SavedFileOwnership.attach(
                path: image("img-shared.jpg"), kind: .image, to: two.id, in: db)
        }

        try database.transaction { db in
            try SavedFileOwnership.detach(path: image("img-shared.jpg"), from: one.id, in: db)
        }
        XCTAssertEqual(try knownPaths(), ["Articles/img-shared.jpg"], "one owner left")
        XCTAssertTrue(try pendingDeletes().isEmpty)

        try database.transaction { db in
            try SavedFileOwnership.detach(path: image("img-shared.jpg"), from: two.id, in: db)
        }
        XCTAssertTrue(try knownPaths().isEmpty, "no owners left, so no file row")
        XCTAssertEqual(Array(try pendingDeletes().keys), ["Articles/img-shared.jpg"])
    }

    /// A path that reached the queue is retired permanently. A new owner cannot
    /// revive it; a re-download must use a different generated image name.
    func testReReferencingAQueuedPathDoesNotRescueIt() throws {
        let database = try openDatabase()
        let store = makeStore()
        let first = store.add(urlString: "https://example.com/first")
        let second = store.add(urlString: "https://example.com/second")
        try database.transaction { db in
            try SavedFileOwnership.attach(
                path: image("img-rescued.jpg"), kind: .image, to: first.id, in: db)
            try SavedFileOwnership.detach(path: image("img-rescued.jpg"), from: first.id, in: db)
        }
        XCTAssertEqual(Array(try pendingDeletes().keys), ["Articles/img-rescued.jpg"])

        try database.transaction { db in
            try SavedFileOwnership.attach(
                path: image("img-rescued.jpg"), kind: .image, to: second.id, in: db)
        }

        XCTAssertEqual(Array(try pendingDeletes().keys), ["Articles/img-rescued.jpg"])
        XCTAssertTrue(try knownPaths().isEmpty)

        makeImage("img-rescued.jpg")
        store.reapPendingDeletes()
        XCTAssertFalse(exists("img-rescued.jpg"))
        try database.transaction { db in
            try SavedFileOwnership.attach(
                path: image("img-rescued.jpg"), kind: .image, to: second.id, in: db)
        }
        XCTAssertTrue(try knownPaths().isEmpty, "reaping does not forget the tombstone")
    }

    /// Reuse is an atomic database claim, not a filename lookup. Once the live
    /// mapping is released, neither a queued nor a fully reaped path can be
    /// claimed for a later save.
    func testClaimingAnImageRejectsItsRetiredSourceMapping() throws {
        let database = try openDatabase()
        let store = makeStore()
        let sourceURL = "https://images.example.com/hero.jpg"
        let name = "img-\(UUID().uuidString).jpg"
        makeImage(name)
        let first = store.add(urlString: "https://example.com/first")
        _ = store.saveContent(ArticleContent(
            title: "First",
            blocks: [.init(kind: .image, text: "", links: [],
                           imageURLString: sourceURL, imageFileName: name)]), for: first)

        try database.transaction { db in
            try SavedFileOwnership.detach(path: image(name), from: first.id, in: db)
        }
        let second = store.add(urlString: "https://example.com/second")
        XCTAssertNil(store.claimLiveImageCopy(
            sourceURL: sourceURL, for: second.id, animatedGIFOnly: false))

        store.reapPendingDeletes()
        let third = store.add(urlString: "https://example.com/third")
        XCTAssertNil(store.claimLiveImageCopy(
            sourceURL: sourceURL, for: third.id, animatedGIFOnly: false))
    }

    /// The assumption the whole design rests on, tested rather than assumed:
    /// SQLite fires an `AFTER DELETE` trigger for a row removed by an
    /// `ON DELETE CASCADE`, with `recursive_triggers` left at its default. If it
    /// did not, deleting a save would silently free nothing.
    func testDeletingASaveCascadesThroughTheEdgesAndFiresTheReleaseTrigger() throws {
        let database = try openDatabase()
        let store = makeStore()
        let item = store.add(urlString: "https://example.com/cascade")
        try database.transaction { db in
            try SavedFileOwnership.attach(
                path: SavedFileOwnership.articlesPath("\(item.id.uuidString).json")!,
                kind: .content, to: item.id, in: db)
            try SavedFileOwnership.attach(
                path: image("img-cascade.jpg"), kind: .image, to: item.id, in: db)
        }

        // Straight through SQL, so nothing but the cascade and the trigger can be
        // doing the work.
        try database.transaction { db in
            try db.run("DELETE FROM saves WHERE id = ?") { try $0.bind(1, uuid: item.id) }
        }

        XCTAssertTrue(try knownPaths().isEmpty)
        XCTAssertEqual(
            Set(try pendingDeletes().keys),
            ["Articles/\(item.id.uuidString).json", "Articles/img-cascade.jpg"])
    }

    // MARK: - Through the store

    /// A save's own columns decide what it owns, at every row write: the content
    /// file it was given, the thumbnail written later, the images inside the
    /// content.
    func testSavingAnArticleTakesItsContentImagesAndThumbnail() throws {
        let store = makeStore()
        makeImage("img-lead.jpg")
        makeImage("img-body.png")
        let item = store.add(urlString: "https://example.com/illustrated")

        let saved = store.saveContent(illustrated("Illustrated", images: ["img-lead.jpg", "img-body.png"]), for: item)
        store.setThumbnail(Data("thumb".utf8), for: item.id)

        XCTAssertEqual(saved.state, .ready)
        XCTAssertEqual(try ownedPaths(of: item.id), [
            "Articles/\(item.id.uuidString).json",
            "Articles/\(item.id.uuidString)-thumb.jpg",
            "Articles/img-lead.jpg",
            "Articles/img-body.png",
        ])
    }

    /// Deleting the save deletes every file it held, and the row keeps none of it.
    func testDeletingASaveRemovesEveryFileItHeld() throws {
        let store = makeStore()
        makeImage("img-only.jpg")
        let item = store.add(urlString: "https://example.com/solo")
        let saved = store.saveContent(illustrated("Solo", images: ["img-only.jpg"]), for: item)
        store.saveWebArchive(Data("archive".utf8), for: saved)
        store.setThumbnail(Data("thumb".utf8), for: item.id)

        store.delete(store.item(withID: item.id) ?? saved)

        XCTAssertTrue(try ownedPaths(of: item.id).isEmpty)
        XCTAssertTrue(try pendingDeletes().isEmpty, "the reaper ran, so nothing is still queued")
        XCTAssertFalse(exists("img-only.jpg"))
        XCTAssertFalse(exists("\(item.id.uuidString).json"))
        XCTAssertFalse(exists("\(item.id.uuidString)-thumb.jpg"))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("OriginalArchives")
                .appendingPathComponent("\(item.id.uuidString).webarchive").path))
    }

    /// A tracked product's photo goes with the tracker's save. It is written by the
    /// price ingestor, outside the store, and owned from the moment the tracker's
    /// column names it.
    func testDeletingATrackedProductRemovesItsArtwork() throws {
        let store = makeStore()
        let item = store.add(urlString: "https://shop.example.com/thing")
        let artwork = "\(item.id.uuidString)-product.jpg"
        makeImage(artwork)
        let tracker = PriceTracker(
            productName: "Thing", firstStoreURL: "https://shop.example.com/thing",
            price: Decimal(10), currency: "USD", imageFileName: artwork)
        _ = store.savePriceTracker(tracker, for: item.id)
        XCTAssertTrue(try ownedPaths(of: item.id).contains("Articles/\(artwork)"))

        store.delete(store.item(withID: item.id)!)

        XCTAssertFalse(exists(artwork))
    }

    /// Two saves showing the same picture: the file survives the first delete and
    /// goes with the second. This is the refcount, and it is the edge count.
    func testASharedImageSurvivesUntilItsLastSaveIsDeleted() throws {
        let store = makeStore()
        makeImage("img-both.jpg")
        let first = store.add(urlString: "https://example.com/a")
        let second = store.add(urlString: "https://example.com/b")
        _ = store.saveContent(illustrated("A", images: ["img-both.jpg"]), for: first)
        _ = store.saveContent(illustrated("B", images: ["img-both.jpg"]), for: second)

        store.delete(store.item(withID: first.id)!)
        XCTAssertTrue(exists("img-both.jpg"), "the second save still shows it")

        store.delete(store.item(withID: second.id)!)
        XCTAssertFalse(exists("img-both.jpg"))
    }

    /// A preloaded page is not a save, but it reads the same downloaded images. One
    /// of each holding the same file means the file outlives either one alone.
    func testAnImageSharedWithAPreloadedPageOutlivesTheSave() throws {
        let store = makeStore()
        makeImage("img-page.jpg")
        let item = store.add(urlString: "https://example.com/article")
        _ = store.saveContent(illustrated("Article", images: ["img-page.jpg"]), for: item)
        store.setPreloadedPageImages(pageKey: "page-hash", fileNames: ["img-page.jpg"])

        store.delete(store.item(withID: item.id)!)
        XCTAssertTrue(exists("img-page.jpg"), "the preloaded page still holds it")

        store.releasePreloadedPages(pageKeys: ["page-hash"])
        XCTAssertFalse(exists("img-page.jpg"))
    }

    /// Re-declaring what a page holds drops what it no longer does.
    func testReplacingAPreloadedPagesImagesFreesTheOnesItDropped() throws {
        let store = makeStore()
        makeImage("img-kept.jpg")
        makeImage("img-dropped.jpg")
        store.setPreloadedPageImages(
            pageKey: "page", fileNames: ["img-kept.jpg", "img-dropped.jpg"])

        store.setPreloadedPageImages(pageKey: "page", fileNames: ["img-kept.jpg"])

        XCTAssertTrue(exists("img-kept.jpg"))
        XCTAssertFalse(exists("img-dropped.jpg"))
    }

    /// An image name that did not come from the image downloader is never recorded,
    /// so nothing can arrive at the reaper through a crafted article's content.
    func testContentCannotClaimAFileTheImageDownloaderWouldNotHaveWritten() throws {
        let store = makeStore()
        makeImage("saves.sqlite")
        let item = store.add(urlString: "https://example.com/crafted")

        _ = store.saveContent(
            illustrated("Crafted", images: ["saves.sqlite", "../escape.jpg"]), for: item)

        XCTAssertEqual(try ownedPaths(of: item.id), ["Articles/\(item.id.uuidString).json"])
        store.delete(store.item(withID: item.id)!)
        XCTAssertTrue(exists("saves.sqlite"))
    }

    /// The archive's capture input is named from the id rather than a column, so it
    /// takes its own edge — and releasing it is what deletes it.
    func testReaderSourceHTMLIsOwnedUntilItIsDropped() throws {
        let store = makeStore()
        let item = store.add(urlString: "https://example.com/paywalled")
        store.saveReaderSourceHTML("<html>whole article</html>", for: item.id)
        let path = "OriginalArchives/\(item.id.uuidString)-reader-source.html"
        XCTAssertTrue(try ownedPaths(of: item.id).contains(path))
        XCTAssertEqual(store.readerSourceHTML(for: item.id), "<html>whole article</html>")

        store.removeReaderSourceHTML(for: item.id)

        XCTAssertFalse(try ownedPaths(of: item.id).contains(path))
        XCTAssertNil(store.readerSourceHTML(for: item.id))
    }

    // MARK: - The reaper

    /// An edge written through one store instance is released and unlinked by
    /// another — two connections on one file, which is what an extension and its
    /// app are.
    func testAFileOwnedThroughOneInstanceIsReapedByAnother() throws {
        let writer = makeStore()
        let reaper = makeStore()
        makeImage("img-crossing.jpg")
        let item = writer.add(urlString: "https://example.com/crossing")
        _ = writer.saveContent(illustrated("Crossing", images: ["img-crossing.jpg"]), for: item)

        reaper.delete(reaper.item(withID: item.id)!)

        XCTAssertFalse(exists("img-crossing.jpg"))
        XCTAssertTrue(try pendingDeletes().isEmpty)
    }

    /// A file already gone is a finished job, not a failure: the row goes.
    func testAQueuedPathWhoseFileIsAlreadyAbsentClearsItsRow() throws {
        let database = try openDatabase()
        let store = makeStore()
        let item = store.add(urlString: "https://example.com/ghost")
        try database.transaction { db in
            try SavedFileOwnership.attach(
                path: image("img-ghost.jpg"), kind: .image, to: item.id, in: db)
            try SavedFileOwnership.detach(path: image("img-ghost.jpg"), from: item.id, in: db)
        }
        XCTAssertFalse(exists("img-ghost.jpg"), "the file was never written")

        store.reapPendingDeletes()

        XCTAssertTrue(try pendingDeletes().isEmpty)
    }

    /// An unlink that fails keeps its row and counts the attempt, so the next run
    /// tries again — and does the job once the file can be removed.
    func testAFailedUnlinkKeepsTheRowAndCountsTheAttempt() throws {
        let database = try openDatabase()
        let store = makeStore()
        makeImage("img-locked.jpg")
        let item = store.add(urlString: "https://example.com/locked")
        try database.transaction { db in
            try SavedFileOwnership.attach(
                path: image("img-locked.jpg"), kind: .image, to: item.id, in: db)
            try SavedFileOwnership.detach(path: image("img-locked.jpg"), from: item.id, in: db)
        }
        // A read-only directory is an unlink that cannot succeed.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500], ofItemAtPath: articlesDirectory.path)

        store.reapPendingDeletes()
        XCTAssertEqual(try pendingDeletes(), ["Articles/img-locked.jpg": 1])
        store.reapPendingDeletes()
        XCTAssertEqual(try pendingDeletes(), ["Articles/img-locked.jpg": 2])

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: articlesDirectory.path)
        store.reapPendingDeletes()

        XCTAssertTrue(try pendingDeletes().isEmpty)
        XCTAssertFalse(exists("img-locked.jpg"))
    }

    /// Even a malformed legacy state with both an owner and a tombstone must not
    /// rescue the path: the tombstone wins and the bytes are removed.
    func testTheReaperDoesNotRescueAQueuedPathThatStillHasAnOwnerRow() throws {
        let database = try openDatabase()
        let store = makeStore()
        makeImage("img-reowned.jpg")
        let item = store.add(urlString: "https://example.com/reowned")
        try database.transaction { db in
            try SavedFileOwnership.attach(
                path: image("img-reowned.jpg"), kind: .image, to: item.id, in: db)
            // The state a kill between the two commits leaves: the path is queued
            // AND owned.
            try db.run(
                """
                INSERT OR REPLACE INTO pending_deletes (relative_path, enqueued_at, attempts)
                    VALUES ('Articles/img-reowned.jpg', 0, 0)
                """)
        }

        store.reapPendingDeletes()

        XCTAssertFalse(exists("img-reowned.jpg"))
        XCTAssertTrue(try pendingDeletes().isEmpty)
    }

    /// The reaper only ever unlinks inside the container, whatever a path says.
    func testPathsOutsideTheContainerResolveToNothing() {
        let container = URL(fileURLWithPath: "/tmp/container", isDirectory: true)
        for path in ["../escape.jpg", "/etc/hosts", "", "Articles/../../escape.jpg"] {
            XCTAssertNil(
                PendingDeleteReaper.resolvedURL(forRelativePath: path, containerURL: container),
                "\(path) is not inside the container")
        }
        XCTAssertEqual(
            PendingDeleteReaper.resolvedURL(
                forRelativePath: "Articles/img-fine.jpg", containerURL: container)?.path,
            "/tmp/container/Articles/img-fine.jpg")
    }
}
