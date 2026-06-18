//
//  ArticleResolverTests.swift
//  ClipTests
//

import XCTest
@testable import Clip

final class ArticleResolverTests: XCTestCase {

    /// A paragraph block of `length` characters.
    private func content(title: String, bodyLength: Int) -> ArticleContent {
        let body = String(repeating: "a", count: bodyLength)
        return ArticleContent(title: title, blocks: [.init(kind: .paragraph, text: body, links: [])])
    }

    func testDirectReadableWinsAndSkipsArchive() {
        let direct = content(title: "Real", bodyLength: 1000)
        let result = ArticleResolver.resolution(
            direct: (direct, "<html>direct</html>"), archived: nil)
        XCTAssertEqual(result, .readable(direct, html: "<html>direct</html>"))
    }

    func testArchiveReadableUsedWhenDirectIsStub() {
        let directStub = content(title: "Paywalled", bodyLength: 50)
        let archived = content(title: "Paywalled", bodyLength: 1000)
        let result = ArticleResolver.resolution(
            direct: (directStub, "<stub>"), archived: (archived, "<archive>"))
        XCTAssertEqual(result, .readable(archived, html: "<archive>"))
    }

    /// FT-shaped: the direct fetch returns a titled subscription stub and the
    /// archive fetch fails entirely — the title must survive as `.paywalled`.
    func testDirectStubTitleSurvivesWhenArchiveFails() {
        let directStub = content(title: "FT Headline", bodyLength: 80)
        let result = ArticleResolver.resolution(direct: (directStub, "<stub>"), archived: nil)
        XCTAssertEqual(result, .paywalled(title: "FT Headline"))
    }

    /// WSJ-shaped: the direct fetch 401s (no content at all) but the archive
    /// snapshot, while itself paywalled, still carries the real title.
    func testArchiveTitleUsedWhenDirectFails() {
        let archivedStub = content(title: "WSJ Headline", bodyLength: 120)
        let result = ArticleResolver.resolution(direct: nil, archived: (archivedStub, "<archive>"))
        XCTAssertEqual(result, .paywalled(title: "WSJ Headline"))
    }

    func testDirectTitlePreferredOverArchiveTitle() {
        let directStub = content(title: "Canonical", bodyLength: 40)
        let archivedStub = content(title: "Archive Copy", bodyLength: 60)
        let result = ArticleResolver.resolution(
            direct: (directStub, "<stub>"), archived: (archivedStub, "<archive>"))
        XCTAssertEqual(result, .paywalled(title: "Canonical"))
    }

    func testPlaceholderTitleIsNotTreatedAsReal() {
        let directStub = content(title: "Untitled", bodyLength: 40)
        let result = ArticleResolver.resolution(direct: (directStub, "<stub>"), archived: nil)
        XCTAssertEqual(result, .unreadable)
    }

    func testNothingReachableIsUnreadable() {
        let result = ArticleResolver.resolution(direct: nil, archived: nil)
        XCTAssertEqual(result, .unreadable)
    }
}
