//
//  ArticleBlockRenderingTests.swift
//  LunaTests
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
