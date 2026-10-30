import LunaIntents
import LunaModels
import LunaStorage
import XCTest

final class ArticleTextChunksTests: XCTestCase {
    func testUsesLongestSentenceCutoffInsteadOfFillingWithPartOfNextSentence() throws {
        let text = "One ends. Two ends. This third sentence is much longer."
        let chunks = try ArticleTextChunks.split(text, maximumCharacters: 25)
        XCTAssertEqual(chunks.first, "One ends. Two ends.")
        XCTAssertEqual(chunks.joined(), text)
        XCTAssertTrue(chunks.allSatisfy { $0.count <= 25 })
    }

    func testSentenceAtExactLimitDoesNotRequireItsFollowingSpace() throws {
        let chunks = try ArticleTextChunks.split("First ends. Next ends.", maximumCharacters: 11)
        XCTAssertEqual(chunks, ["First ends.", " Next ends."])
    }

    func testOversizedSentenceUsesLastWordThatFits() throws {
        let text = "One two three four five six."
        let chunks = try ArticleTextChunks.split(text, maximumCharacters: 13)
        XCTAssertEqual(chunks.first, "One two three")
        XCTAssertEqual(chunks.joined(), text)
        XCTAssertTrue(chunks.allSatisfy { $0.count <= 13 })
    }

    func testSentenceCutoffResumesAfterWordFallback() throws {
        let chunks = try ArticleTextChunks.split("One two three four. Five. Six seven eight nine ten.", maximumCharacters: 14)
        XCTAssertEqual(chunks.prefix(2), ["One two three ", "four. Five."])
    }

    func testPreservesAllWhitespaceAndUnicodeForEverySmallLimit() throws {
        let texts = [
            "  First sentence.\n\nSecond sentence!\tThird?  ",
            "👨‍👩‍👧‍👦 cafe\u{301} 👍🏽. Next sentence with words.",
            "最初の文です。次の文章です。最後の文です。",
            "No punctuation and a veryveryverylongword",
            " \n\t  ", "", "...", "One, two; three: four!"
        ]
        for text in texts {
            for limit in 1...max(1, text.count + 1) {
                let chunks = try ArticleTextChunks.split(text, maximumCharacters: limit)
                XCTAssertEqual(chunks.joined(), text, "limit=\(limit)")
                XCTAssertTrue(chunks.allSatisfy { !$0.isEmpty && $0.count <= limit }, "limit=\(limit), chunks=\(chunks)")
            }
        }
    }

    func testOversizedWordSplitsOnlyAtWholeCharacters() throws {
        XCTAssertEqual(try ArticleTextChunks.split("👨‍👩‍👧‍👦👍🏽abcdef", maximumCharacters: 2), ["👨‍👩‍👧‍👦👍🏽", "ab", "cd", "ef"])
    }

    func testEmptyInputAndLargeLimit() throws {
        XCTAssertEqual(try ArticleTextChunks.split("", maximumCharacters: 4), [])
        XCTAssertEqual(try ArticleTextChunks.split("All here.\n", maximumCharacters: .max), ["All here.\n"])
    }

    func testInvalidMaximumIsRejected() {
        XCTAssertThrowsError(try ArticleTextChunks.split("Text.", maximumCharacters: 0))
        XCTAssertThrowsError(try ArticleTextChunks.split("", maximumCharacters: -1))
    }

    func testFetchUsesCurrentSavedContentAndRejectsDeletedOrUnreadableItems() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SavesStore(containerURL: root)
        let item = store.reserveSaveAttempt(urlString: "https://example.com/article", at: Date()).item
        XCTAssertThrowsError(try ArticleTextChunks.chunks(saveID: item.id, maximumCharacters: 20, store: store))
        let content = ArticleContent(title: "Article", blocks: [
            .init(kind: .paragraph, text: "First ends. Two ends.", links: []),
            .init(kind: .paragraph, text: "Third ends.", links: [])
        ])
        let saved = store.saveContent(content, for: item)
        let chunks = try ArticleTextChunks.chunks(saveID: saved.id, maximumCharacters: 21, store: store)
        XCTAssertEqual(chunks.joined(), "First ends. Two ends.\n\nThird ends.")
        XCTAssertEqual(chunks.first, "First ends. Two ends.")
        store.delete(saved)
        XCTAssertThrowsError(try ArticleTextChunks.chunks(saveID: saved.id, maximumCharacters: 20, store: store))
    }
}
