//
//  ExtensionReaderPreparationTests.swift
//  LunaTests
//
//  The extension surfaces hand over a FINISHED reader: no intermediate loading
//  screen between the host's spinner and the article, and no images arriving
//  after the text has already been laid out.
//

import LunaModels
import LunaReaderUI
import LunaStorage
import UIKit
import XCTest

@MainActor
final class ExtensionReaderPreparationTests: XCTestCase {

    private var scratch: URL!
    private var store: ReadingListStore!

    override func setUp() {
        super.setUp()
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReaderPrep-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        store = ReadingListStore(containerURL: scratch)
    }

    override func tearDown() {
        ShareReaderViewController.settleImagesOverride = nil
        try? FileManager.default.removeItem(at: scratch)
        super.tearDown()
    }

    private func imageBlock(
        url: String, width: Int? = nil, height: Int? = nil
    ) -> ArticleContent.Block {
        ArticleContent.Block(
            kind: .image, text: "", links: [], imageURLString: url,
            imageWidth: width, imageHeight: height)
    }

    private func content(_ blocks: [ArticleContent.Block]) -> ArticleContent {
        ArticleContent(title: "T", blocks: blocks)
    }

    /// An image the page declared no size for has no placeholder to land in, so
    /// the surface must settle it BEFORE showing the article — otherwise it drops
    /// in later and shoves everything below it down.
    func testSettlingBlocksOnImagesWithNoDeclaredSize() async {
        let article = content([
            .init(kind: .paragraph, text: "body", links: []),
            imageBlock(url: "https://example.com/unsized.jpg"),
        ])
        let item = store.add(urlString: "https://example.com/story")

        var settled = false
        ShareReaderViewController.settleImagesOverride = { content, _, _, _ in
            settled = true
            return content
        }
        _ = await ShareReaderViewController.settledImageLayout(
            for: article, item: item, url: URL(string: "https://example.com/story")!, store: store)
        XCTAssertTrue(settled, "an unknown-size image must be settled before display")
    }

    /// Images WITH declared dimensions already have correctly-sized placeholders,
    /// so nothing moves when they arrive — the surface must not hold the spinner
    /// for them.
    func testSettlingSkipsImagesThatAlreadyHaveDeclaredSizes() async {
        let article = content([
            .init(kind: .paragraph, text: "body", links: []),
            imageBlock(url: "https://example.com/sized.jpg", width: 800, height: 600),
        ])
        let item = store.add(urlString: "https://example.com/story")

        var settled = false
        ShareReaderViewController.settleImagesOverride = { content, _, _, _ in
            settled = true
            return content
        }
        _ = await ShareReaderViewController.settledImageLayout(
            for: article, item: item, url: URL(string: "https://example.com/story")!, store: store)
        XCTAssertFalse(settled, "a sized image loads in behind its placeholder instead")
    }

    /// A text-only article never waits on the image step at all.
    func testSettlingIsANoOpWithoutImages() async {
        let article = content([.init(kind: .paragraph, text: "body", links: [])])
        let item = store.add(urlString: "https://example.com/story")

        ShareReaderViewController.settleImagesOverride = { _, _, _, _ in
            XCTFail("a text-only article must not reach the image step")
            return self.content([])
        }
        let result = await ShareReaderViewController.settledImageLayout(
            for: article, item: item, url: URL(string: "https://example.com/story")!, store: store)
        XCTAssertEqual(result.blocks.count, 1)
    }

    /// A stalled image host must not strand the sheet on a spinner: the settling
    /// is bounded, and whatever resolved locally is still returned.
    func testSettlingIsBoundedWhenTheImageHostStalls() async {
        let article = content([imageBlock(url: "https://example.com/unsized.jpg")])
        let item = store.add(urlString: "https://example.com/story")

        ShareReaderViewController.settleImagesOverride = { content, _, _, _ in
            // Longer than the timeout; cancellation lands on the sleep.
            try? await Task.sleep(nanoseconds: 30 * 1_000_000_000)
            return content
        }
        let started = Date()
        let result = await ShareReaderViewController.settledImageLayout(
            for: article, item: item, url: URL(string: "https://example.com/story")!, store: store)
        XCTAssertLessThan(
            Date().timeIntervalSince(started),
            ShareReaderViewController.imagePreparationTimeout + 5,
            "the wait must be bounded")
        XCTAssertEqual(result.blocks.count, 1)
    }

    /// The prepared hand-off IS the reader — the surface goes straight from its
    /// own spinner to the article, with the reader's Done already in place.
    func testPreparedReaderIsTheFinishedReaderWithDone() async {
        ShareReaderViewController.settleImagesOverride = { content, _, _, _ in content }
        let reader = await ShareReaderViewController.preparedReader(
            url: URL(string: "https://example.com/story")!, mode: .reader,
            content: content([.init(kind: .paragraph, text: "body", links: [])]),
            store: store, onModeChange: nil, onDone: {})
        XCTAssertTrue(reader is ReaderViewController)
        XCTAssertFalse(reader is ShareReaderViewController, "no intermediate loading screen")
        XCTAssertNotNil(reader.navigationItem.leftBarButtonItem)
    }
}
