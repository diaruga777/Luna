import LunaPluginIngest
import XCTest

final class PluginPageSnapshotTests: XCTestCase {
    func testSnapshotBoundsHTMLAndReportsTruncation() throws {
        let html = String(repeating: "x", count: PluginPageSnapshot.maxHTMLCharacters + 1)
        let snapshot = PluginPageSnapshot(url: "https://example.com", html: html, source: "safari")
        let data = try JSONEncoder().encode(snapshot)
        let value = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual((value["html"] as? String)?.count, PluginPageSnapshot.maxHTMLCharacters)
        XCTAssertEqual(value["truncated"] as? Bool, true)
    }
}
