//
//  ActionButtonGuideAssetTests.swift
//  LunaTests
//

import Foundation
import UIKit
import XCTest
@testable import Luna

final class ActionButtonGuideAssetTests: XCTestCase {

    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private func source(_ relativePath: String) -> String {
        (try? String(
            contentsOf: Self.repoRoot.appendingPathComponent(relativePath),
            encoding: .utf8)) ?? ""
    }

    func testEveryLunaSurfaceHasLightAndDarkActionButtonGuide() {
        let resources = Self.repoRoot.appendingPathComponent("Luna/Resources")
        let stems = [
            "ActionButtonGuideLuna",
            "ActionButtonGuideReader",
            "ActionButtonGuideDownloader",
            "ActionButtonGuidePriceTracker",
        ]
        for stem in stems {
            for appearance in ["Dark", "Light"] {
                let url = resources.appendingPathComponent("\(stem)\(appearance).mp4")
                XCTAssertTrue(
                    FileManager.default.fileExists(atPath: url.path),
                    "Missing \(url.lastPathComponent) for the matching app surface")
                XCTAssertGreaterThan(
                    (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0,
                    100_000,
                    "\(url.lastPathComponent) should contain a rendered guide, not an empty placeholder")
            }
        }
    }

    func testGuideGeneratorUsesOnlyCurrentShortcutNames() {
        let generator = source("scripts/generate_action_button_guides.swift")
        XCTAssertFalse(generator.contains("Send To Luna"))
        for name in ["Luna", "Luna Reader", "Luna Video", "Luna Price Tracker"] {
            XCTAssertTrue(generator.contains("name: \"\(name)\""))
        }
    }

    func testGuideGeneratorUsesTheSettingsMatchedGlyphs() {
        let generator = source("scripts/generate_action_button_guides.swift")
        XCTAssertTrue(generator.contains("case \"Personal Hotspot\": return \"personalhotspot\""))
        XCTAssertTrue(generator.contains("case \"Camera\": return \"camera.fill\""))
        XCTAssertTrue(generator.contains("drawActionButtonSettingsGlyph"))
        XCTAssertTrue(generator.contains("drawVPNSettingsGlyph"))
        XCTAssertFalse(generator.contains("case \"Action Button\": return \"arrow.right.to.line\""))
    }

    @MainActor
    func testActionButtonGuideStopsOnForegroundAndOnActivation() async {
        let actionGuide = SetupGuideVideo()
        actionGuide.requestPictureInPictureForTesting()

        NotificationCenter.default.post(
            name: UIApplication.willEnterForegroundNotification,
            object: nil)
        await Task.yield()
        XCTAssertFalse(actionGuide.pictureInPictureRequestedForTesting)

        actionGuide.requestPictureInPictureForTesting()
        NotificationCenter.default.post(
            name: UIApplication.didBecomeActiveNotification,
            object: nil)
        await Task.yield()
        XCTAssertFalse(actionGuide.pictureInPictureRequestedForTesting)
    }
}
