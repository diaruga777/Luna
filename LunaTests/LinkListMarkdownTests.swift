//
//  LinkListMarkdownTests.swift
//  LunaTests
//

import XCTest
@testable import LunaURLClassification

/// Luna's own export format — markdown with `## Links` / `## Archive` headings —
/// and the tier order `LinkListFile` reads every accepted shape through
/// (`claudedocs/import-export.md`).
final class LinkListMarkdownTests: XCTestCase {

    private func stamp(_ day: Int) -> Date {
        var components = DateComponents()
        components.year = 2026
        components.month = 8
        components.day = day
        return Calendar(identifier: .gregorian).date(from: components)!
    }

    // MARK: - Encoding

    func testEncodeWritesBothSectionsWithTitledBullets() {
        let document = LinkListDocument(
            links: ["https://a.example/1", "https://b.example/2"],
            archived: ["https://c.example/3"],
            titles: ["https://a.example/1": "First Piece", "https://c.example/3": "An Old One"],
            isStructured: true)

        let markdown = LinkListMarkdown.encode(
            document, appName: "Luna Reader", exportedOn: stamp(6))

        XCTAssertTrue(markdown.hasPrefix("# Luna Reader Links\n"), markdown)
        XCTAssertTrue(markdown.contains("Exported 2026-08-06."), markdown)
        XCTAssertTrue(markdown.contains("## Links (2)"), markdown)
        XCTAssertTrue(markdown.contains("- [First Piece](https://a.example/1)"), markdown)
        // No title in the file → a bare bullet, still one link per line.
        XCTAssertTrue(markdown.contains("- https://b.example/2"), markdown)
        XCTAssertTrue(markdown.contains("## Archive (1)"), markdown)
        XCTAssertTrue(markdown.contains("- [An Old One](https://c.example/3)"), markdown)
        XCTAssertTrue(markdown.hasSuffix("\n"))
    }

    func testEncodeOmitsAnEmptySectionEntirely() {
        let markdown = LinkListMarkdown.encode(
            LinkListDocument(links: ["https://a.example/1"], isStructured: true),
            appName: "Luna", exportedOn: stamp(6))
        XCTAssertTrue(markdown.contains("## Links (1)"))
        XCTAssertFalse(markdown.contains("Archive"))
    }

    func testEncodeKeepsALinkReadableWhenItsTitleOrURLWouldBreakTheMarkdown() {
        // Brackets in a title would close the link text early; a space or a
        // parenthesis in the URL needs CommonMark's `<…>` destination form.
        XCTAssertEqual(
            LinkListMarkdown.bullet(for: "https://a.example/1", title: "A [bracketed]\ntitle"),
            "- [A bracketed title](https://a.example/1)")
        XCTAssertEqual(
            LinkListMarkdown.bullet(for: "https://a.example/x(1)", title: nil),
            "- <https://a.example/x(1)>")
    }

    // MARK: - Round trip

    func testRoundTripPreservesOrderSectionsAndTitles() {
        let document = LinkListDocument(
            links: ["https://a.example/1", "https://b.example/x?ids=1,2"],
            archived: ["https://c.example/3"],
            titles: ["https://b.example/x?ids=1,2": "Commas, and more"],
            isStructured: true)

        let reread = LinkListFile.parse(
            LinkListMarkdown.encode(document, appName: "Luna", exportedOn: stamp(6)))

        XCTAssertTrue(reread.isStructured)
        XCTAssertEqual(reread.links, document.links)
        XCTAssertEqual(reread.archived, document.archived)
        XCTAssertEqual(reread.titles["https://b.example/x?ids=1,2"], "Commas, and more")
    }

    // MARK: - Reading a mangled export

    func testTheArchiveSplitSurvivesLosingEveryMarkdownMarker() {
        // What comes back out of Notes after an AirDrop: no `##`, no `-`, the
        // headings decorated or counted, the links bare. The split has to hold —
        // losing it is the bug this format exists to fix.
        let document = LinkListFile.parse("""
            Luna Links

            **Links (2)**
            https://a.example/1
            https://b.example/2

            ARCHIVE:
            https://c.example/3
            """)
        XCTAssertTrue(document.isStructured)
        XCTAssertEqual(document.links, ["https://a.example/1", "https://b.example/2"])
        XCTAssertEqual(document.archived, ["https://c.example/3"])
    }

    func testAHeadingIsRecognizedHoweverItIsDecorated() {
        for line in ["## Archive", "**Archive**", "Archive:", "## Archive (128)", "  archived  "] {
            XCTAssertEqual(
                LinkListMarkdown.headingKind(of: line), .archive, line)
        }
        for line in ["## Links", "Links (3)", "Unread", "Reading List", "> Inbox"] {
            XCTAssertEqual(LinkListMarkdown.headingKind(of: line), .links, line)
        }
    }

    func testALineHoldingALinkIsNeverAHeading() {
        // A bookmark titled "Archive" must not re-section the rest of the file.
        XCTAssertNil(LinkListMarkdown.headingKind(of: "- [Archive](https://a.example/1)"))
        XCTAssertNil(LinkListMarkdown.headingKind(of: "archive.example.com"))
    }

    func testLongProseMentioningAnArchiveIsNotAHeading() {
        XCTAssertNil(LinkListMarkdown.headingKind(
            of: "These are the pieces I moved into the archive last spring, roughly."))
    }

    func testLinksAboveTheFirstHeadingAreOrdinarySaves() {
        let document = LinkListFile.parse("""
            https://a.example/1

            ## Archive

            https://c.example/3
            """)
        XCTAssertEqual(document.links, ["https://a.example/1"])
        XCTAssertEqual(document.archived, ["https://c.example/3"])
    }

    func testATitledBulletAndABareURLOnTheSameLineBothImportOnce() {
        let found = LinkListMarkdown.links(
            in: "- [Titled](https://a.example/1) — see also https://b.example/2")
        XCTAssertEqual(found, [
            LinkListMarkdown.FoundLink(urlString: "https://a.example/1", title: "Titled"),
            LinkListMarkdown.FoundLink(urlString: "https://b.example/2", title: nil),
        ])
    }

    func testAMarkdownLinkThatIsNotAWebLinkIsRefused() {
        XCTAssertTrue(LinkListMarkdown.links(in: "- [Mail me](mailto:a@example.com)").isEmpty)
    }

    func testDuplicatesKeepTheirFirstSection() {
        let document = LinkListFile.parse("""
            ## Links
            - https://a.example/1
            ## Archive
            - https://a.example/1
            """)
        XCTAssertEqual(document.links, ["https://a.example/1"])
        XCTAssertTrue(document.archived.isEmpty)
    }

    // MARK: - Tier order

    func testTextWithNoHeadingFallsThroughToTheCSVAndScrapeTiers() {
        XCTAssertNil(LinkListMarkdown.parse("https://a.example/1\nhttps://b.example/2"))
        // …and `LinkListFile` then recovers them flat.
        let document = LinkListFile.parse("https://a.example/1\nhttps://b.example/2")
        XCTAssertFalse(document.isStructured)
        XCTAssertEqual(document.links, ["https://a.example/1", "https://b.example/2"])
    }

    func testHeadingsWithNoLinksUnderThemImportNothing() {
        // `parse` returns an empty structured document, which `LinkListFile`
        // discards; the CSV tier and the scrape then find nothing either.
        let document = LinkListFile.parse("## Links\n\nnothing here yet\n")
        XCTAssertTrue(document.isEmpty)
        XCTAssertFalse(document.isStructured)
    }

    func testABareHostUnderAHeadingStillLandsInThatSection() {
        // A hand-written list under Luna's own headings: the links don't have to
        // be markdown, or even carry a scheme, to be sectioned correctly.
        let document = LinkListFile.parse("## Archive\n\nsee example.com/story")
        XCTAssertTrue(document.isStructured)
        XCTAssertTrue(document.links.isEmpty)
        XCTAssertEqual(document.archived.count, 1)
        XCTAssertTrue(
            document.archived[0].hasSuffix("example.com/story"), document.archived[0])
    }
}
