//
//  RabbitHoleStackStoreTests.swift
//  ClipTests
//

import XCTest
@testable import Clip

final class RabbitHoleStackStoreTests: XCTestCase {

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
