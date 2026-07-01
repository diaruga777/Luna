//
//  RabbitHoleStackStoreTests.swift
//  LunaTests
//

import LunaModels
import LunaReaderUI
import XCTest
@testable import Luna

final class RabbitHoleStackStoreTests: XCTestCase {

    // MARK: - Layer mode segments (regression: web-URL saves regain Original mode)

    /// A web-URL save must offer all three reading modes — scroll, RSVP, and the
    /// original (live/archived) page. The blank layer shell builds its chrome against a
    /// placeholder empty URL (which excludes `.original`), so `configure(...)` must
    /// rebuild the segment set off the real URL or the Original mode is permanently lost.
    @MainActor
    func testConfigureWithWebURLOffersOriginalSegment() {
        let layer = RabbitHoleLayerViewController(
            shareProvider: nil, gazeTrackerFactory: nil, layout: RabbitHoleLayout())
        // Before configure: chrome built off the blank shell's "" placeholder → no Original.
        XCTAssertEqual(layer.modeSegmentCountForTesting, 2)

        let content = ArticleContent(title: "T", blocks: [
            .init(kind: .paragraph, text: "Body text.", links: []),
        ])
        layer.configure(
            descriptor: RabbitHoleLayerDescriptor(urlString: "https://example.com/article"),
            preloadedContent: content)
        // After configure with a real web URL: scroll + RSVP + original.
        XCTAssertEqual(layer.modeSegmentCountForTesting, 3)
    }

    /// A save with a non-web (synthetic) URL — e.g. an email/document import — has no
    /// live page to load, so the Original segment stays absent even after configure.
    @MainActor
    func testConfigureWithNonWebURLHasNoOriginalSegment() {
        let layer = RabbitHoleLayerViewController(
            shareProvider: nil, gazeTrackerFactory: nil, layout: RabbitHoleLayout())
        let content = ArticleContent(title: "Mail", blocks: [
            .init(kind: .paragraph, text: "Email body.", links: []),
        ])
        layer.configure(
            descriptor: RabbitHoleLayerDescriptor(urlString: "lunamail://message/123"),
            preloadedContent: content)
        XCTAssertEqual(layer.modeSegmentCountForTesting, 2)
    }

    private var tempDir: URL!
    private var store: RabbitHoleStackStore!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rh-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        store = RabbitHoleStackStore(containerURL: tempDir)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testRoundTripPreservesTrail() {
        let id = UUID()
        let stack = RabbitHoleStack(layers: [
            RabbitHoleLayerDescriptor(urlString: "https://example.com/root",
                                      scrollOffset: 120, readerMode: .scroll,
                                      title: "Root", bottomLipText: "the tapped line"),
            RabbitHoleLayerDescriptor(urlString: "https://example.com/deep",
                                      scrollOffset: 0, readerMode: .rsvp, title: "Deep"),
        ])
        store.save(stack, forRootID: id)
        XCTAssertEqual(store.load(forRootID: id), stack)
    }

    func testSingleLayerStackIsNotPersisted() {
        // A trail collapsed back to just the root carries no breadcrumb state — it is
        // cleared so a stale deep trail can't resurface.
        let id = UUID()
        store.save(RabbitHoleStack(layers: [
            RabbitHoleLayerDescriptor(urlString: "https://example.com/root"),
            RabbitHoleLayerDescriptor(urlString: "https://example.com/deep"),
        ]), forRootID: id)
        XCTAssertNotNil(store.load(forRootID: id))

        store.save(RabbitHoleStack(layers: [
            RabbitHoleLayerDescriptor(urlString: "https://example.com/root"),
        ]), forRootID: id)
        XCTAssertNil(store.load(forRootID: id))
    }

    func testTrailsAreKeyedPerRoot() {
        let a = UUID(), b = UUID()
        store.save(RabbitHoleStack(layers: [
            RabbitHoleLayerDescriptor(urlString: "a0"),
            RabbitHoleLayerDescriptor(urlString: "a1"),
        ]), forRootID: a)
        XCTAssertNil(store.load(forRootID: b))
        XCTAssertEqual(store.load(forRootID: a)?.layers.first?.urlString, "a0")
    }

    func testClearRemovesTrail() {
        let id = UUID()
        store.save(RabbitHoleStack(layers: [
            RabbitHoleLayerDescriptor(urlString: "0"),
            RabbitHoleLayerDescriptor(urlString: "1"),
        ]), forRootID: id)
        store.clear(forRootID: id)
        XCTAssertNil(store.load(forRootID: id))
    }
}
