//
//  ArchiveWebPreStageTests.swift
//  LuneTests
//

import LuneArchiveReader
import XCTest
@testable import Lune

final class ArchiveWebPreStageTests: XCTestCase {
    func testPaywalledArticlesGoStraightToArchiveIs() {
        let url = URL(string: "https://www.wsj.com/articles/x")!
        XCTAssertTrue(ArchiveWebReaderViewController.webPreStageURLs(for: url).isEmpty)
    }
}
