//
//  LinkImportSheetTests.swift
//  LunaTests
//

import LunaIngest
import LunaModels
import LunaSaves
import LunaStorage
import LunaURLClassification
import UIKit
import XCTest
@testable import Luna

/// The import sheet's three stages (`claudedocs/import-export.md`), driven with a
/// runner whose ingest is stubbed.
@MainActor
final class LinkImportSheetTests: XCTestCase {

    private var window: UIWindow?
    private var tempDirectory: URL!
    private var store: SavesStore!

    override func setUp() {
        super.setUp()
        LinkImportRunner.media = nil
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(
            at: tempDirectory, withIntermediateDirectories: true)
        store = SavesStore(containerURL: tempDirectory)
    }

    override func tearDown() {
        window?.isHidden = true
        window?.rootViewController = nil
        window = nil
        try? FileManager.default.removeItem(at: tempDirectory)
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeSheet(
        _ document: LinkListDocument,
        failing: Set<String> = [],
        unsupported: Set<String> = []
    ) -> LinkImportSheetViewController {
        let store = store!
        let runner = LinkImportRunner(
            store: store, concurrency: 2,
            ingest: { item -> SurfaceSupport.Decision in
                if unsupported.contains(item.urlString) {
                    store.delete(item)
                    return .unsupported(owner: .downloader)
                }
                if failing.contains(item.urlString) {
                    store.markFailed(item.id)
                } else {
                    _ = store.saveContent(
                        ArticleContent(
                            title: "Imported",
                            blocks: [.init(kind: .paragraph, text: "Body.", links: [])]),
                        for: item)
                }
                return .supported
            },
            rescue: { _ in false }, rescueFraction: { _ in nil })
        let sheet = LinkImportSheetViewController(document: document, runner: runner)
        window = UITestSupport.host(sheet)
        return sheet
    }

    private func document(
        links: [String], archived: [String] = [], structured: Bool = true
    ) -> LinkListDocument {
        LinkListDocument(links: links, archived: archived, isStructured: structured)
    }

    private func rowTitles(_ sheet: LinkImportSheetViewController, section: Int) -> [String] {
        let rows = sheet.tableView(sheet.table, numberOfRowsInSection: section)
        return (0..<rows).compactMap { row in
            let cell = sheet.tableView(
                sheet.table, cellForRowAt: IndexPath(row: row, section: section))
            return (cell.contentConfiguration as? UIListContentConfiguration)?.text
        }
    }

    private func sectionTitles(_ sheet: LinkImportSheetViewController) -> [String] {
        (0..<sheet.numberOfSections(in: sheet.table)).compactMap {
            sheet.tableView(sheet.table, titleForHeaderInSection: $0)
        }
    }

    // MARK: - Review

    func testReviewShowsBothListsWithCountsAndEverythingSelected() {
        let sheet = makeSheet(
            document(links: ["https://a.example/one", "https://b.example/two"],
                     archived: ["https://c.example/three"]))

        XCTAssertEqual(sectionTitles(sheet), ["Links (2)", "Archive (1)"])
        XCTAssertEqual(rowTitles(sheet, section: 0), ["one", "two"])
        XCTAssertEqual(rowTitles(sheet, section: 1), ["three"])
        XCTAssertEqual(sheet.selectedCandidates.count, 3)
    }

    func testAnEmptyArchiveIsNotRenderedAsABareHeader() {
        let sheet = makeSheet(document(links: ["https://a.example/1"]))
        XCTAssertEqual(sectionTitles(sheet), ["Links (1)"])
    }

    func testAFileWithOnlyArchivedLinksShowsOnlyTheArchive() {
        let sheet = makeSheet(document(links: [], archived: ["https://a.example/1"]))
        XCTAssertEqual(sectionTitles(sheet), ["Archive (1)"])
    }

    func testTappingARowDeselectsItAndTappingAgainRestoresIt() {
        let sheet = makeSheet(
            document(links: ["https://a.example/1", "https://b.example/2"]))
        let table = sheet.table

        sheet.tableView(table, didSelectRowAt: IndexPath(row: 0, section: 0))
        XCTAssertEqual(sheet.selectedCandidates.count, 1)

        sheet.tableView(table, didSelectRowAt: IndexPath(row: 0, section: 0))
        XCTAssertEqual(sheet.selectedCandidates.count, 2)
    }

    func testDeselectingEverythingDisablesImport() {
        let sheet = makeSheet(document(links: ["https://a.example/1"]))
        XCTAssertTrue(sheet.primaryButton.isEnabled)

        sheet.tableView(
            sheet.table, didSelectRowAt: IndexPath(row: 0, section: 0))
        XCTAssertEqual(sheet.selectedCandidates.count, 0)
        XCTAssertFalse(sheet.primaryButton.isEnabled)
    }

    func testAScrapedFileShowsAFooterNoteAndAStructuredOneDoesNot() {
        let sheet = makeSheet(
            document(links: ["https://a.example/1"], structured: false))
        let footer = sheet.tableView(
            sheet.table, titleForFooterInSection: 0)
        XCTAssertEqual(
            footer,
            L10n.string("Settings_linkImport_unstructuredFooter"))
    }

    func testAStructuredFileHasNoSuchWarning() {
        let sheet = makeSheet(document(links: ["https://a.example/1"]))
        XCTAssertNil(
            sheet.tableView(sheet.table, titleForFooterInSection: 0))
    }

    // MARK: - Import and summary

    func testImportingOnlyTheSelectedLinksSavesJustThose() async {
        let sheet = makeSheet(
            document(links: ["https://a.example/1", "https://b.example/2"]))
        sheet.tableView(
            sheet.table, didSelectRowAt: IndexPath(row: 1, section: 0))

        await sheet.performImport()

        XCTAssertEqual(store.items().map(\.urlString), ["https://a.example/1"])
    }

    func testTheSummaryNamesTheAppThatOwnsARejectedLink() async {
        let sheet = makeSheet(
            document(links: ["https://a.example/1", "https://b.example/video"]),
            unsupported: ["https://b.example/video"])

        await sheet.performImport()

        XCTAssertEqual(sectionTitles(sheet), ["Summary", "Not Saved (1)"])
        XCTAssertEqual(rowTitles(sheet, section: 0), ["1 imported"])
        XCTAssertEqual(rowTitles(sheet, section: 1), ["video"])
        let cell = sheet.tableView(
            sheet.table, cellForRowAt: IndexPath(row: 0, section: 1))
        let content = cell.contentConfiguration as? UIListContentConfiguration
        XCTAssertEqual(content?.secondaryText, "Luna Video handles this kind of link.")
    }

    func testTheSummaryReportsAFailureAsRecoverableRatherThanRejected() async {
        let sheet = makeSheet(
            document(links: ["https://a.example/1", "https://b.example/2"]),
            failing: ["https://b.example/2"])

        await sheet.performImport()

        XCTAssertEqual(sectionTitles(sheet), ["Summary"])
        XCTAssertEqual(
            rowTitles(sheet, section: 0), ["1 imported", "1 couldn't be fetched yet"])
    }

    func testTheSummaryReportsAlreadySavedLinks() async {
        let existing = store.add(urlString: "https://a.example/1")
        _ = store.saveContent(
            ArticleContent(title: "Old", blocks: [.init(kind: .paragraph, text: "x", links: [])]),
            for: existing)

        let sheet = makeSheet(
            document(links: ["https://a.example/1", "https://b.example/2"]))
        await sheet.performImport()

        XCTAssertEqual(rowTitles(sheet, section: 0), ["1 imported", "1 already saved"])
    }

    func testTheProgressBarEndsFullAndTheButtonBecomesDone() async {
        let sheet = makeSheet(document(links: ["https://a.example/1"]))
        await sheet.performImport()

        XCTAssertEqual(Double(sheet.progressBar.progress), 1, accuracy: 0.0001)
        XCTAssertEqual(sheet.primaryButton.title(for: .normal), "Done")
    }

    // MARK: - Dismissal guard

    func testTheSheetCannotBeSwipedAwayWhileLinksAreBeingSaved() async {
        let sheet = makeSheet(document(links: ["https://a.example/1"]))
        XCTAssertTrue(sheet.allowsInteractiveDismissal)

        // `performImport` flips the stage synchronously before its first await, so
        // the guard is observable the moment the run starts.
        let running = Task { await sheet.performImport() }
        await Task.yield()
        XCTAssertFalse(sheet.allowsInteractiveDismissal)
        XCTAssertEqual(sheet.primaryButton.title(for: .normal), "Stop")
        await running.value
    }
}
