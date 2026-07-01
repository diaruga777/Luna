//
//  ArchiveWebPreStageTests.swift
//  LunaTests
//

import LunaArchiveReader
import XCTest
@testable import Luna

final class ArchiveWebPreStageTests: XCTestCase {
    func testPaywalledArticlesGoStraightToArchiveIs() {
        let url = URL(string: "https://www.wsj.com/articles/x")!
        XCTAssertTrue(ArchiveWebReaderViewController.webPreStageURLs(for: url).isEmpty)
    }
}
