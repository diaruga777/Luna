//
//  IntentQueryTests.swift
//  LunaTests
//

import LunaIntents
import LunaModels
import LunaStorage
import XCTest
@testable import Luna

final class IntentQueryTests: XCTestCase {

    func testRedditQueryUsesOperatorsAndStripsPrefixes() {
        let query = RedditPostQuery.searchQuery(
            subreddit: "r/swift", title: "Concurrency tips", author: "u/bob")
        XCTAssertEqual(query, "Concurrency tips subreddit:swift author:bob")
    }

    func testRedditQueryWithoutAuthor() {
        let query = RedditPostQuery.searchQuery(subreddit: "swift", title: "Hello", author: nil)
        XCTAssertEqual(query, "Hello subreddit:swift")
    }

    func testRedditQueryEmptyTitleIsEmpty() {
        XCTAssertEqual(RedditPostQuery.searchQuery(subreddit: "swift", title: "  ", author: "x"), "")
    }

    func testBlueskyQueryUsesFromOperator() {
        let query = BlueskyPostQuery.searchQuery(handle: "@jay.bsky.team", text: "hello world")
        XCTAssertEqual(query, "hello world from:jay.bsky.team")
    }

    func testBlueskyQueryTextOnly() {
        XCTAssertEqual(BlueskyPostQuery.searchQuery(handle: "  ", text: "just text"), "just text")
    }

    // MARK: - Save-intent single-string response parsing

    func testParseFieldsSplitsOnDelimiterAndTrims() {
        XCTAssertEqual(
            SaveResponseParsing.parseFields(from: "Veritasium ; The math of slime"),
            ["Veritasium", "The math of slime"])
        XCTAssertEqual(
            SaveResponseParsing.parseFields(from: "  swift  ;  Concurrency tips ;  bob "),
            ["swift", "Concurrency tips", "bob"])
    }

    func testParseFieldsTreatsNoneAndEmptyAsNothing() {
        XCTAssertEqual(SaveResponseParsing.parseFields(from: "none"), [])
        XCTAssertEqual(SaveResponseParsing.parseFields(from: "  NONE  "), [])
        XCTAssertEqual(SaveResponseParsing.parseFields(from: ""), [])
        XCTAssertEqual(SaveResponseParsing.parseFields(from: "   "), [])
        XCTAssertEqual(SaveResponseParsing.parseFields(from: nil), [])
    }

    func testParseFieldsSingleValuePassesThrough() {
        XCTAssertEqual(
            SaveResponseParsing.parseFields(from: "https://example.com/a"),
            ["https://example.com/a"])
    }
    func testURLSaveRejectsFailedAndRemovedSavesBeforeReturningEntity() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SavesStore(containerURL: directory)
        do {
            _ = try await ReaderURLSave.save(URL(string: "https://example.com/failed")!, store: store) {
                store.markFailed($0.id)
                return $0.id
            }
            XCTFail("A failed extraction must not return a successful saved item")
        } catch { XCTAssertEqual(error as? ReaderURLSave.Failure, .contentUnavailable) }
        do {
            _ = try await ReaderURLSave.save(URL(string: "https://example.com/removed")!, store: store) { store.delete($0); return nil }
            XCTFail("A removed save must not be returned")
        } catch { XCTAssertEqual(error as? ReaderURLSave.Failure, .missing) }
        let saved = try await ReaderURLSave.save(URL(string: "https://example.com/ready")!, store: store) {
            store.saveContent(ArticleContent(title: "Ready", blocks: [.init(kind: .paragraph, text: "Saved text", links: [])]), for: $0).id
        }
        XCTAssertEqual(saved.state, .ready)
        XCTAssertEqual(saved.title, "Ready")
    }

    func testURLSaveRejectsNonWebURLWithoutWritingOrIngesting() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SavesStore(containerURL: directory)
        do {
            _ = try await ReaderURLSave.save(URL(string: "file:///tmp/article")!, store: store) { _ in XCTFail("Invalid URL reached ingestion"); return nil }
            XCTFail("Expected invalid URL")
        } catch { XCTAssertEqual(error as? ReaderURLSave.Failure, .invalidURL) }
        XCTAssertTrue(store.items().isEmpty)
    }

    func testURLSaveReturnsSurvivingSaveAfterDeduplication() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SavesStore(containerURL: directory)
        let canonical = store.add(urlString: "https://example.com/article")
        store.markPlainLink(canonical.id)
        let saved = try await ReaderURLSave.save(URL(string: "https://example.com/wrapper")!, store: store) { wrapper in
            XCTAssertNil(store.updateURL(canonical.urlString, for: wrapper.id))
            return canonical.id
        }
        XCTAssertEqual(saved.id, canonical.id)
        XCTAssertEqual(store.items().count, 1)
    }

}
