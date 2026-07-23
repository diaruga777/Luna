//
//  ShareSurfaceDriverRescueTests.swift
//  LunaTests
//

import LunaShareSurface
import LunaStorage
import LunaIngest
import LunaModels
import UIKit
import XCTest
@testable import Luna

/// The `.failed` rescue-handoff behavior of `ShareSurfaceDriver`: the action
/// extension presents the rescue card (and marks the row failed); the zero-UI
/// share extension completes silently (and marks it failed) with no card.
@MainActor
final class ShareSurfaceDriverRescueTests: XCTestCase {

    private final class FakeHost: ExtensionHost {
        var readerMode: ShareReaderViewController.Mode?
        private(set) var presented: [UIViewController] = []
        private(set) var completedSilently = 0
        private(set) var openedURLs: [URL] = []
        init(isActionExtension: Bool) { readerMode = isActionExtension ? .reader : nil }
        func presentModally(_ vc: UIViewController) { presented.append(vc) }
        func confirmSavedThenComplete() {}
        func completeSilently() { completedSilently += 1 }
        func autoDownloadThenComplete(urlString: String) {}
        func failOrComplete(_ message: String) {}
        func openURL(_ url: URL) { openedURLs.append(url) }
    }

    private var scratch: URL!
    private var store: ReadingListStore!

    override func setUp() {
        super.setUp()
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShareRescue-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        store = ReadingListStore(containerURL: scratch)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: scratch)
        super.tearDown()
    }

    func testActionExtensionFailedPresentsRescueCardAndMarksFailed() {
        let host = FakeHost(isActionExtension: true)
        let driver = ShareSurfaceDriver(host: host, store: store, surfaceDecision: { _ in .supported })
        let url = URL(string: "https://example.com/broken")!
        let item = store.add(urlString: url.absoluteString)

        driver.present(.failed, url: url)

        XCTAssertTrue(host.presented.contains { $0 is RescueFailureViewController },
                      "action extension should present the rescue card")
        XCTAssertEqual(store.item(withID: item.id)?.state, .failed)
    }

    func testShareExtensionFailedCompletesSilentlyNoCard() {
        let host = FakeHost(isActionExtension: false)
        let driver = ShareSurfaceDriver(host: host, store: store, surfaceDecision: { _ in .supported })
        let url = URL(string: "https://example.com/broken")!
        let item = store.add(urlString: url.absoluteString)

        driver.present(.failed, url: url)

        XCTAssertFalse(host.presented.contains { $0 is RescueFailureViewController })
        XCTAssertEqual(host.completedSilently, 1)
        XCTAssertEqual(store.item(withID: item.id)?.state, .failed)
    }

    func testDefaultHintMapping() {
        XCTAssertEqual(ShareSurfaceDriver.defaultHint(for: .reader), .article)
        XCTAssertEqual(ShareSurfaceDriver.defaultHint(for: .downloader), .media)
        XCTAssertEqual(ShareSurfaceDriver.defaultHint(for: .priceTracker), .product)
    }
}
