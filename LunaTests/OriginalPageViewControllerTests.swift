//
//  OriginalPageViewControllerTests.swift
//  LunaTests
//

import LunaArchiveReader
import LunaModels
import LunaStorage
import XCTest

final class OriginalPageViewControllerTests: XCTestCase {
    @MainActor
    func testWebArchiveReplayAllowsContentJavaScript() {
        let item = ReadingListItem(urlString: "https://example.com/script-laid-out-article")
        let controller = OriginalPageViewController(item: item, store: .shared)

        XCTAssertTrue(controller.allowsContentJavaScriptForTesting)
    }
}
