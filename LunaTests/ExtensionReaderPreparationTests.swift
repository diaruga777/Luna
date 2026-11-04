//
//  ExtensionReaderPreparationTests.swift
//  LunaTests
//
//  The extension surfaces hand over a FINISHED reader: no intermediate loading
//  screen between the host's spinner and the article, and no images arriving
//  after the text has already been laid out.
//

import LunaModels
import LunaStorage
import UIKit
import XCTest
@testable import LunaReaderUI

/// Stands in for the extension host's exit leg. Nothing here can press Done — a
/// `UIBarButtonItem`'s `UIAction` is not reachable from a test — so this exists to be
/// the real conformer the prepared reader is built against.
private final class StubShareReaderHost: ShareReaderCompletionDelegate {
    func shareReaderDidFinish() {}
}

@MainActor
final class ExtensionReaderPreparationTests: XCTestCase {

    private var scratch: URL!
    private var store: SavesStore!

    override func setUp() {
        super.setUp()
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReaderPrep-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        store = SavesStore(containerURL: scratch)
    }

    override func tearDown() {
        ShareReaderViewController.settleImagesOverride = nil
        ShareReaderViewController.imagePreparationTimeout = 8
        try? FileManager.default.removeItem(at: scratch)
        super.tearDown()
    }

    private func imageBlock(
        url: String, width: Int? = nil, height: Int? = nil
    ) -> ArticleContent.Block {
        let size: ArticleContent.BlockImageSize?
        if let width, let height {
            size = ArticleContent.BlockImageSize(width: width, height: height)
        } else {
            size = nil
        }
        return ArticleContent.Block(
            kind: .image, text: "", links: [], imageURLString: url,
            imageSize: size)
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

    /// Declared dimensions reserve space; visible pixels must also be ready.
    func testSettlingIncludesVisibleImagesThatAlreadyHaveDeclaredSizes() async {
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
        XCTAssertTrue(settled, "an on-screen image must be prepared before revealing the reader")
    }

    func testSettlingDefersKnownSizeImagesFarBelowTheInitialViewport() async {
        let article = content([
            .init(kind: .paragraph, text: String(repeating: "word ", count: 800), links: []),
            imageBlock(url: "https://example.com/offscreen.jpg", width: 800, height: 600),
        ])
        let item = store.add(urlString: "https://example.com/story")
        ShareReaderViewController.settleImagesOverride = { content, _, _, _ in
            XCTFail("offscreen known-size images should remain deferred")
            return content
        }
        _ = await ShareReaderViewController.settledImageLayout(
            for: article, item: item, url: URL(string: item.urlString)!, store: store)
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

        // The bound is what's under test, not its production value: shrink it and
        // the same race runs in a twentieth of a second. tearDown puts 8 back.
        ShareReaderViewController.imagePreparationTimeout = 0.05
        ShareReaderViewController.settleImagesOverride = { content, _, _, _ in
            // Far longer than the timeout; cancellation lands on the sleep.
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

    func testTimeoutKeepsVisibleImagesCompletedBeforeOffscreenWorkWasCancelled() async throws {
        let article = content([imageBlock(url: "https://example.com/visible.jpg", width: 800, height: 600)])
        let item = store.add(urlString: "https://example.com/story")
        ShareReaderViewController.imagePreparationTimeout = 0.01
        let name = "completed-visible.png"
        let image = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { context in
            UIColor.blue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        try XCTUnwrap(image.pngData()).write(to: store.articlesDirectory.appendingPathComponent(name))
        ShareReaderViewController.settleImagesOverride = { content, _, _, _ in
            var completed = content
            completed.blocks[0].imageFileName = name
            try? await Task.sleep(nanoseconds: 30 * 1_000_000_000)
            return completed
        }
        let settled = await ShareReaderViewController.settledImageLayout(
            for: article, item: item, url: URL(string: item.urlString)!, store: store)
        XCTAssertEqual(settled.blocks[0].imageFileName, name)
    }

    /// The prepared hand-off IS the reader — the surface goes straight from its
    /// own spinner to the article, with the reader's Done already in place.
    func testPreparedReaderIsTheFinishedReaderWithDone() async {
        ShareReaderViewController.settleImagesOverride = { content, _, _, _ in content }
        let host = StubShareReaderHost()
        let reader = await ShareReaderViewController.preparedReader(
            url: URL(string: "https://example.com/story")!, mode: .reader,
            content: content([.init(kind: .paragraph, text: "body", links: [])]),
            store: store, modePreferenceDelegate: nil, completionDelegate: host)
        XCTAssertTrue(reader is ReaderViewController)
        XCTAssertFalse(reader is ShareReaderViewController, "no intermediate loading screen")
        XCTAssertNotNil(reader.navigationItem.leftBarButtonItem)
    }
}
