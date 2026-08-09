//
//  ArticleBlockRenderingTests.swift
//  LunaTests
//
//  Ported from LunaLibraries/Tests/LunaModelsTests (retired — that SwiftPM test
//  target never ran under the app-hosted `LunaTests` bundle).
//

import XCTest
@testable import LunaModels

final class ArticleBlockRenderingTests: XCTestCase {

    func testJoinsNonEmptyBlocksWithParagraphSpacing() {
        XCTAssertEqual(
            ArticleBlockRendering.plainText(blocks: [" First ", "", "Second"]),
            "First\n\nSecond")
    }
}
