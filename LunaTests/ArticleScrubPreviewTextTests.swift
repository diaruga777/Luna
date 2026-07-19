import LunaModels
import XCTest
@testable import Luna

final class ArticleScrubPreviewTextTests: XCTestCase {
    func testExcerptStartsNearSavedWordPositionAndStaysBounded() {
        let content = ArticleContent(title: "Title", blocks: [
            block((0..<120).map { "early\($0)" }.joined(separator: " ")),
            block((0..<220).map { "target\($0)" }.joined(separator: " ")),
        ])

        let excerpt = ArticleScrubPreviewText.excerpt(
            from: content, aroundWordIndex: 150, readingProgress: nil)

        XCTAssertTrue(excerpt.contains("target30"))
        XCTAssertFalse(excerpt.contains("early0"))
        XCTAssertLessThanOrEqual(
            excerpt.split(whereSeparator: { $0.isWhitespace }).count,
            ArticleScrubPreviewText.wordBudget + 2)
    }

    func testReadingProgressSelectsCorrespondingBlockWithoutWordIndex() {
        let content = ArticleContent(title: "Title", blocks: [
            block("first block"),
            block("middle block"),
            block("last block"),
        ])

        let excerpt = ArticleScrubPreviewText.excerpt(
            from: content, aroundWordIndex: nil, readingProgress: 0.7)

        XCTAssertTrue(excerpt.contains("last block"))
        XCTAssertFalse(excerpt.contains("first block"))
    }

    private func block(_ text: String) -> ArticleContent.Block {
        ArticleContent.Block(kind: .paragraph, text: text, links: [])
    }
}
