//
//  LinkImportPreviewLoaderTests.swift
//  LunaTests
//

import LunaFetch
import UIKit
import XCTest
@testable import Luna

/// The import review list's rolling preview window: what it fetches, what it
/// refuses to fetch, and what a row shows at each stage
/// (`claudedocs/import-export.md`).
@MainActor
final class LinkImportPreviewLoaderTests: XCTestCase {

    /// One fetch per URL, resolved by the test when it chooses, so the queue and
    /// the concurrency cap are observable rather than raced.
    private final class Recorder {
        var requested: [String] = []
        var continuations: [String: CheckedContinuation<LinkPreview, Error>] = [:]

        func finish(_ urlString: String, with preview: LinkPreview) {
            continuations.removeValue(forKey: urlString)?.resume(returning: preview)
        }

        func fail(_ urlString: String, with error: Error) {
            continuations.removeValue(forKey: urlString)?.resume(throwing: error)
        }
    }

    /// The page reads a test drives by hand: each request parks on a
    /// continuation the test resumes when it chooses.
    private struct FakeNetwork: LinkImportPreviewNetworking {
        let recorder: Recorder
        let imageData: Data?
        let isOnline: Bool

        func fetchPreview(for url: URL) async throws -> LinkPreview {
            try await withCheckedThrowingContinuation { continuation in
                recorder.requested.append(url.absoluteString)
                recorder.continuations[url.absoluteString] = continuation
            }
        }

        func fetchImageData(from url: URL) async throws -> Data {
            guard let imageData else { throw URLError(.badServerResponse) }
            return imageData
        }
    }

    /// Records which rows the loader reported as changed.
    @MainActor
    private final class ChangeWatch: LinkImportPreviewLoaderDelegate {
        private(set) var changed: [String] = []

        func previewLoaderDidChangeRow(forURLString urlString: String) {
            changed.append(urlString)
        }
    }

    private var recorder: Recorder!

    override func setUp() {
        super.setUp()
        recorder = Recorder()
    }

    private func makeLoader(
        maximumConcurrent: Int = 2, online: Bool = true, imageData: Data? = nil
    ) -> LinkImportPreviewLoader {
        return LinkImportPreviewLoader(
            maximumConcurrent: maximumConcurrent,
            network: FakeNetwork(
                recorder: recorder!, imageData: imageData, isOnline: online))
    }

    /// Lets the loader's own tasks run to their next suspension point.
    private func settle() async {
        for _ in 0..<8 { await Task.yield() }
    }

    /// Waits for something the loader does across a detached hop (the thumbnail
    /// decode), rather than guessing a number of yields.
    private func waitUntil(
        _ description: String, _ condition: () -> Bool,
        file: StaticString = #filePath, line: UInt = #line
    ) async {
        for _ in 0..<200 {
            if condition() { return }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("timed out waiting for \(description)", file: file, line: line)
    }

    /// Asserts a row REACHES a state, rather than assuming a fixed number of
    /// yields already got it there.
    ///
    /// `settle()`'s eight yields are enough when this class runs alone and not
    /// when the whole suite is competing for the main actor: every assertion
    /// below that follows an async transition used to read the state one hop
    /// early under load. That is how
    /// `testAPageThatDoesNotAnswerLeavesTheRowAsItWas` passed in isolation
    /// (0.001s) and failed in a full run, reading `.loading` where the refusal
    /// had not yet landed. Assertions about a state that must NOT change (a row
    /// that stays `.idle`, a request that is never made) still use `settle()` —
    /// waiting for those would be a tautology.
    private func assertState(
        _ loader: LinkImportPreviewLoader, of urlString: String,
        reaches expected: LinkImportPreviewLoader.State,
        file: StaticString = #filePath, line: UInt = #line
    ) async {
        for _ in 0..<200 {
            if loader.state(for: urlString) == expected { return }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(loader.state(for: urlString), expected, file: file, line: line)
    }

    private func onePixelPNG() -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8))
        return renderer.pngData { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
    }

    // MARK: - The window

    func testOnlyTheRowsInTheWindowAreFetched() async {
        let loader = makeLoader(maximumConcurrent: 4)
        loader.enterWindow(["https://a.example/1", "https://b.example/2"])
        await waitUntil("both rows to be requested") { recorder.requested.count == 2 }

        XCTAssertEqual(
            recorder.requested.sorted(), ["https://a.example/1", "https://b.example/2"])
        await assertState(loader, of: "https://a.example/1", reaches: .loading)
        // Never asked for → never fetched, and the row shows its URL display.
        XCTAssertEqual(loader.state(for: "https://c.example/3"), .idle)
    }

    func testNoMoreThanTheConcurrencyCapIsInFlightAtOnce() async {
        let loader = makeLoader(maximumConcurrent: 2)
        loader.enterWindow(
            ["https://a.example/1", "https://b.example/2", "https://c.example/3"])
        await waitUntil("the cap to be filled") { recorder.requested.count == 2 }

        XCTAssertEqual(recorder.requested.count, 2)
        // The third is queued, not fetched — and it still reads as loading, so its
        // row shows a spinner rather than flickering between states.
        await assertState(loader, of: "https://c.example/3", reaches: .loading)

        recorder.finish("https://a.example/1", with: LinkPreview(title: "One"))
        await waitUntil("the queued third to start") { recorder.requested.count == 3 }
        XCTAssertEqual(recorder.requested.count, 3)
    }

    func testARowThatLeavesTheWindowBeforeItsTurnIsNeverFetched() async {
        let loader = makeLoader(maximumConcurrent: 1)
        loader.enterWindow(["https://a.example/1", "https://b.example/2"])
        await waitUntil("the first row to be requested") { recorder.requested.count == 1 }
        XCTAssertEqual(recorder.requested, ["https://a.example/1"])

        // Scrolled past before its turn came up: the data it would have cost is
        // exactly what the window exists to save.
        loader.leaveWindow(["https://b.example/2"])
        recorder.finish("https://a.example/1", with: LinkPreview(title: "One"))
        await settle()

        XCTAssertEqual(recorder.requested, ["https://a.example/1"])
        XCTAssertEqual(loader.state(for: "https://b.example/2"), .idle)
    }

    func testAFetchAlreadyInFlightIsLeftToFinishWhenItsRowScrollsAway() async {
        let loader = makeLoader(maximumConcurrent: 2)
        loader.enterWindow(["https://a.example/1"])
        await settle()

        loader.leaveWindow(["https://a.example/1"])
        recorder.finish("https://a.example/1", with: LinkPreview(title: "One"))
        await settle()

        // Cancelling would waste the bytes already spent, and scrolling back is
        // likely — so the answer is kept.
        await assertState(
            loader, of: "https://a.example/1",
            reaches: .loaded(LinkImportPreviewLoader.Preview(title: "One")))
    }

    func testARowIsNeverFetchedTwice() async {
        let loader = makeLoader()
        loader.enterWindow(["https://a.example/1"])
        await settle()
        recorder.finish("https://a.example/1", with: LinkPreview(title: "One"))
        await settle()

        loader.enterWindow(["https://a.example/1"])
        await settle()
        XCTAssertEqual(recorder.requested, ["https://a.example/1"])
    }

    // MARK: - Failing

    func testOfflineFailsFastWithNoSpinnerAndNoRequest() async {
        let loader = makeLoader(online: false)
        loader.enterWindow(["https://a.example/1"])
        await settle()

        XCTAssertTrue(recorder.requested.isEmpty)
        // Not `.loading`: a spinner on a plane would promise something that isn't
        // coming.
        await assertState(loader, of: "https://a.example/1", reaches: .unavailable)
    }

    func testAPageThatDoesNotAnswerLeavesTheRowAsItWas() async {
        let loader = makeLoader()
        loader.enterWindow(["https://a.example/1"])
        await settle()
        recorder.fail("https://a.example/1", with: URLError(.timedOut))

        await assertState(loader, of: "https://a.example/1", reaches: .unavailable)
    }

    func testAPageWithNothingUsableIsAnsweredRatherThanRetried() async {
        let loader = makeLoader()
        loader.enterWindow(["https://a.example/1"])
        await settle()
        recorder.finish("https://a.example/1", with: LinkPreview())

        await assertState(
            loader, of: "https://a.example/1",
            reaches: .loaded(LinkImportPreviewLoader.Preview()))
        loader.enterWindow(["https://a.example/1"])
        await settle()
        XCTAssertEqual(recorder.requested.count, 1)
    }

    func testAnUnusableURLIsNeverRequested() async {
        let loader = makeLoader()
        loader.enterWindow(["not a url"])
        await settle()
        XCTAssertTrue(recorder.requested.isEmpty)
        await assertState(loader, of: "not a url", reaches: .unavailable)
    }

    // MARK: - Landing

    func testTheTitleLandsBeforeTheThumbnailAndBothReportAChange() async {
        let loader = makeLoader(imageData: onePixelPNG())
        let changeWatch = ChangeWatch()
        loader.delegate = changeWatch

        loader.enterWindow(["https://a.example/1"])
        await settle()
        recorder.finish(
            "https://a.example/1",
            with: LinkPreview(
                title: "One", siteName: "Example",
                imageURL: URL(string: "https://a.example/cover.png")))
        await waitUntil("the thumbnail to land") {
            if case let .loaded(preview) = loader.state(for: "https://a.example/1") {
                return preview.image != nil
            }
            return false
        }

        guard case let .loaded(preview) = loader.state(for: "https://a.example/1") else {
            return XCTFail("expected a loaded preview")
        }
        XCTAssertEqual(preview.title, "One")
        XCTAssertEqual(preview.siteName, "Example")
        XCTAssertNotNil(preview.image)
        // Entering the window, the text landing, then the picture landing.
        XCTAssertEqual(
            changeWatch.changed, Array(repeating: "https://a.example/1", count: 3))
    }

    func testAThumbnailThatFailsToDownloadStillLeavesTheTitle() async {
        let loader = makeLoader(imageData: nil)
        loader.enterWindow(["https://a.example/1"])
        await settle()
        recorder.finish(
            "https://a.example/1",
            with: LinkPreview(
                title: "One", imageURL: URL(string: "https://a.example/cover.png")))

        await assertState(
            loader, of: "https://a.example/1",
            reaches: .loaded(LinkImportPreviewLoader.Preview(title: "One")))
    }

    // MARK: - What the row shows

    func testTheRowPrefersThePagesOwnTitleThenTheFilesThenTheURL() {
        let entry = LinkImportSheetViewController.Entry(
            urlString: "https://example.com/some/story", fileTitle: "From the file")

        XCTAssertEqual(
            LinkImportSheetViewController.rowTitle(
                for: entry, preview: .loaded(.init(title: "From the page"))),
            "From the page")
        XCTAssertEqual(
            LinkImportSheetViewController.rowTitle(for: entry, preview: .loading),
            "From the file")
        XCTAssertEqual(
            LinkImportSheetViewController.rowTitle(
                for: LinkImportSheetViewController.Entry(
                    urlString: "https://example.com/some/story", fileTitle: nil),
                preview: .unavailable),
            "some/story")
    }

    func testTheSecondLineNamesThePublisherWhenTheresOneAndTheHostOtherwise() {
        let entry = LinkImportSheetViewController.Entry(
            urlString: "https://www.example.com/story", fileTitle: nil)
        XCTAssertEqual(
            LinkImportSheetViewController.rowSubtitle(
                for: entry, preview: .loaded(.init(siteName: "The Example"))),
            "The Example")
        XCTAssertEqual(
            LinkImportSheetViewController.rowSubtitle(for: entry, preview: .idle),
            "www.example.com")
    }
}
