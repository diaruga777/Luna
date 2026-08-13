//
//  SharedReadingListAppenderTests.swift
//  LunaTests
//
//  The extension-side append into the shared `readingList.json`. It writes raw
//  dictionaries rather than decoding the list, so the one thing it must never do
//  is treat an unreadable file as an empty one — that rewrites the whole reading
//  list as a single new row.
//
//  Runs against a throwaway App Group container (`StageContainer`), which is also
//  a live check that the redirect works: without it these tests would rewrite the
//  simulator's real reading list.
//

import LunaAppConfig
import LunaStorage
import XCTest

final class SharedReadingListAppenderTests: XCTestCase {

    private var container: URL!

    override func setUp() {
        super.setUp()
        container = StageContainer.activate(identifier: "shared-appender-tests")
    }

    override func tearDown() {
        StageContainer.deactivateForTesting()
        super.tearDown()
    }

    private var listURL: URL { container.appendingPathComponent("readingList.json") }

    private func rows() -> [[String: Any]] {
        guard let data = try? Data(contentsOf: listURL),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }
        return array
    }

    /// The data-loss case: the file holds bytes that will not parse. Appending
    /// used to write `[newItem]` over them — every saved item gone. Now the
    /// append is refused and the file is left byte-for-byte as it was.
    func testAppendRefusesWhenTheExistingListCannotBeDecoded() throws {
        let corrupt = Data("[{\"id\":\"truncated\",".utf8)
        try corrupt.write(to: listURL)

        SharedReadingListAppender.append(urlString: "https://example.com/story")

        XCTAssertEqual(try Data(contentsOf: listURL), corrupt,
                       "an unreadable list must be left exactly as it was found")
    }

    /// Valid JSON that is not a list of items is unreadable in the same sense —
    /// there is no list to append to, so nothing may be overwritten.
    func testAppendRefusesWhenTheFileHoldsSomethingOtherThanAList() throws {
        let notAList = Data("{\"items\":[]}".utf8)
        try notAList.write(to: listURL)

        SharedReadingListAppender.append(urlString: "https://example.com/story")

        XCTAssertEqual(try Data(contentsOf: listURL), notAList)
    }

    /// The refusal must be narrow: a readable list still gains its new row at the
    /// front, keeps every existing row verbatim, and stays eligible for backup
    /// (the store's own writes apply the same policy).
    func testAppendPrependsToAReadableListAndKeepsItInBackups() throws {
        let existing: [[String: Any]] = [[
            "id": UUID().uuidString,
            "urlString": "https://example.com/older",
            "dateAdded": 1.0,
            "state": "ready",
            "readState": "unopened",
            // A field the extension's writer knows nothing about — it must survive.
            "platform": "bluesky",
        ]]
        try JSONSerialization.data(withJSONObject: existing).write(to: listURL)
        var fileURL = listURL
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try fileURL.setResourceValues(values)

        SharedReadingListAppender.append(urlString: "https://example.com/newer")

        let written = rows()
        XCTAssertEqual(written.count, 2)
        XCTAssertEqual(written.first?["urlString"] as? String, "https://example.com/newer")
        XCTAssertEqual(written.last?["urlString"] as? String, "https://example.com/older")
        XCTAssertEqual(written.last?["platform"] as? String, "bluesky",
                       "an existing row's unknown fields must be preserved verbatim")
        XCTAssertEqual(
            try listURL.resourceValues(forKeys: [.isExcludedFromBackupKey])
                .isExcludedFromBackup, false,
            "the reading list is durable user data — the append keeps it in backups")
    }

    /// No file yet is not the same as an unreadable one: the first save creates it.
    func testAppendCreatesTheListWhenThereIsNoneYet() {
        SharedReadingListAppender.append(urlString: "https://example.com/first")

        let written = rows()
        XCTAssertEqual(written.count, 1)
        XCTAssertEqual(written.first?["urlString"] as? String, "https://example.com/first")
        XCTAssertEqual(written.first?["state"] as? String, "pending")
    }
}
