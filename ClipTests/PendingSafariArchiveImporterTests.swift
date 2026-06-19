//
//  PendingSafariArchiveImporterTests.swift
//  ClipTests
//

import XCTest
@testable import Clip

final class PendingSafariArchiveImporterTests: XCTestCase {

    private var scratch: URL!
    private var archives: URL!
    private var store: ReadingListStore!
    private var importer: PendingSafariArchiveImporter!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("clip-archive-import-\(UUID().uuidString)")
        archives = scratch.appendingPathComponent("PendingSafariArchives")
        try FileManager.default.createDirectory(at: archives, withIntermediateDirectories: true)
        store = ReadingListStore(containerURL: scratch)
        importer = PendingSafariArchiveImporter(store: store, directory: archives)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    private func writeHandoff(_ record: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: record)
        try data.write(to: archives.appendingPathComponent("\(UUID().uuidString).json"))
    }

    func testImportsHTMLHandoffAsReadyArticleAndDeletesFile() async throws {
        let body = (1...6).map {
            "<p>Apple plans to raise prices as memory costs surge, paragraph \($0), with enough "
            + "real sentence length to clear the readable-body threshold comfortably here.</p>"
        }.joined()
        let html = "<html><head><title>Apple Prices</title></head><body><article>\(body)</article></body></html>"
        try writeHandoff([
            "url": "https://www.wsj.com/tech/apple-prices-199845b1",
            "title": "Apple Prices",
            "html": html,
        ])

        await importer.importPending()

        let item = try XCTUnwrap(store.item(forURLString: "https://www.wsj.com/tech/apple-prices-199845b1"))
        XCTAssertEqual(item.state, .ready)
        let content = try XCTUnwrap(store.content(for: item))
        XCTAssertTrue(content.wholeText.contains("Apple plans to raise prices"))
        // The hand-off file is consumed.
        let remaining = try FileManager.default.contentsOfDirectory(atPath: archives.path)
        XCTAssertTrue(remaining.isEmpty, "hand-off file should be deleted after import")
    }

    func testImportsPlainTextFallbackAsParagraphs() async throws {
        try writeHandoff([
            "url": "https://www.ft.com/content/abc",
            "title": "FT Story",
            "text": "First paragraph of the story.\nSecond paragraph with more detail.",
        ])

        await importer.importPending()

        let item = try XCTUnwrap(store.item(forURLString: "https://www.ft.com/content/abc"))
        let content = try XCTUnwrap(store.content(for: item))
        XCTAssertEqual(content.title, "FT Story")
        XCTAssertTrue(content.wholeText.contains("First paragraph"))
        XCTAssertTrue(content.wholeText.contains("Second paragraph"))
    }

    func testSkipsAndClearsHandoffWithNoUsableContent() async throws {
        try writeHandoff(["url": "https://www.wsj.com/x"])   // no html, no text

        await importer.importPending()

        XCTAssertNil(store.item(forURLString: "https://www.wsj.com/x"))
        let remaining = try FileManager.default.contentsOfDirectory(atPath: archives.path)
        XCTAssertTrue(remaining.isEmpty, "unusable hand-off should still be cleared")
    }
}
