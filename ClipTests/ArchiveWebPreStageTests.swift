//
//  ArchiveWebPreStageTests.swift
//  ClipTests
//

import ClipArchiveReader
import XCTest
@testable import Clip

final class ArchiveWebPreStageTests: XCTestCase {
    func testPaywalledArticlesGoStraightToArchiveIs() {
        let url = URL(string: "https://www.wsj.com/articles/x")!
        XCTAssertTrue(ArchiveWebReaderViewController.webPreStageURLs(for: url).isEmpty)
    }
}
