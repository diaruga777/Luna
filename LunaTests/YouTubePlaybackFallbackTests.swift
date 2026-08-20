//
//  YouTubePlaybackFallbackTests.swift
//  LunaTests
//

import LunaModels
import UIKit
import WebKit
import XCTest
@testable import Luna
@testable import LunaMediaDownload

/// Regression coverage for the identified long-form YouTube player. The old
/// bare embed produced error 153 and filled the entire card with web gestures.
@MainActor
final class YouTubeEmbeddedPlaybackTests: XCTestCase {

    func testCardUsesIdentifiedInlinePlayerAndLeavesBlankLongPressForCardMenu() throws {
        let source = try XCTUnwrap(URL(string: "https://youtu.be/dQw4w9WgXcQ"))
        var opened: [URL] = []
        let controller = YouTubePlaybackCardContentViewController(
            sourceURL: source, openSourceURL: { opened.append($0) })
        controller.view.frame = CGRect(x: 0, y: 0, width: 320, height: 568)
        controller.view.layoutIfNeeded()

        let player = try XCTUnwrap(
            Self.views(in: controller.view).compactMap { $0 as? YouTubeEmbeddedPlayerView }.first)
        XCTAssertNotNil(player.webView, "the app card should offer inline playback")
        XCTAssertFalse(
            controller.longPressSelectsContent(at: CGPoint(x: 20, y: 20)),
            "blank card space belongs to the carousel context menu")
        let playerCenter = player.convert(
            CGPoint(x: player.bounds.midX, y: player.bounds.midY), to: controller.view)
        XCTAssertTrue(
            controller.longPressSelectsContent(at: playerCenter),
            "only the 16:9 player rectangle keeps its HTML interaction")
        XCTAssertFalse(controller.allowsCardTap(at: CGPoint(x: 20, y: 20)))

        let poster = try XCTUnwrap(Self.button(
            identified: "YouTubeCard.posterButton", in: controller.view))
        let explicit = try XCTUnwrap(Self.button(
            identified: "YouTubeCard.openButton", in: controller.view))
        XCTAssertEqual(
            explicit.configuration?.title,
            L10n.string("Downloader_media_preview_openInYouTubeButtonTitle"))

        poster.sendActions(for: .touchUpInside)
        explicit.sendActions(for: .touchUpInside)
        XCTAssertEqual(opened, [source, source])
    }

    func testPlayerDocumentUsesBundleIdentifierAsYouTubeClientIdentity() throws {
        let source = try XCTUnwrap(
            URL(string: "https://www.youtube.com/watch?v=M7lc1UVf-VE&t=42"))
        let document = try XCTUnwrap(YouTubeEmbeddedPlayerDocument(
            sourceURL: source, bundleIdentifier: "com.hsanabria.luna.downloader"))

        XCTAssertEqual(
            document.baseURL.absoluteString, "https://com.hsanabria.luna.downloader")
        XCTAssertTrue(document.html.contains("videoId: 'M7lc1UVf-VE'"))
        XCTAssertTrue(document.html.contains("start: 42"))
        XCTAssertTrue(document.html.contains(
            "origin: 'https://com.hsanabria.luna.downloader'"))
        XCTAssertTrue(document.html.contains("strict-origin-when-cross-origin"))
    }

    private static func button(identified identifier: String, in root: UIView) -> UIButton? {
        views(in: root)
            .compactMap { $0 as? UIButton }
            .first { $0.accessibilityIdentifier == identifier }
    }

    private static func views(in root: UIView) -> [UIView] {
        [root] + root.subviews.flatMap { views(in: $0) }
    }
}
