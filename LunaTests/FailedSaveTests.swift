//
//  FailedSaveTests.swift
//  LunaTests
//
//  The failed-save error card's non-UI machinery: how a failure reason is
//  classified from what a fetch threw, how a card that has no title of its own
//  gets named, how the failure sidecar accumulates, and which surfaces show a
//  kind-less failed save.
//

import LunaFetch
import LunaIngest
import LunaModels
import LunaReadingListUI
import LunaStorage
import XCTest
@testable import Luna

final class SaveFailureReasonTests: XCTestCase {

    // MARK: - Classifying what a fetch threw

    func testHTTPStatusIsCarriedThroughFromABadResponse() {
        let reason = SaveFailureReason(
            fetchError: ArticleFetcher.FetchError.badResponse(status: 403))
        XCTAssertEqual(reason, .httpStatus(403))
    }

    func testStatuslessBadResponseIsUnknownRatherThanAFakeCode() {
        let reason = SaveFailureReason(
            fetchError: ArticleFetcher.FetchError.badResponse(status: nil))
        XCTAssertEqual(reason, .unknown)
    }

    func testNotHTMLAndTooLargeKeepTheirOwnReasons() {
        XCTAssertEqual(
            SaveFailureReason(fetchError: ArticleFetcher.FetchError.notHTML), .notHTML)
        XCTAssertEqual(
            SaveFailureReason(fetchError: ArticleFetcher.FetchError.tooLarge), .tooLarge)
    }

    func testOfflineAndTimeoutAreDistinguishedFromOtherTransportErrors() {
        XCTAssertEqual(
            SaveFailureReason(fetchError: URLError(.notConnectedToInternet)), .offline)
        XCTAssertEqual(
            SaveFailureReason(fetchError: URLError(.timedOut)), .timedOut)
        // A DNS failure has no dedicated case; it keeps its own sentence.
        guard case .network = SaveFailureReason(fetchError: URLError(.cannotFindHost)) else {
            return XCTFail("a host-resolution failure should land in .network")
        }
    }

    func testANonURLErrorIsUnknown() {
        struct Opaque: Error {}
        XCTAssertEqual(SaveFailureReason(fetchError: Opaque()), .unknown)
    }

    // MARK: - Copy

    func testEveryReasonHasANonEmptyHeadline() {
        let reasons: [SaveFailureReason] = [
            .offline, .timedOut, .httpStatus(403), .httpStatus(404), .httpStatus(429),
            .httpStatus(503), .httpStatus(418), .network("Lost connection"), .notReadable,
            .notHTML, .tooLarge, .unsupportedDocument("xyz"), .unsupportedDocument(""),
            .noMediaFound, .couldNotSave, .unknown,
        ]
        for reason in reasons {
            XCTAssertFalse(
                reason.headline.isEmpty, "\(reason) must always have something to say")
        }
    }

    func testStatusCodesAreWordedByWhatTheyMean() {
        XCTAssertTrue(SaveFailureReason.httpStatus(403).headline.contains("refused"))
        XCTAssertTrue(SaveFailureReason.httpStatus(404).headline.contains("gone"))
        XCTAssertTrue(SaveFailureReason.httpStatus(429).headline.contains("rate-limiting"))
        XCTAssertTrue(SaveFailureReason.httpStatus(503).headline.contains("server error"))
    }

    /// Retrying the same background fetch only helps for transient failures — a
    /// 403 or an unreadable page will fail identically forever, so the card
    /// shouldn't invite it.
    func testOnlyTransientFailuresAreWorthRetrying() {
        XCTAssertTrue(SaveFailureReason.offline.isWorthRetrying)
        XCTAssertTrue(SaveFailureReason.timedOut.isWorthRetrying)
        XCTAssertTrue(SaveFailureReason.httpStatus(429).isWorthRetrying)
        XCTAssertTrue(SaveFailureReason.httpStatus(500).isWorthRetrying)
        XCTAssertFalse(SaveFailureReason.httpStatus(403).isWorthRetrying)
        XCTAssertFalse(SaveFailureReason.httpStatus(404).isWorthRetrying)
        XCTAssertFalse(SaveFailureReason.notReadable.isWorthRetrying)
        XCTAssertFalse(SaveFailureReason.noMediaFound.isWorthRetrying)
    }

    func testReasonSurvivesACodableRoundTrip() throws {
        // The sidecar persists these, so a coding regression would silently wipe
        // every stored reason on the next launch.
        for reason in [SaveFailureReason.httpStatus(429), .network("nope"),
                       .unsupportedDocument("epub"), .offline] {
            let data = try JSONEncoder().encode(reason)
            XCTAssertEqual(try JSONDecoder().decode(SaveFailureReason.self, from: data), reason)
        }
    }
}

final class FailedSaveNamingTests: XCTestCase {

    private let url = URL(string: "https://www.example.com/2026/07/how-the-deal-collapsed")!

    func testAFetchedTitleWinsOverEverythingElse() {
        let title = FailedSaveNaming.displayTitle(
            url: url, itemTitle: "Stale", resolvedTitle: "How the Deal Collapsed")
        XCTAssertEqual(title, "How the Deal Collapsed")
    }

    func testAStoredTitleIsUsedWhenNothingWasFetched() {
        XCTAssertEqual(
            FailedSaveNaming.displayTitle(url: url, itemTitle: "Stored headline"),
            "Stored headline")
    }

    /// "Untitled" is the store's placeholder, not a title — it must never win
    /// over the slug guess, which is the whole point of the chain.
    func testUntitledPlaceholderFallsThroughToTheSlugGuess() {
        XCTAssertEqual(
            FailedSaveNaming.displayTitle(url: url, itemTitle: "Untitled"),
            "How The Deal Collapsed")
    }

    func testBlankAndWhitespaceTitlesFallThrough() {
        XCTAssertEqual(
            FailedSaveNaming.displayTitle(url: url, itemTitle: "   ", resolvedTitle: ""),
            "How The Deal Collapsed")
    }

    func testASluglessURLFallsBackToTheHost() {
        let bare = URL(string: "https://www.example.com/")!
        XCTAssertEqual(FailedSaveNaming.displayTitle(url: bare), "example.com")
    }

    func testAMissingURLStillProducesSomething() {
        XCTAssertEqual(FailedSaveNaming.displayTitle(url: nil), "Untitled")
    }

    func testSiteNamePrefersTheFetchedPublisherName() {
        XCTAssertEqual(
            FailedSaveNaming.displaySiteName(url: url, siteName: "The Example"),
            "The Example")
        XCTAssertEqual(FailedSaveNaming.displaySiteName(url: url), "example.com")
        XCTAssertNil(FailedSaveNaming.displaySiteName(url: nil))
    }

    /// The card shows WHICH url failed, so the path and query must survive —
    /// only the scheme is dropped as noise.
    func testDisplayURLDropsOnlyTheScheme() {
        XCTAssertEqual(
            FailedSaveNaming.displayURL(URL(string: "https://a.com/b?c=d")!),
            "a.com/b?c=d")
        XCTAssertEqual(
            FailedSaveNaming.displayURL(URL(string: "http://a.com/b")!), "a.com/b")
        XCTAssertEqual(
            FailedSaveNaming.displayURL(nil, rawURLString: "not a url"), "not a url")
    }
}

final class PageMetadataFetcherTests: XCTestCase {

    /// Publishers keep the clean headline in Open Graph and append " | Site" to
    /// the `<title>` tag, so og:title must win.
    func testOpenGraphTitleBeatsTheTitleTag() {
        let metadata = PageMetadataFetcher.metadata(inHTML: """
        <html><head>
        <title>How the Deal Collapsed | The Example</title>
        <meta property="og:title" content="How the Deal Collapsed">
        <meta property="og:site_name" content="The Example">
        </head><body></body></html>
        """)
        XCTAssertEqual(metadata.title, "How the Deal Collapsed")
        XCTAssertEqual(metadata.siteName, "The Example")
    }

    /// Both `property=` and `name=` spellings appear in the wild for the same key.
    func testMetaNameSpellingIsAccepted() {
        let metadata = PageMetadataFetcher.metadata(inHTML: """
        <html><head><meta name="og:title" content="Named Spelling"></head></html>
        """)
        XCTAssertEqual(metadata.title, "Named Spelling")
    }

    func testTitleTagIsUsedWhenThereIsNoOpenGraph() {
        let metadata = PageMetadataFetcher.metadata(inHTML: "<html><head><title>Plain</title></head></html>")
        XCTAssertEqual(metadata.title, "Plain")
        XCTAssertNil(metadata.siteName)
    }

    func testWhitespaceIsCollapsedToOneLine() {
        let metadata = PageMetadataFetcher.metadata(inHTML: """
        <html><head><title>
            A   wrapped
            headline
        </title></head></html>
        """)
        XCTAssertEqual(metadata.title, "A wrapped headline")
    }

    func testEmptyContentAttributesAreIgnored() {
        let metadata = PageMetadataFetcher.metadata(inHTML: """
        <html><head><meta property="og:title" content="   "><title>Real</title></head></html>
        """)
        XCTAssertEqual(metadata.title, "Real")
    }

    func testAPageWithNoMetadataIsEmpty() {
        XCTAssertTrue(PageMetadataFetcher.metadata(inHTML: "<html><body>hi</body></html>").isEmpty)
        XCTAssertTrue(PageMetadataFetcher.metadata(inHTML: "").isEmpty)
    }

    func testOriginIsTheHTTPSHomepage() {
        XCTAssertEqual(
            PageMetadataFetcher.origin(of: URL(string: "http://a.com/b/c?d=e")!),
            URL(string: "https://a.com")!)
        XCTAssertNil(PageMetadataFetcher.origin(of: URL(string: "file:///tmp/x")!))
    }
}

final class SaveFailureStoreTests: XCTestCase {

    private var directory: URL!
    private var store: SaveFailureStore!
    private var clock = Date(timeIntervalSince1970: 1_000_000_000)

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = SaveFailureStore(containerURL: directory, now: { [unowned self] in self.clock })
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testFirstFailureStartsTheCountAtOne() {
        let id = UUID()
        store.recordFailure(id, reason: .httpStatus(403))
        XCTAssertEqual(store.record(for: id)?.failureCount, 1)
        XCTAssertEqual(store.record(for: id)?.reason, .httpStatus(403))
        XCTAssertEqual(store.record(for: id)?.lastFailureDate, clock)
    }

    func testRepeatFailuresAccumulateAndRefreshTheDate() {
        let id = UUID()
        store.recordFailure(id, reason: .timedOut)
        clock = clock.addingTimeInterval(3600)
        store.recordFailure(id, reason: .timedOut)
        XCTAssertEqual(store.record(for: id)?.failureCount, 2)
        XCTAssertEqual(store.record(for: id)?.lastFailureDate, clock)
    }

    /// A later attempt that couldn't classify itself must not erase the earlier
    /// attempt's real diagnosis — a "403 blocked" is worth more than a shrug.
    func testANilReasonKeepsThePreviouslyCapturedOne() {
        let id = UUID()
        store.recordFailure(id, reason: .httpStatus(403))
        store.recordFailure(id, reason: nil)
        XCTAssertEqual(store.record(for: id)?.reason, .httpStatus(403))
        XCTAssertEqual(store.record(for: id)?.failureCount, 2)
    }

    func testMetadataIsRecordedWithoutTouchingTheCount() {
        let id = UUID()
        store.recordFailure(id, reason: .notReadable)
        store.recordMetadata(id, title: "A headline", siteName: "The Example")
        XCTAssertEqual(store.record(for: id)?.resolvedTitle, "A headline")
        XCTAssertEqual(store.record(for: id)?.siteName, "The Example")
        XCTAssertEqual(store.record(for: id)?.failureCount, 1)
    }

    func testEmptyMetadataNeverOverwritesAGoodValue() {
        let id = UUID()
        store.recordMetadata(id, title: "Kept", siteName: "Kept Site")
        store.recordMetadata(id, title: "", siteName: nil)
        XCTAssertEqual(store.record(for: id)?.resolvedTitle, "Kept")
        XCTAssertEqual(store.record(for: id)?.siteName, "Kept Site")
    }

    func testClearingRemovesTheRecordSoALaterFailureStartsFresh() {
        let id = UUID()
        store.recordFailure(id, reason: .offline)
        store.recordFailure(id, reason: .offline)
        store.clear(id)
        XCTAssertNil(store.record(for: id))
        store.recordFailure(id, reason: .offline)
        XCTAssertEqual(store.record(for: id)?.failureCount, 1)
    }

    func testPruningDropsRowsForItemsThatNoLongerExist() {
        let kept = UUID()
        let gone = UUID()
        store.recordFailure(kept, reason: .offline)
        store.recordFailure(gone, reason: .offline)
        store.prune(keeping: [kept])
        XCTAssertNotNil(store.record(for: kept))
        XCTAssertNil(store.record(for: gone))
    }

    func testRecordsSurviveARelaunchFromTheSameContainer() {
        let id = UUID()
        store.recordFailure(id, reason: .httpStatus(429))
        store.recordMetadata(id, title: "Persisted", siteName: nil)
        let reopened = SaveFailureStore(containerURL: directory)
        XCTAssertEqual(reopened.record(for: id)?.reason, .httpStatus(429))
        XCTAssertEqual(reopened.record(for: id)?.resolvedTitle, "Persisted")
    }
}

final class FailedSaveSurfacingTests: XCTestCase {

    private func failedItem() -> ReadingListItem {
        var item = ReadingListItem(urlString: "https://example.com/broken")
        item.state = .failed
        return item
    }

    /// A failed save carries no kind (the classifier never got one), so it
    /// belongs to no app — and therefore shows in ALL of them. The app the user
    /// saved the link in is where they expect to see it break.
    func testEverySurfaceShowsAKindLessFailedSave() {
        let item = failedItem()
        for filter in ReadingListSectioning.ListFilter.allCases {
            XCTAssertTrue(
                filter.includes(item),
                "\(filter) must show a failed save — it belongs to no single app")
        }
        for surface in [AppSurface.all, .reader, .downloader, .priceTracker] {
            XCTAssertTrue(surface.includes(item), "\(surface) must show a failed save")
        }
    }

    func testAFailedPlatformItemKeepsItsOwnKindAndUI() {
        var item = failedItem()
        item.platform = .youtube
        XCTAssertFalse(
            ReadingListSectioning.isFailedSave(item),
            "a platform item that failed a later step is not a kind-less failed save")
        XCTAssertFalse(ReadingListSectioning.ListFilter.articles.includes(item))
    }

    func testAReadyItemIsUnaffected() {
        var item = failedItem()
        item.state = .ready
        XCTAssertFalse(ReadingListSectioning.isFailedSave(item))
        XCTAssertTrue(ReadingListSectioning.ListFilter.articles.includes(item))
        XCTAssertFalse(ReadingListSectioning.ListFilter.mediaAndLinks.includes(item))
    }
}

final class FailedSaveCardFactoryTests: XCTestCase {

    /// Only the central Luna app has a real question to ask — the other three
    /// each handle exactly one kind, so their hint is implied and the card shows
    /// no picker.
    func testOnlyTheCentralAppOffersAHintPicker() {
        XCTAssertEqual(FailedSaveCardFactory.hintChoices(for: .all), RescueHint.allCases)
        XCTAssertEqual(FailedSaveCardFactory.hintChoices(for: .reader), [.article])
        XCTAssertEqual(FailedSaveCardFactory.hintChoices(for: .downloader), [.media])
        XCTAssertEqual(FailedSaveCardFactory.hintChoices(for: .priceTracker), [.product])
    }

    func testASingleFreshFailureShowsNoAttemptHistory() {
        let record = SaveFailureRecord(reason: .offline, failureCount: 1)
        XCTAssertNil(FailedSaveCardFactory.attemptFooter(record))
        XCTAssertNil(FailedSaveCardFactory.attemptFooter(nil))
    }

    func testARepeatedFailureReportsItsCount() {
        let now = Date(timeIntervalSince1970: 1_000_000_000)
        let record = SaveFailureRecord(
            reason: .timedOut, lastFailureDate: now.addingTimeInterval(-7200), failureCount: 3)
        let footer = FailedSaveCardFactory.attemptFooter(record, now: now)
        XCTAssertNotNil(footer)
        XCTAssertTrue(footer?.contains("3 times") == true, "got \(footer ?? "nil")")
    }
}
