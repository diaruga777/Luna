//
//  IntentMediaExportNamingTests.swift
//  LunaTests
//

@testable import LunaMediaDownload
import XCTest

final class IntentMediaExportNamingTests: XCTestCase {
    func testSavedLocalMediaExportsAsConcreteFriendlyFile() async throws {
        let sourceName = "share-export-\(UUID().uuidString).mp4"
        let sourceURL = SavedMediaStore.shared.mediaDirectory.appendingPathComponent(sourceName)
        let bytes = Data("video bytes".utf8)
        try bytes.write(to: sourceURL)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let item = SavedMediaItem(
            id: UUID(),
            sourceURLString: "https://www.tiktok.com/@luna/video/123",
            title: "A useful clip",
            dateSaved: Date(),
            kind: .video,
            storageState: .localFile(fileName: sourceName),
            thumbnailFileName: nil)

        let result = await MediaAutoDownloader.exportFile(from: item)
        let exported = try XCTUnwrap(result)
        defer { MediaDownloadStorage.discardIntentExport(at: exported.fileURL) }

        XCTAssertEqual(exported.fileURL.lastPathComponent, "A useful clip.mp4")
        XCTAssertEqual(try Data(contentsOf: exported.fileURL), bytes)
    }

    func testDiscardIntentExportRemovesOnlyItsUniqueExportDirectory() throws {
        let export = MediaDownloadStorage.newIntentExportURL(fileName: "share.mp4")
        try Data("bytes".utf8).write(to: export)
        MediaDownloadStorage.discardIntentExport(at: export)
        XCTAssertFalse(FileManager.default.fileExists(atPath: export.path))

        let unrelated = FileManager.default.temporaryDirectory
            .appendingPathComponent("unrelated-\(UUID().uuidString).mp4")
        try Data("keep".utf8).write(to: unrelated)
        defer { try? FileManager.default.removeItem(at: unrelated) }
        MediaDownloadStorage.discardIntentExport(at: unrelated)
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
    }

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
