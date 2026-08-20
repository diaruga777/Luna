//
//  SavedNonTextualYouTubeTests.swift
//  LunaTests
//

import LunaModels
import UIKit
import XCTest
@testable import LunaMediaDownload
@testable import LunaShareSurface

/// Pins the long-form YouTube fallback shared by the action and share
/// extensions: no redundant label, poster-to-inline playback, and a reliable
/// outbound fallback that exits.
@MainActor
final class SavedNonTextualYouTubeTests: XCTestCase {

    private final class Host: ExtensionHost {
        var readerMode: ExtensionReaderMode?
        var opened: [URL] = []
        var completionCount = 0

        func presentModally(_ viewController: UIViewController) {}
        func confirmSavedThenComplete() {}
        func completeSilently() { completionCount += 1 }
        func autoDownloadThenComplete(urlString: String) {}
        func failOrComplete(_ message: String) {}
        func openURL(_ url: URL) { opened.append(url) }
    }

    func testPosterShowsInlinePlayerAndFailureOrButtonOpenThenComplete() throws {
        let source = try XCTUnwrap(URL(string: "https://youtu.be/dQw4w9WgXcQ"))
        let host = Host()
        let controller = SavedNonTextualViewController(
            articleURLString: source.absoluteString, delegate: host)
        controller.view.frame = CGRect(x: 0, y: 0, width: 393, height: 760)
        controller.view.layoutIfNeeded()

        let openTitle = L10n.string("Downloader_media_preview_openInYouTubeButtonTitle")
        let openButton = try XCTUnwrap(
            Self.views(in: controller.view)
                .compactMap { $0 as? UIButton }
                .first { $0.configuration?.title == openTitle })
        let visibleLabels = Self.views(in: controller.view)
            .compactMap { $0 as? UILabel }
            .filter { !$0.isHidden }
            .compactMap(\.text)
        XCTAssertFalse(
            visibleLabels.contains { $0.localizedCaseInsensitiveContains("YouTube video") },
            "the poster and button do not need a second content-kind label")

        controller.previewTapped()

        let player = try XCTUnwrap(
            Self.views(in: controller.view)
                .compactMap { $0 as? YouTubeEmbeddedPlayerView }
                .first)
        XCTAssertTrue(host.opened.isEmpty, "poster tap stays inline when the player can load")
        XCTAssertEqual(host.completionCount, 0)

        controller.youTubeEmbeddedPlayer(player, didFailWithCode: 101)
        openButton.sendActions(for: .touchUpInside)

        XCTAssertEqual(host.opened, [source, source])
        XCTAssertEqual(
            host.completionCount, 2,
            "player failure and explicit launch both close even when URL opening is denied")
    }

    private static func views(in root: UIView) -> [UIView] {
        [root] + root.subviews.flatMap { views(in: $0) }
    }
}
