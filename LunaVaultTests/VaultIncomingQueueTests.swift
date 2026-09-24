import XCTest
import UniformTypeIdentifiers
@testable import LunaVault

final class VaultIncomingQueueTests: XCTestCase {
    func testPublishedFilesSurviveReopenInFIFOOrder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("VaultQueueTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let queue = try VaultIncomingQueue(rootURL: root.appendingPathComponent("Incoming"))
        let source = root.appendingPathComponent("photo.jpg")
        try Data("photo bytes".utf8).write(to: source)

        let first = try queue.enqueueFile(at: source, relativeName: "Photos/Trip/photo.jpg")
        let second = try queue.enqueueDirectory(relativeName: "Photos/Empty Album")
        _ = try queue.prepare(first, destinationName: "Photos/Trip/photo (2).jpg")

        let reopened = try VaultIncomingQueue(rootURL: queue.rootURL)
        let items = try reopened.items()
        XCTAssertEqual(items.map(\.id), [first.id, second.id])
        XCTAssertEqual(items.first?.destinationName, "Photos/Trip/photo (2).jpg")
        XCTAssertEqual(try Data(contentsOf: reopened.payloadURL(for: first)), Data("photo bytes".utf8))
        XCTAssertTrue(try reopened.payloadURL(for: second).resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true)
        try reopened.remove(first)
        XCTAssertEqual(try reopened.items().map(\.id), [second.id])
    }
}

@MainActor
final class VaultPhotoFormatTests: XCTestCase {
    func testDefaultJPEGAndMP4ConversionAndOriginalChoice() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("VaultPhotoFormat-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let sourceImage = repository.appendingPathComponent("Luna/LunaLaunchStarfield.png")
        let png = root.appendingPathComponent("image.png")
        try FileManager.default.copyItem(at: sourceImage, to: png)
        let coordinator = VaultPhotoSelectionCoordinator()
        let (jpeg, jpegName) = try await coordinator.convertIfNeeded(png, named: "image.png", mediaType: .png, in: root)
        XCTAssertEqual(jpegName, "image.jpg")
        XCTAssertEqual(Array(try Data(contentsOf: jpeg).prefix(3)), [0xff, 0xd8, 0xff])

        coordinator.imageFormat = .original
        let originalPNG = root.appendingPathComponent("original.png")
        try FileManager.default.copyItem(at: sourceImage, to: originalPNG)
        let (unchanged, originalName) = try await coordinator.convertIfNeeded(originalPNG,
            named: "original.png", mediaType: .png, in: root)
        XCTAssertEqual(unchanged, originalPNG)
        XCTAssertEqual(originalName, "original.png")

        let sourceVideo = repository.appendingPathComponent("Luna/Resources/ActionButtonGuideReaderLight.mp4")
        let mov = root.appendingPathComponent("video.mov")
        try FileManager.default.copyItem(at: sourceVideo, to: mov)
        let (mp4, mp4Name) = try await coordinator.convertIfNeeded(mov, named: "video.mov", mediaType: .movie, in: root)
        XCTAssertEqual(mp4Name, "video.mp4")
        XCTAssertEqual(try Data(contentsOf: mp4).subdata(in: 4..<8), Data("ftyp".utf8))

        coordinator.videoFormat = .original
        let originalMOV = root.appendingPathComponent("original.mov")
        try FileManager.default.copyItem(at: sourceVideo, to: originalMOV)
        let (originalVideo, originalVideoName) = try await coordinator.convertIfNeeded(originalMOV,
            named: "original.mov", mediaType: .movie, in: root)
        XCTAssertEqual(originalVideo, originalMOV)
        XCTAssertEqual(originalVideoName, "original.mov")
    }
}
