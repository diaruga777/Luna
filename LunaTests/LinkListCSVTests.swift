//
//  LinkListCSVTests.swift
//  LunaTests
//

import XCTest
@testable import LunaURLClassification

/// The CSV + scrape tiers of the import reader — a foreign read-later export and
/// arbitrary text. Luna's OWN format is markdown (`LinkListMarkdownTests`); the
/// tier order lives in `LinkListFile` (`claudedocs/import-export.md`).
final class LinkListCSVTests: XCTestCase {

    // MARK: - Structured parsing

    func testParseAcceptsColumnAliasesInEitherOrder() {
        let parsed = LinkListFile.parse("""
            url,section
            https://a.example/1,archive
            https://b.example/2,list
            """)
        XCTAssertTrue(parsed.isStructured)
        XCTAssertEqual(parsed.links, ["https://b.example/2"])
        XCTAssertEqual(parsed.archived, ["https://a.example/1"])
    }

    func testParseTreatsAnyArchPrefixedSectionAsArchive() {
        let parsed = LinkListFile.parse("""
            section,url
            Archived,https://a.example/1
            ARCHIVE,https://b.example/2
            saved,https://c.example/3
            """)
        XCTAssertEqual(parsed.archived, ["https://a.example/1", "https://b.example/2"])
        XCTAssertEqual(parsed.links, ["https://c.example/3"])
    }

    func testParseHandlesCRLFAndBOMAndBlankLines() {
        let parsed = LinkListFile.parse("\u{FEFF}section,url\r\nlist,https://a.example/1\r\n\r\narchive,https://b.example/2\r\n")
        XCTAssertTrue(parsed.isStructured)
        XCTAssertEqual(parsed.links, ["https://a.example/1"])
        XCTAssertEqual(parsed.archived, ["https://b.example/2"])
    }

    func testParseHandlesCRLFWithoutABOM() {
        // Swift reads `\r\n` as ONE Character, so a reader that switches on
        // Characters swallows every line break on a Windows-authored CSV.
        let parsed = LinkListFile.parse(
            "section,url\r\nlist,https://a.example/1\r\narchive,https://b.example/2\r\n")
        XCTAssertTrue(parsed.isStructured)
        XCTAssertEqual(parsed.links, ["https://a.example/1"])
        XCTAssertEqual(parsed.archived, ["https://b.example/2"])
    }

    func testParseDropsDuplicateURLsKeepingTheFirstSection() {
        let parsed = LinkListFile.parse("""
            section,url
            list,https://a.example/1
            archive,https://a.example/1
            list,https://a.example/1
            """)
        XCTAssertEqual(parsed.links, ["https://a.example/1"])
        XCTAssertTrue(parsed.archived.isEmpty)
    }

    func testParseSkipsRowsWhoseURLColumnIsNotAURL() {
        let parsed = LinkListFile.parse("""
            section,url
            list,not a url at all
            list,mailto:someone@example.com
            list,https://a.example/1
            """)
        XCTAssertEqual(parsed.links, ["https://a.example/1"])
    }

    func testParseFillsMissingSectionColumnAsAnOrdinarySave() {
        // A row truncated to just its URL still imports, as a normal link.
        let parsed = LinkListFile.parse("section,url\nhttps://a.example/1")
        XCTAssertEqual(parsed.links, ["https://a.example/1"])
        XCTAssertTrue(parsed.archived.isEmpty)
    }

    // MARK: - Fallback scraping

    func testParsePlainTextOneURLPerLineImportsAllAsLinks() {
        let parsed = LinkListFile.parse("""
            https://a.example/1
            https://b.example/2
            https://c.example/3
            """)
        XCTAssertFalse(parsed.isStructured)
        XCTAssertEqual(parsed.links, [
            "https://a.example/1", "https://b.example/2", "https://c.example/3",
        ])
        XCTAssertTrue(parsed.archived.isEmpty)
    }

    func testParseForeignCSVWithoutASectionColumnScrapesEveryLink() {
        // Pocket-style export: no section column, so nothing tells us about an
        // archive and every link becomes an ordinary save.
        let parsed = LinkListFile.parse("""
            title,url,time_added,tags
            Some Piece,https://a.example/1,1699999999,
            Another,https://b.example/2,1699999998,tag
            """)
        XCTAssertFalse(parsed.isStructured)
        XCTAssertEqual(parsed.links, ["https://a.example/1", "https://b.example/2"])
    }

    func testParsePocketStyleStatusColumnKeepsTheArchiveSplit() {
        let parsed = LinkListFile.parse("""
            title,url,time_added,tags,status
            Unread One,https://a.example/1,1699999999,,unread
            Old One,https://b.example/2,1699999998,,archive
            """)
        XCTAssertTrue(parsed.isStructured)
        XCTAssertEqual(parsed.links, ["https://a.example/1"])
        XCTAssertEqual(parsed.archived, ["https://b.example/2"])
    }

    func testParseScrapesLinksOutOfProse() {
        let parsed = LinkListFile.parse(
            "read this https://a.example/1 and then https://b.example/2, both good")
        XCTAssertEqual(parsed.links, ["https://a.example/1", "https://b.example/2"])
    }

    func testParseScrapeDedupesAndKeepsFirstOrder() {
        let parsed = LinkListFile.parse(
            "https://b.example/2\nhttps://a.example/1\nhttps://b.example/2")
        XCTAssertEqual(parsed.links, ["https://b.example/2", "https://a.example/1"])
    }

    func testParseStructuredHeaderWithNoUsableRowsFallsBackToScraping() {
        // A valid header whose rows are junk still recovers the one real link
        // sitting in the file rather than importing nothing.
        let parsed = LinkListFile.parse("""
            section,url
            list,
            list,
            note: the real one is https://a.example/1
            """)
        XCTAssertFalse(parsed.isStructured)
        XCTAssertEqual(parsed.links, ["https://a.example/1"])
    }

    func testParseDoesNotTurnUnrelatedDecimalColumnsIntoLinks() {
        // Bare-host acceptance would make `https://3.14` out of a score column.
        XCTAssertTrue(LinkListFile.parse("name,score\nthing,3.14\nother,2.72").links.isEmpty)
    }

    func testParseSplitsTabSeparatedLinks() {
        // `URL(string:)` percent-encodes an interior tab instead of refusing it,
        // so the pair would otherwise import as one dead `…%09https://…` link.
        XCTAssertEqual(
            LinkListFile.parse("https://a.example/1\thttps://b.example/2").links,
            ["https://a.example/1", "https://b.example/2"])
    }

    func testParseEmptyTextYieldsNothing() {
        XCTAssertTrue(LinkListFile.parse("").isEmpty)
        XCTAssertTrue(LinkListFile.parse("\n\n  \n").isEmpty)
    }

    func testParseNormalizesBareHostsAndOfflineWrappers() {
        let parsed = LinkListFile.parse("section,url\nlist,example.com/story\n")
        XCTAssertEqual(parsed.links, ["https://example.com/story"])
    }

    // MARK: - CSV reader

    func testRecordReaderHonorsQuotedCommasNewlinesAndDoubledQuotes() {
        let records = LinkListCSV.parseRecords("a,\"b,c\",\"d\ne\",\"f\"\"g\"\n")
        XCTAssertEqual(records, [["a", "b,c", "d\ne", "f\"g"]])
    }

    func testRecordReaderDropsEmptyRecordsButKeepsEmptyFields() {
        let records = LinkListCSV.parseRecords("a,,b\n\n,,\nc\n")
        XCTAssertEqual(records, [["a", "", "b"], ["c"]])
    }

    func testRecordReaderHandlesAMissingTrailingNewline() {
        XCTAssertEqual(LinkListCSV.parseRecords("a,b"), [["a", "b"]])
    }
}
