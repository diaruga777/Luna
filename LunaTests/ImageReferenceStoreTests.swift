//
//  ImageReferenceStoreTests.swift
//  LunaTests
//

import LunaModels
import LunaStorage
import XCTest
@testable import Luna

final class ImageReferenceStoreTests: XCTestCase {
    private var dir: URL!
    private var articlesDir: URL!
    private var store: ImageReferenceStore!

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImageRefTests-\(UUID().uuidString)", isDirectory: true)
        articlesDir = dir.appendingPathComponent("Articles", isDirectory: true)
        try? FileManager.default.createDirectory(at: articlesDir, withIntermediateDirectories: true)
        store = ImageReferenceStore(containerURL: dir)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    private func makeImage(_ name: String) {
        try? Data("x".utf8).write(to: articlesDir.appendingPathComponent(name))
    }

    private func exists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: articlesDir.appendingPathComponent(name).path)
    }

    func testSharedImageKeptUntilLastOwnerReleased() {
        makeImage("img-abc.jpg")
        store.setReferences(contentKey: "item:A", files: ["img-abc.jpg"])
        store.setReferences(contentKey: "preloadB", files: ["img-abc.jpg"])

        // One owner gone → shared image survives.
        store.removeReferences(contentKey: "item:A")
        XCTAssertTrue(exists("img-abc.jpg"))

        // Last owner gone → deleted.
        store.removeReferences(contentKey: "preloadB")
        XCTAssertFalse(exists("img-abc.jpg"))
    }

    func testSetReferencesDropsNoLongerReferencedImage() {
        makeImage("img-1.jpg")
        makeImage("img-2.jpg")
        store.setReferences(contentKey: "item:A", files: ["img-1.jpg", "img-2.jpg"])
        // Re-declare A's images without img-2 → img-2 loses its only owner and is deleted.
        store.setReferences(contentKey: "item:A", files: ["img-1.jpg"])
        XCTAssertTrue(exists("img-1.jpg"))
        XCTAssertFalse(exists("img-2.jpg"))
    }

    func testOnlyDeletesImgPrefixedFiles() {
        // A non-`img-` file is tracked but must never be deleted (guards content JSON,
        // thumbnails, anything that isn't a shared image).
        makeImage("readingList.json")
        store.setReferences(contentKey: "item:A", files: ["readingList.json"])
        store.removeReferences(contentKey: "item:A")
        XCTAssertTrue(exists("readingList.json"))
    }

    func testImageFilesHelperPullsFromImageBlocks() {
        let content = ArticleContent(title: "T", blocks: [
            .init(kind: .image, text: "", links: [], imageFileName: "img-a.jpg"),
            .init(kind: .paragraph, text: "x", links: []),
            .init(kind: .image, text: "", links: [], imageFileName: "img-b.png"),
        ])
        XCTAssertEqual(ImageReferenceStore.imageFiles(in: content), ["img-a.jpg", "img-b.png"])
    }
}
