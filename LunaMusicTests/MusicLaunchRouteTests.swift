import XCTest
@testable import LunaMusicApp

final class MusicLaunchRouteTests: XCTestCase {
    func testQueueDeepLinkOpensQueue() {
        XCTAssertEqual(MusicLaunchRoute(url: URL(string: "lunamusic://queue")!), .queue)
    }
    func testSearchAndLibraryLinks() {
        for path in ["search", "library"] {
            XCTAssertEqual(MusicLaunchRoute(url: URL(string: "lunamusic://\(path)")!), .search)
        }
    }
    func testUnrelatedURLsAreIgnored() {
        XCTAssertNil(MusicLaunchRoute(url: URL(string: "https://queue")!))
        XCTAssertNil(MusicLaunchRoute(url: URL(string: "lunamusic://invalid")!))
    }
}
