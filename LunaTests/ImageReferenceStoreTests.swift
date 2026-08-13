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

    /// The content keys recorded as owning `name`, read from the index file the
    /// store writes (`Articles/imageRefs.json`).
    private func owners(of name: String) -> Set<String> {
        let indexURL = articlesDir.appendingPathComponent("imageRefs.json")
        guard let data = try? Data(contentsOf: indexURL),
              let index = try? JSONDecoder().decode([String: Set<String>].self, from: data)
        else { return [] }
        return index[name] ?? []
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

    // MARK: - Through the reading-list store

    /// `saveContent` and `delete` write the reading list under one file coordination
    /// and this index under another, so the refcount legs run outside the list's
    /// coordination. Both writes must still happen, with the same values: a saved
    /// article owns its images while it lives, and releases them when it is deleted.
    func testSavingAndDeletingAnArticleTakesAndReleasesItsImages() {
        let list = ReadingListStore(containerURL: dir)
        makeImage("img-lead.jpg")
        makeImage("img-body.png")
        let item = list.add(urlString: "https://example.com/illustrated", source: .manual)
        let content = ArticleContent(title: "Illustrated", blocks: [
            .init(kind: .image, text: "", links: [], imageFileName: "img-lead.jpg"),
            .init(kind: .paragraph, text: "Prose.", links: []),
            .init(kind: .image, text: "", links: [], imageFileName: "img-body.png"),
        ])

        let saved = list.saveContent(content, for: item)

        XCTAssertEqual(saved.state, .ready)
        XCTAssertEqual(owners(of: "img-lead.jpg"), [ImageReferenceStore.itemKey(item.id)])
        XCTAssertEqual(owners(of: "img-body.png"), [ImageReferenceStore.itemKey(item.id)])

        list.delete(saved)

        XCTAssertTrue(owners(of: "img-lead.jpg").isEmpty)
        XCTAssertFalse(exists("img-lead.jpg"), "the last owner is gone — the file goes with it")
        XCTAssertFalse(exists("img-body.png"))
    }

    /// The other hoisted release: repointing an item onto a URL another item already
    /// holds removes the duplicate row, and its images go with it.
    func testUpdatingOntoADuplicateURLReleasesTheDroppedItemsImages() {
        let list = ReadingListStore(containerURL: dir)
        makeImage("img-dupe.jpg")
        let canonical = list.add(urlString: "https://example.com/story", source: .manual)
        let wrapper = list.add(urlString: "https://news.example.com/wrapper", source: .shareSheet)
        _ = list.saveContent(
            ArticleContent(title: "Wrapper", blocks: [
                .init(kind: .image, text: "", links: [], imageFileName: "img-dupe.jpg"),
            ]),
            for: wrapper)
        XCTAssertEqual(owners(of: "img-dupe.jpg"), [ImageReferenceStore.itemKey(wrapper.id)])

        let result = list.updateURL("https://example.com/story", for: wrapper.id)

        XCTAssertNil(result, "the wrapper is a duplicate of the canonical save")
        XCTAssertNil(list.item(withID: wrapper.id))
        XCTAssertNotNil(list.item(withID: canonical.id))
        XCTAssertTrue(owners(of: "img-dupe.jpg").isEmpty)
        XCTAssertFalse(exists("img-dupe.jpg"))
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
