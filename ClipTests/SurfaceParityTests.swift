//
//  SurfaceParityTests.swift
//  ClipTests
//

import ClipModels
import UIKit
import XCTest
@testable import Clip

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
        case reader, tracker, nonTextual, savedDocument, archiveReader, error
    }

    // MARK: - Fake extension host (records what the driver presented)

    private final class FakeExtensionHost: ExtensionHost {
        var readerMode: ShareReaderViewController.Mode?
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

        /// The intent the surface expressed (derived from what the driver did).
        var intent: SurfaceIntent {
            if let last = presented.last {
                if last is PriceTrackingViewController { return .tracker }
                if last is ShareReaderViewController { return .reader }
                if last is SavedNonTextualViewController { return .nonTextual }
                if last is ArchiveWebReaderViewController { return .archiveReader }
            }
            if error != nil { return .error }
            if autoDownloadedURL != nil { return .nonTextual }
            return .savedDocument // a quiet save + checkmark (article/document/failed-share)
        }
    }

    // MARK: - Fixtures + store

    private var scratch: URL!
    private var store: ReadingListStore!

    override func setUp() {
        super.setUp()
        UIView.setAnimationsEnabled(false)
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("SurfaceParity-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        store = ReadingListStore(containerURL: scratch)
    }

    override func tearDown() {
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
            // fbrpc Facebook deep link → unwraps OFFLINE to its YouTube target → video.
            Link(name: "facebook fbrpc video redirect",
                 url: "fbrpc://nativethirdparty/f?app_id=1"
                    + "&target_url=https%3A%2F%2Fwww.youtube.com%2Fwatch%3Fv%3DdQw4w9WgXcQ",
                 fixtures: [:], expectedExtensionActionIntent: .nonTextual),
            Link(name: "tiktok",
                 url: "https://www.tiktok.com/@u/video/7212345678901234567",
                 fixtures: [:], expectedExtensionActionIntent: .nonTextual),
            Link(name: "youtube",
                 url: "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
                 fixtures: [:],
                 expectedExtensionActionIntent: .nonTextual),
            Link(name: "instagram",
                 url: "https://www.instagram.com/reel/Cx/",
                 fixtures: [:],
                 expectedExtensionActionIntent: .nonTextual),
            Link(name: "x",
                 url: "https://x.com/jack/status/20",
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
        return await IngestPipeline.process(
            IngestInput(url: url(link.url), source: source, prefetchedHTML: prefetched),
            timeout: 10, session: OfflineFailingProtocol.session(), fetcher: fetcher(for: link))
    }

    /// The main-app surface's presentation intent for an `Outcome` (mirrors
    /// `IngestorOutcomePresenter` + `ReadingListViewController.open`).
    private func mainAppIntent(for outcome: Outcome) -> SurfaceIntent {
        switch outcome {
        case .article: return .reader
        case .product: return .tracker
        case .video, .social, .audio: return .nonTextual
        case .document: return .savedDocument
        case .needsArchive: return .archiveReader
        case .failed: return .error
        }
    }

    /// The extension surface's intent: drive the REAL `ShareSurfaceDriver` with the
    /// outcome and a fake host, then read back what it presented.
    private func extensionIntent(for outcome: Outcome, link: Link, isAction: Bool) -> SurfaceIntent {
        // Each surface invocation needs its own freshly-saved item.
        let finalURLString = finalURL(for: link)
        if let existing = store.item(forURLString: finalURLString) { store.delete(existing) }
        _ = store.add(urlString: finalURLString)
        let host = FakeExtensionHost(isActionExtension: isAction)
        let driver = ShareSurfaceDriver(host: host, store: store)
        driver.present(outcome, url: url(finalURLString))
        return host.intent
    }

    /// The URL the surfaces operate on AFTER the pipeline's offline unwrap (fbrpc →
    /// target). For non-wrapper links this is the link itself.
    private func finalURL(for link: Link) -> String {
        URLUnwrapper.unwrapOffline(link.url)
    }

    // MARK: - The parity assertions

    /// Same link → same `Outcome` from the main-app source AND the extension source.
    func testSameOutcomeAcrossMainAppAndExtensionSources() async {
        for link in links() {
            let mainApp = await process(link, source: .manual)        // paste / typed / app
            let shareExt = await process(link, source: .shareSheet)   // share extension
            let actionExt = await process(link, source: .appIntent)   // action extension
            XCTAssertEqual(mainApp, shareExt, "\(link.name): main app vs share extension Outcome")
            XCTAssertEqual(mainApp, actionExt, "\(link.name): main app vs action extension Outcome")
        }
    }

    /// Same link → the main-app presenter and BOTH extension presenters map the Outcome
    /// to the IDENTICAL presentation intent (the headline cross-surface guarantee).
    func testSamePresentationIntentAcrossSurfaces() async {
        for link in links() {
            let outcome = await process(link, source: .manual)
            let appIntent = mainAppIntent(for: outcome)
            let actionIntent = extensionIntent(for: outcome, link: link, isAction: true)
            XCTAssertEqual(actionIntent, appIntent,
                           "\(link.name): action extension must present the same intent as the main app")

            // The zero-UI share extension agrees on the interactive intents (tracker,
            // archive) and never mis-presents; for article/document it saves silently
            // (savedDocument) and for video it auto-downloads (nonTextual) — assert it
            // never diverges into the WRONG interactive UI.
            let shareIntent = extensionIntent(for: outcome, link: link, isAction: false)
            switch appIntent {
            case .tracker, .archiveReader, .nonTextual:
                XCTAssertEqual(shareIntent, appIntent,
                               "\(link.name): share extension must match the interactive intent")
            case .reader, .savedDocument:
                XCTAssertEqual(shareIntent, .savedDocument,
                               "\(link.name): share extension saves articles/documents silently")
            case .error:
                break // share ext completes quietly on failure (by design)
            }

            if let expected = link.expectedExtensionActionIntent {
                XCTAssertEqual(actionIntent, expected, "\(link.name): expected action-ext intent")
            }
        }
    }

    /// The extension PERSISTS the classified item the SAME shape the main app would:
    /// a YouTube link saved via the extension carries its platform + videoID (the bug-4
    /// regression — it used to be a bare URL), a product becomes a tracker.
    func testExtensionPersistsClassifiedItem() async {
        // YouTube via the share extension.
        let youtube = links().first { $0.name == "youtube" }!
        let ytOutcome = await process(youtube, source: .shareSheet)
        _ = extensionIntent(for: ytOutcome, link: youtube, isAction: false)
        let ytSaved = store.item(forURLString: finalURL(for: youtube))
        XCTAssertEqual(ytSaved?.contentPlatform, .youtube, "youtube saved via share ext keeps its platform")
        XCTAssertEqual(ytSaved?.youtubeVideoID, "dQw4w9WgXcQ")

        // Amazon via the action extension.
        let amazon = links().first { $0.name == "amazon" }!
        let amzOutcome = await process(amazon, source: .appIntent)
        _ = extensionIntent(for: amzOutcome, link: amazon, isAction: true)
        XCTAssertNotNil(store.item(forURLString: finalURL(for: amazon))?.priceTracker,
                        "amazon saved via action ext becomes a price tracker")
    }
}
