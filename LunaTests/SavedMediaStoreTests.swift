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

        let reloaded = try XCTUnwrap(SavedMediaStore(containerURL: root).item(id: id))
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

        let item = try XCTUnwrap(store.item(id: id))
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

        let repaired = try XCTUnwrap(store.item(id: local.id))
        XCTAssertEqual(repaired.storageState, .undownloaded)
        XCTAssertNil(repaired.thumbnailFileName)
    }
}
