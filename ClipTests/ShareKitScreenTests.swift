//
//  ShareKitScreenTests.swift
//  ClipTests
//
//  Snapshot + layout coverage for the share/action extension screens (compiled into
//  the app target via the ShareKit synchronized folder).
//

import UIKit
import XCTest
@testable import Clip

final class ShareKitScreenTests: XCTestCase {

    override func setUp() {
        super.setUp()
        UIView.setAnimationsEnabled(false)
    }

    /// The action-extension article reader's initial (loading) state — it kicks off
    /// an async fetch that never completes in tests (no network), so the loading
    /// screen is the deterministic snapshot. The Done bar item must be present.
    func testShareReaderLoadingSnapshot() {
        guard let url = URL(string: "https://example.com/article") else { return }
        let reader = ShareReaderViewController(url: url, mode: .reader, onDone: {})
        let nav = UINavigationController(rootViewController: reader)
        SnapshotTesting.assertSnapshot(of: nav, named: "sharekit-reader-loading")
    }

    func testShareReaderHasDoneButton() {
        guard let url = URL(string: "https://example.com/article") else { return }
        let reader = ShareReaderViewController(url: url, mode: .reader, onDone: {})
        let window = UITestSupport.host(UINavigationController(rootViewController: reader))
        XCTAssertNotNil(reader.navigationItem.leftBarButtonItem,
                        "share reader should expose a Done item")
        _ = window
    }

    /// The non-textual "Open in Queue" screen for a YouTube video.
    func testSavedNonTextualYouTubeSnapshot() {
        let content = NonTextualContent.youTube(videoID: "dQw4w9WgXcQ")
        let screen = SavedNonTextualViewController(
            articleURLString: "https://youtube.com/watch?v=dQw4w9WgXcQ",
            content: content, onDone: {})
        SnapshotTesting.assertSnapshot(of: UINavigationController(rootViewController: screen),
                                       named: "sharekit-nontextual-youtube")
    }

    /// The non-textual screen for a platform post (X).
    func testSavedNonTextualPlatformSnapshot() {
        let content = NonTextualContent.platform(.x, itemID: "123")
        let screen = SavedNonTextualViewController(
            articleURLString: "https://x.com/user/status/123",
            content: content, onDone: {})
        SnapshotTesting.assertSnapshot(of: UINavigationController(rootViewController: screen),
                                       named: "sharekit-nontextual-platform")
    }

    func testSavedNonTextualLayoutSane() {
        let content = NonTextualContent.youTube(videoID: "dQw4w9WgXcQ")
        let screen = SavedNonTextualViewController(
            articleURLString: "https://youtube.com/watch?v=dQw4w9WgXcQ",
            content: content, onDone: {})
        let window = UITestSupport.host(screen)
        XCTAssertGreaterThan(screen.view.subviews.count, 0)
        for subview in screen.view.subviews where !subview.isHidden && subview.bounds.height > 1 {
            LayoutAssertions.assertVisibleAndInBounds(subview, in: screen.view)
        }
        _ = window
    }
}
