//
//  SurfaceParityTests.swift
//  LunaTests
//

import LunaArticleIngest
import LunaPriceIngest
import LunaShareSurface
import LunaMediaDownload
import LunaPriceUI
import LunaArchiveReader
import LunaStorage
import LunaIngest
import LunaURLClassification
import LunaModels
import UIKit
import XCTest
@testable import Luna
@testable import LunaReaderUI

/// Fails every request instantly, so the pipeline's network-unwrap leg (apple.news /
/// Google News new-style) resolves to a miss without touching the live network and
/// without hanging the test. Used via an ephemeral session injected into the pipeline.
private final class OfflineFailingProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }
    override func stopLoading() {}

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [OfflineFailingProtocol.self]
        return URLSession(configuration: config)
    }
}

/// THE cross-surface parity guarantee: the SAME example links, driven through the
/// MAIN-APP surface AND the EXTENSION surface(s), must produce the IDENTICAL `Outcome`
/// AND the identical presentation intent. `NamedSiteParityTests` proves the pipeline
/// is source-invariant; this proves the two PRESENTERS (the main app's
/// `IngestorOutcomePresenter` switch and the extension's `ShareSurfaceDriver` switch)
/// agree, and that the extension persists the classified item the same shape the main
/// app does. It FAILS if any surface diverges again (the bug class this whole
/// unification removes).
///
/// No live network: the real `IngestPipeline` runs with a mock fetcher + the Stage-1–4
/// fixtures and a nil render tier. Offline-unwrapped links (fbrpc Facebook) classify
/// deterministically; the network-unwrap links (apple.news / Google News) are asserted
/// only for SURFACE PARITY (same Outcome + intent on both surfaces), not a fixed kind.
@MainActor
final class SurfaceParityTests: XCTestCase {

    /// The presentation intent a surface produces — the common vocabulary both the
    /// main-app presenter and the extension driver map an `Outcome` into.
    private enum SurfaceIntent: Equatable {
        case reader, tracker, nonTextual, savedDocument, archiveReader, error, rescue
    }

    // MARK: - Fake extension host (records what the driver presented)

    private final class FakeExtensionHost: ExtensionHost {
        var readerMode: ExtensionReaderMode?
        private(set) var presented: [UIViewController] = []
        private(set) var confirmedSaved = false
        private(set) var completedSilently = false
        private(set) var autoDownloadedURL: String?
        private(set) var error: String?

        init(isActionExtension: Bool) {
            self.readerMode = isActionExtension ? .reader : nil
        }

        func presentModally(_ viewController: UIViewController) { presented.append(viewController) }
        func confirmSavedThenComplete() { confirmedSaved = true }
        func completeSilently() { completedSilently = true }
        func autoDownloadThenComplete(urlString: String) { autoDownloadedURL = urlString }
        func failOrComplete(_ message: String) { error = message }
        func openURL(_ url: URL) {}

        /// True once the surface has done something conclusive. The article leg
        /// presents asynchronously (its reader is prepared before hand-off), so
        /// the caller pumps the main queue until this flips.
        var hasSettled: Bool {
            !presented.isEmpty || confirmedSaved || completedSilently
                || autoDownloadedURL != nil || error != nil
        }

        /// The intent the surface expressed (derived from what the driver did).
        var intent: SurfaceIntent {
            if let last = presented.last {
                if last is PriceTrackingViewController { return .tracker }
                // The article reader arrives finished (`preparedReader`); the
                // loading-screen form remains for the standalone/archive paths.
                if last is ReaderViewController || last is ShareReaderViewController {
                    return .reader
                }
                if last is SavedNonTextualViewController { return .nonTextual }
                if last is ArchiveWebReaderViewController { return .archiveReader }
                if last is RescueFailureViewController { return .rescue }
            }
            if error != nil { return .error }
            if autoDownloadedURL != nil { return .nonTextual }
            return .savedDocument // a quiet save + checkmark (article/document/failed-share)
        }
    }

    // MARK: - Fixtures + store

    private var scratch: URL!
    private var store: SavesStore!

    override func setUp() {
        super.setUp()
        UIView.setAnimationsEnabled(false)
        // Presenters registered EXPLICITLY, same reason the pipeline processors
        // are passed explicitly below: the test bundle can hold its own copy of
        // the frameworks, so the host app's launch registration isn't
        // necessarily visible through the registry here.
        ShareKindPresenterTestSupport.registerAll()
        // The reader is now prepared before presentation, which in production
        // downloads the fixture's unknown-size images first. This suite is about
        // presentation parity, so stub that step out rather than let a fixture's
        // <img> tags pull the suite onto the network.
        ShareReaderViewController.settleImagesOverride = { content, _, _, _ in content }
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("SurfaceParity-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        store = SavesStore(containerURL: scratch)
    }

    override func tearDown() {
        ShareReaderViewController.settleImagesOverride = nil
        try? FileManager.default.removeItem(at: scratch)
        super.tearDown()
    }

    private func url(_ string: String) -> URL {
        guard let url = URL(string: string) else { fatalError("bad test URL: \(string)") }
        return url
    }

    /// One example link, with the fixture HTML (keyed by its FINAL unwrapped URL) the
    /// mock fetcher serves. The expected intent is the agreed presentation both surfaces
    /// must reach (nil ⇒ assert only that the two surfaces AGREE, used for the
    /// network-unwrap links whose offline kind isn't fixed).
    private struct Link {
        let name: String
        let url: String
        /// fixture name → the URL it's served for (the post-unwrap URL).
        let fixtures: [String: String]
        let expectedExtensionActionIntent: SurfaceIntent?
    }

    /// The requested links the unification must handle identically on every surface.
    private func links() -> [Link] {
        [
            Link(name: "amazon",
                 url: "https://www.amazon.com/Acme-Widget/dp/B0ACME1234",
                 fixtures: ["Products/amazon-listprice.html": "https://www.amazon.com/Acme-Widget/dp/B0ACME1234"],
                 expectedExtensionActionIntent: .tracker),
            Link(name: "nytimes (readable)",
                 url: "https://www.nytimes.com/2026/06/20/story.html",
                 fixtures: ["Readable/nytimes-readable.html": "https://www.nytimes.com/2026/06/20/story.html"],
                 expectedExtensionActionIntent: .reader),
            Link(name: "wsj (paywalled)",
                 url: "https://www.wsj.com/articles/apple-prices",
                 fixtures: ["Readable/wsj-paywalled.html": "https://www.wsj.com/articles/apple-prices"],
                 expectedExtensionActionIntent: .archiveReader),
            // Facebook's outbound redirect must be unwrapped before either surface
            // classifies it; both then render the destination article, not Facebook.
            Link(name: "facebook redirect",
                 url: "https://l.facebook.com/l.php?u=https%3A%2F%2Fwww.nytimes.com%2F2026%2F06%2F20%2Fstory.html",
                 fixtures: ["Readable/nytimes-readable.html": "https://www.nytimes.com/2026/06/20/story.html"],
                 expectedExtensionActionIntent: .reader),
            // fbrpc Facebook deep link → unwraps OFFLINE to its TikTok target → video.
            Link(name: "facebook fbrpc video redirect",
                 url: "fbrpc://nativethirdparty/f?app_id=1"
                    + "&target_url=https%3A%2F%2Fwww.tiktok.com%2F%40u%2Fvideo%2F7212345678901234567",
                 fixtures: [:], expectedExtensionActionIntent: .nonTextual),
            Link(name: "tiktok",
                 url: "https://www.tiktok.com/@u/video/7212345678901234567",
                 fixtures: [:], expectedExtensionActionIntent: .nonTextual),
            // YouTube uses the same shared `.video` outcome and the same extension
            // non-textual playback surface as every other downloadable video.
            Link(name: "youtube",
                 url: "https://youtu.be/dQw4w9WgXcQ?t=30",
                 fixtures: [:], expectedExtensionActionIntent: .nonTextual),
            Link(name: "instagram",
                 url: "https://www.instagram.com/reel/Cx/",
                 fixtures: [:],
                 expectedExtensionActionIntent: .nonTextual),
            Link(name: "x",
                 url: "https://x.com/jack/status/20",
                 fixtures: [:],
                 expectedExtensionActionIntent: .nonTextual),
            // Bluesky is the one platform `MediaDownloadablePlatform` doesn't support —
            // its non-downloadable-post path exercises the same auto-download/confirm
            // terminal a non-social-platform (e.g. a bare document) would.
            Link(name: "bluesky",
                 url: "https://bsky.app/profile/someone/post/123",
                 fixtures: [:],
                 expectedExtensionActionIntent: .nonTextual),
            // Network-unwrap links: assert only that BOTH surfaces agree (no fixed kind).
            Link(name: "apple.news",
                 url: "https://apple.news/AbCdEfGhIjK",
                 fixtures: [:],
                 expectedExtensionActionIntent: nil),
            Link(name: "google news",
                 url: "https://news.google.com/articles/CBMiABC?hl=en-US",
                 fixtures: [:],
                 expectedExtensionActionIntent: nil),
        ]
    }

    private func fetcher(for link: Link) -> MockArticleFetcher {
        let fetcher = MockArticleFetcher()
        for (fixture, servedURL) in link.fixtures {
            fetcher.htmlByURL[servedURL] = BypassFixtures.html(fixture)
        }
        return fetcher
    }

    /// Runs the REAL pipeline for `link` from `source` (mock fetcher, fixtures, nil
    /// render, short bounded timeout — no network).
    private func process(_ link: Link, source: CaptureSource) async -> Outcome {
        let prefetched = link.fixtures.keys.first.map { BypassFixtures.html($0) }
        // Processors passed EXPLICITLY: the test bundle can hold its own copy
        // of the LunaIngest framework, so the host app's launch registration
        // (KindWiring) isn't necessarily visible through the registry here.
        return await IngestPipeline.process(
            IngestInput(url: url(link.url), source: source, prefetchedHTML: prefetched),
            timeout: 10, session: OfflineFailingProtocol.session(), fetcher: fetcher(for: link),
            articleProcessor: ArticleIngestProcessor(),
            productProcessor: ProductIngestProcessor())
    }

    /// The main-app surface's presentation intent for an `Outcome` (mirrors
    /// `IngestorOutcomePresenter` + each app card deck's tap routing).
    private func mainAppIntent(for outcome: Outcome) -> SurfaceIntent {
        switch outcome {
        case .article: return .reader
        case .product: return .tracker
        case .video, .social: return .nonTextual
        case .document: return .savedDocument
        case .needsArchive: return .archiveReader
        case .failed: return .error
        case .unsupported: return .error
        }
    }

    /// The extension surface's intent: drive the REAL `ShareSurfaceDriver` with the
    /// outcome and a fake host, then read back what it presented. The surface gate is
    /// pinned to `.supported` — this test is about presentation parity, not the
    /// per-app content gate (see `ShareSurfaceDriverSurfaceTests` for that).
    private func extensionIntent(
        for outcome: Outcome, link: Link, isAction: Bool
    ) async -> SurfaceIntent {
        // Each surface invocation needs its own freshly-saved item.
        let finalURLString = finalURL(for: link)
        if let existing = store.item(forURLString: finalURLString) { store.delete(existing) }
        _ = store.add(urlString: finalURLString)
        let host = FakeExtensionHost(isActionExtension: isAction)
        let driver = ShareSurfaceDriver(
            host: host, store: store, surfaceGate: AlwaysSupportedSurfaceGate())
        driver.present(outcome, url: url(finalURLString))
        // An article's reader is prepared before it is handed to the host, so
        // yield the main actor until the surface has done something conclusive.
        let deadline = Date().addingTimeInterval(10)
        while !host.hasSettled, Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return host.intent
    }

    /// The URL the surfaces operate on AFTER the pipeline's offline unwrap (fbrpc →
    /// target). For non-wrapper links this is the link itself.
    private func finalURL(for link: Link) -> String {
        URLUnwrapper.unwrapOffline(link.url)
    }

    // MARK: - The parity assertions

    /// Same link → the same `Outcome` from every source, AND the main-app presenter
    /// and BOTH extension presenters map that Outcome to the IDENTICAL presentation
    /// intent (the headline cross-surface guarantee). One pipeline pass per source,
    /// reused for both halves.
    func testSameOutcomeAndPresentationIntentAcrossSurfaces() async {
        for link in links() {
            let outcome = await process(link, source: .manual)        // paste / typed / app
            let shareExtOutcome = await process(link, source: .shareSheet)
            let actionExtOutcome = await process(link, source: .appIntent)
            XCTAssertEqual(outcome, shareExtOutcome,
                           "\(link.name): main app vs share extension Outcome")
            XCTAssertEqual(outcome, actionExtOutcome,
                           "\(link.name): main app vs action extension Outcome")

            let appIntent = mainAppIntent(for: outcome)
            let actionIntent = await extensionIntent(for: outcome, link: link, isAction: true)
            if appIntent == .error {
                // URL Rescue (claudedocs/url-rescue.md): a `.failed` outcome now
                // legitimately diverges by surface — the action extension presents
                // the rescue hand-off card while the main app shows the failed row.
                XCTAssertEqual(actionIntent, .rescue,
                               "\(link.name): action extension presents the rescue card on failure")
            } else {
                XCTAssertEqual(actionIntent, appIntent,
                               "\(link.name): action extension must present the same intent as the main app")
            }

            // The zero-UI share extension agrees on the interactive intents (tracker,
            // archive) and never mis-presents; for article/document it saves silently
            // (savedDocument) and for video it auto-downloads (nonTextual) — assert it
            // never diverges into the WRONG interactive UI.
            let shareIntent = await extensionIntent(for: outcome, link: link, isAction: false)
            switch appIntent {
            case .tracker, .archiveReader, .nonTextual:
                XCTAssertEqual(shareIntent, appIntent,
                               "\(link.name): share extension must match the interactive intent")
            case .reader, .savedDocument:
                XCTAssertEqual(shareIntent, .savedDocument,
                               "\(link.name): share extension saves articles/documents silently")
            case .error, .rescue:
                break // share ext completes quietly on failure (by design) — the
                       // rescue card is an action-extension-only affordance
            }

            if let expected = link.expectedExtensionActionIntent {
                XCTAssertEqual(actionIntent, expected, "\(link.name): expected action-ext intent")
            }
        }
    }

    /// The Reader App Clip reaches the SAME answer as every other article surface.
    ///
    /// The clip is the one surface this bundle can't drive: an `.app` inside an
    /// `.app`, hosted by nothing. So it was the one surface with no parity coverage,
    /// and it drifted — `.needsArchive` dead-ended on "download the full app" while
    /// the app and both extensions unlocked the article through the archive reader.
    /// `ClipReaderRoute` is that switch, lifted into LunaReaderUI so this can hold it.
    func testAppClipRoutesEveryOutcomeLikeTheOtherArticleSurfaces() async {
        for link in links() {
            let outcome = await process(link, source: .manual)
            let expected: ClipReaderRoute
            switch mainAppIntent(for: outcome) {
            case .reader: expected = .reader
            case .archiveReader: expected = .archiveUnlock
            // The clip reads articles only: another kind's page, and a document
            // (which the full Reader downloads and stores), have nothing to show.
            case .tracker, .nonTextual, .savedDocument: expected = .notReadable
            case .error, .rescue: expected = .failed
            }
            XCTAssertEqual(ClipReaderRoute.route(for: outcome), expected,
                           "\(link.name): app clip must route like the main app")
        }
    }

    /// The specific regression, pinned without needing a paywalled link to resolve:
    /// a parked paywall opens the clip's own archive unlock, never an error.
    func testAppClipUnlocksAPaywalledArticleInsteadOfDeferringToTheFullApp() {
        XCTAssertEqual(ClipReaderRoute.route(for: .needsArchive(title: "A Real Story - WSJ")),
                       .archiveUnlock)
    }

    /// The extension PERSISTS the classified item the SAME shape the main app would:
    /// a non-downloadable platform post saved via the extension carries its platform +
    /// item id (the bug-4 regression — it used to be a bare URL), a product becomes a
    /// tracker.
    func testExtensionPersistsClassifiedItem() async {
        // Bluesky via the share extension.
        let bluesky = links().first { $0.name == "bluesky" }!
        let blueskyOutcome = await process(bluesky, source: .shareSheet)
        _ = await extensionIntent(for: blueskyOutcome, link: bluesky, isAction: false)
        let blueskySaved = store.item(forURLString: finalURL(for: bluesky))
        XCTAssertEqual(blueskySaved?.contentPlatform, .bluesky,
                       "bluesky saved via share ext keeps its platform")
        XCTAssertEqual(blueskySaved?.platformItemID, "123")

        // Amazon via the action extension.
        let amazon = links().first { $0.name == "amazon" }!
        let amzOutcome = await process(amazon, source: .appIntent)
        _ = await extensionIntent(for: amzOutcome, link: amazon, isAction: true)
        XCTAssertNotNil(store.item(forURLString: finalURL(for: amazon))?.priceTracker,
                        "amazon saved via action ext becomes a price tracker")
    }
}
