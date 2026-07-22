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
            shareProvider: nil, layout: RabbitHoleLayout())
        // Before configure: chrome built off the blank shell's "" placeholder → no Original.
        XCTAssertEqual(layer.modeSegmentCountForTesting, 2)

        let content = ArticleContent(title: "T", blocks: [
            .init(kind: .paragraph, text: "Body text.", links: []),
        ])
        layer.configure(
            descriptor: RabbitHoleLayerDescriptor(urlString: "https://example.com/article"),
            knownContent: content)
        // After configure with a real web URL: scroll + RSVP + original.
        XCTAssertEqual(layer.modeSegmentCountForTesting, 3)
    }

    /// A save with a non-web (synthetic) URL — e.g. an email/document import — has no
    /// live page to load, so the Original segment stays absent even after configure.
    @MainActor
    func testConfigureWithNonWebURLHasNoOriginalSegment() {
        let layer = RabbitHoleLayerViewController(
            shareProvider: nil, layout: RabbitHoleLayout())
        let content = ArticleContent(title: "Mail", blocks: [
            .init(kind: .paragraph, text: "Email body.", links: []),
        ])
        layer.configure(
            descriptor: RabbitHoleLayerDescriptor(urlString: "lunamail://message/123"),
            knownContent: content)
        XCTAssertEqual(layer.modeSegmentCountForTesting, 2)
    }

    /// Restoring a saved layer whose persisted mode is Original must mount and
    /// load that reader on the first presentation. Comparing only the restored
    /// `readerMode` used to make the initial embed look redundant, producing a
    /// blank card until switching away and back.
    @MainActor
    func testRestoredOriginalModeMountsArchiveReaderInitially() {
        let layer = RabbitHoleLayerViewController(
            shareProvider: nil, layout: RabbitHoleLayout())
        let content = ArticleContent(title: "Archive", blocks: [
            .init(kind: .paragraph, text: "Saved page.", links: []),
        ])
        layer.configure(
            descriptor: RabbitHoleLayerDescriptor(
                urlString: "https://example.com/archive", readerMode: .original),
            knownContent: content)
        layer.loadViewIfNeeded()

        XCTAssertTrue(layer.hasMountedOriginalReaderForTesting)
    }

    /// A carousel preview uses the real reader controller, but ordinary child
    /// activation must not turn its viewport-sized prefix into a whole-article
    /// render. Promotion permanently lifts that gate and runs Phase 2.
    @MainActor
    func testPrimaryGateDefersFullScrollRenderUntilPromotion() throws {
        let content = ArticleContent(title: "Long", blocks: (0..<4).map { index in
            .init(
                kind: .paragraph,
                text: "Paragraph \(index) " + String(repeating: "viewport word ", count: 180),
                links: [])
        })
        let layer = RabbitHoleLayerViewController(
            shareProvider: nil, layout: RabbitHoleLayout())
        layer.defersFullContentUntilPrimary = true
        layer.view.frame = CGRect(x: 0, y: 0, width: 390, height: 650)
        layer.configure(
            descriptor: RabbitHoleLayerDescriptor(urlString: "https://example.com/long"),
            knownContent: content)
        layer.loadViewIfNeeded()
        layer.view.layoutIfNeeded()

        let scroll = try XCTUnwrap(
            layer.children.compactMap { $0 as? ScrollReaderViewController }.first)
        let prefixLength = scroll.renderedTextLengthForTesting
        scroll.beginAppearanceTransition(true, animated: false)
        scroll.endAppearanceTransition()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))

        XCTAssertFalse(scroll.didLoadFullContentForTesting)
        XCTAssertEqual(scroll.renderedTextLengthForTesting, prefixLength)
        XCTAssertLessThan(prefixLength, ArticleTextRenderer.render(content).text.length)

        layer.activatePrimaryContent()
        let deadline = Date().addingTimeInterval(5)
        while !scroll.didLoadFullContentForTesting, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }

        XCTAssertTrue(scroll.didLoadFullContentForTesting)
        XCTAssertGreaterThan(scroll.renderedTextLengthForTesting, prefixLength)
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
