//
//  ExtensionSaveInsertTests.swift
//  LunaTests
//
//  The save an extension performs: it has no ingestor, so it inserts through
//  `ReadingListStore.addIfAbsent` / `addImportedDocument` and lets the main app
//  finish the work. What matters here is that the insert is deduped by URL, that
//  it cannot disturb a row it does not name, and that the first one creates the
//  database.
//
//  Runs against a throwaway App Group container (`StageContainer`), which is also
//  a live check that the redirect works: without it these tests would write the
//  simulator's real saves.
//

import LunaAppConfig
import LunaModels
import LunaStorage
import XCTest

final class ExtensionSaveInsertTests: XCTestCase {

    private var container: URL!

    override func setUp() {
        super.setUp()
        container = StageContainer.activate(identifier: "extension-save-insert-tests")
    }

    override func tearDown() {
        StageContainer.deactivateForTesting()
        super.tearDown()
    }

    private var databaseURL: URL { container.appendingPathComponent("saves.sqlite") }

    /// No database yet is the extension's normal first run: the save creates it,
    /// lands a pending share-sheet row, and leaves it eligible for backup (this is
    /// durable user data).
    func testFirstSaveCreatesTheDatabaseAndLandsAPendingShareSheetRow() throws {
        let store = ReadingListStore(containerURL: container)
        XCTAssertFalse(FileManager.default.fileExists(atPath: databaseURL.path))

        let saved = store.addIfAbsent(urlString: "https://example.com/first", source: .shareSheet)

        XCTAssertNotNil(saved)
        XCTAssertEqual(store.items().map(\.urlString), ["https://example.com/first"])
        XCTAssertEqual(store.items().first?.state, .pending)
        XCTAssertEqual(store.items().first?.captureSource, .shareSheet)
        XCTAssertTrue(FileManager.default.fileExists(atPath: databaseURL.path))
        XCTAssertEqual(
            try databaseURL.resourceValues(forKeys: [.isExcludedFromBackupKey])
                .isExcludedFromBackup, false,
            "the saves database is durable user data — it stays in backups")
    }

    /// The dedup: a second share of a URL already saved inserts nothing and keeps
    /// the row that is there, so nothing is re-attributed or re-notified.
    func testASecondSaveOfTheSameURLInsertsNothing() {
        let store = ReadingListStore(containerURL: container)
        let first = store.addIfAbsent(urlString: "https://example.com/story", source: .shareSheet)

        XCTAssertNil(store.addIfAbsent(urlString: "https://example.com/story", source: .shareSheet))
        XCTAssertEqual(store.items().count, 1)
        XCTAssertEqual(store.items().first?.id, first?.id)
    }

    /// A save writes its own row and nothing else. The row next door keeps every
    /// field, including the ones an extension never writes — its platform, its
    /// read state, its price tracker.
    func testASaveLeavesEveryOtherRowExactlyAsItWas() {
        let store = ReadingListStore(containerURL: container)
        let older = store.add(urlString: "https://example.com/older")
        store.savePlatformMetadata(
            platform: .bluesky, platformItemID: "post-1", title: "Older",
            thumbnailFileName: nil, for: older.id)
        store.markReadState(.opened, for: older.id)
        let before = store.item(withID: older.id)

        store.addIfAbsent(urlString: "https://example.com/newer", source: .shareSheet)

        XCTAssertEqual(store.item(withID: older.id), before)
        // Newest first: the extension's save prepends.
        XCTAssertEqual(
            store.items().map(\.urlString),
            ["https://example.com/newer", "https://example.com/older"])
    }

    /// The document import copies the file into the Articles directory under the
    /// name the reader reads it back from, and titles the save from the file name.
    func testImportedDocumentIsCopiedBesideItsSave() throws {
        let store = ReadingListStore(containerURL: container)
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("Some Notes.TXT")
        try Data("hello".utf8).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }

        let saved = try XCTUnwrap(store.addImportedDocument(sourceURL: source))

        XCTAssertEqual(saved.title, "Some Notes")
        XCTAssertEqual(saved.documentType, "txt")
        XCTAssertEqual(saved.urlString, "lunadoc://\(saved.id.uuidString)")
        XCTAssertEqual(store.originalDocumentURL(for: saved)?.lastPathComponent,
                       "\(saved.id.uuidString)-source.txt")
        XCTAssertEqual(store.items().map(\.id), [saved.id])
    }
}
