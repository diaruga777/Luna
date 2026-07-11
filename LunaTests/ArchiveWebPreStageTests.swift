//
//  ArchiveWebPreStageTests.swift
//  LunaTests
//

import LunaArchiveReader
import XCTest
@testable import Luna

final class ArchiveWebPreStageTests: XCTestCase {
    func testRuleListedPaywalledArticlesUseDirectUnlockFirst() {
        let url = URL(string: "https://www.wsj.com/articles/x")!
        XCTAssertEqual(
            ArchiveWebReaderViewController.webPreStageURLs(for: url),
            [url])
    }
}
