import XCTest
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
