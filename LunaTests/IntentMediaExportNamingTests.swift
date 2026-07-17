//
//  IntentMediaExportNamingTests.swift
//  LunaTests
//

@testable import LunaMediaDownload
import XCTest

final class IntentMediaExportNamingTests: XCTestCase {
    func testVideoUsesSanitizedTitleAndMP4Extension() {
        XCTAssertEqual(
            MediaAutoDownloader.IntentMediaExportNaming.fileName(
                title: "A useful / TikTok: clip?",
                sourceURLString: "https://www.tiktok.com/@luna/video/123",
                kind: .video,
                sourceExtension: "bin"),
            "A useful TikTok clip.mp4")
    }

    func testMissingTitleFallsBackToPlatformBaseName() {
        XCTAssertEqual(
            MediaAutoDownloader.IntentMediaExportNaming.fileName(
                title: nil,
                sourceURLString: "https://www.tiktok.com/@luna/video/123",
                kind: .video),
            "tiktok.mp4")
    }

    func testBlankTitleFallsBackToHostForUnknownURL() {
        XCTAssertEqual(
            MediaAutoDownloader.IntentMediaExportNaming.fileName(
                title: " / : ? ",
                sourceURLString: "https://media.example.com/file",
                kind: .image,
                sourceExtension: "PNG"),
            "example.png")
    }
}
