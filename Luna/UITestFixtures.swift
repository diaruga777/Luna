//
//  UITestFixtures.swift
//  Luna
//

#if DEBUG
import LunaModels
import Foundation

/// Named, deterministic reading-list fixtures shared by the in-app UI-test seeding
/// harness (`UITestSeeder`) and the snapshot / navigation tests. Each state is a
/// fixed set of `ReadingListItem`s plus their `ArticleContent`, built off a stable
/// base date and stable (seed-derived) item ids, so the same state renders
/// identically every run.
///
/// To add a new state: add a `case` to `UITestState`, list it in `allCases` ordering
/// implicitly, and return its `Fixture` from `fixture`. To seed it in the app, launch
/// with `-uiTestState <rawValue>`. See `claudedocs/ui-testing.md`.
enum UITestState: String, CaseIterable {
    /// No items at all (empty-state rendering).
    case empty
    /// One of every save type — articles (ready/locked/failed), document, YouTube,
    /// each platform post, music, podcast, friend-shared, price trackers.
    case mixed
    /// 12 unread renderable articles — enough to make catch-up eligible (the dot)
    /// and give the card stack a queue.
    case catchUpEligible
    /// Several price trackers, one of them alerting (a price drop past threshold).
    case priceTracking

    /// The fixture data (items + content) for this state.
    var fixture: UITestFixtures.Fixture { UITestFixtures.fixture(for: self) }
}

/// Whether this process was launched by the UI-test / screenshot harness (any of
/// the `-uiTestState` / `-uiTestScreen` / `-uiTestOnboardingStep` launch args is
/// present). Lives in ReaderKit so both the app (`UITestSeeder`) and ReaderKit's
/// readers can suppress simulator-only debug tap targets ("Split High/Low") during
/// deterministic captures without ReaderKit importing the app target. Reads the
/// launch arguments directly; no UIKit. DEBUG-only.
enum UITestLaunch {
    private static let argKeys = ["-uiTestState", "-uiTestScreen", "-uiTestOnboardingStep"]

    /// True when any UI-test harness launch argument is present.
    static var isActive: Bool {
        let args = ProcessInfo.processInfo.arguments
        return argKeys.contains { args.contains($0) }
    }
}

/// Builders for the deterministic fixtures. Pure — no UIKit, no disk, no network —
/// so it lives in ReaderKit and is reusable from the app and any test target.
enum UITestFixtures {
    /// A complete reading-list fixture: the items in saved order plus the extracted
    /// content for any item that renders in the text reader.
    struct Fixture {
        var items: [ReadingListItem]
        var contents: [UUID: ArticleContent]
    }

    /// Fixed reference instant for all fixtures: 2025-01-15 12:00:00 UTC. Every
    /// fixture date is expressed as an offset from this, so "3 days ago" etc. are
    /// stable across runs (no `Date()`).
    static let baseDate = Date(timeIntervalSince1970: 1_736_942_400)

    /// A date `days`/`hours` before `baseDate`.
    static func ago(days: Int = 0, hours: Int = 0) -> Date {
        baseDate.addingTimeInterval(TimeInterval(-(days * 86_400 + hours * 3_600)))
    }

    static func fixture(for state: UITestState) -> Fixture {
        switch state {
        case .empty: return Fixture(items: [], contents: [:])
        case .mixed: return mixedFixture()
        case .catchUpEligible: return catchUpFixture()
        case .priceTracking: return priceTrackingFixture()
        }
    }

    // MARK: - Article content

    /// A multi-block article body long enough to clear the readable threshold and
    /// exercise headings, paragraphs, a quote, and a list item.
    static func sampleArticleContent(title: String, author: String? = "Jane Doe") -> ArticleContent {
        let lede = "This is a deterministic fixture article used by the snapshot and "
            + "navigation tests. Its text is fixed so the reader renders identically on "
            + "every run. The body is long enough to be considered readable and to fill "
            + "more than one screen so scroll-depth behavior is exercised."
        let body = String(repeating: lede + " ", count: 6)
        return ArticleContent(
            title: title,
            author: author,
            blocks: [
                .init(kind: .heading, text: "Introduction", links: []),
                .init(kind: .paragraph, text: body, links: [
                    .init(start: 0, length: 4, urlString: "https://example.com/link")
                ]),
                .init(kind: .quote, text: "A representative pull quote that stands apart from the body.", links: []),
                .init(kind: .heading, text: "Details", links: []),
                .init(kind: .listItem, text: "A first list item in the article body.", links: []),
                .init(kind: .listItem, text: "A second list item for measure.", links: []),
                .init(kind: .paragraph, text: body, links: []),
            ])
    }

    // MARK: - Mixed (one of every save type)

    static func mixedFixture() -> Fixture {
        var items: [ReadingListItem] = []
        var contents: [UUID: ArticleContent] = [:]

        func article(
            seed: String, url: String, title: String,
            state: ReadingListItem.State = .ready,
            readState: ReadingListItem.ReadState = .unopened,
            daysAgo: Int, sharedBy: String? = nil, withContent: Bool = true
        ) -> ReadingListItem {
            let item = ReadingListItem(
                seed: seed, urlString: url, title: title, dateAdded: ago(days: daysAgo),
                state: state, readState: readState,
                wordCount: withContent ? 480 : nil,
                readingProgress: readState == .opened ? 0.35 : nil,
                sharedByUsername: sharedBy,
                captureSource: .manual)
            if withContent && state == .ready {
                contents[item.id] = sampleArticleContent(title: title)
            }
            return item
        }

        func platform(
            seed: String, url: String, title: String, daysAgo: Int,
            platform: ContentPlatform, creator: String?,
            mediaTitle: String? = nil, source: MusicProvider? = nil,
            youtubeID: String? = nil, channel: String? = nil
        ) -> ReadingListItem {
            ReadingListItem(
                seed: seed, urlString: url, title: title, dateAdded: ago(days: daysAgo),
                state: .ready, readState: .unopened,
                platform: platform, platformItemID: seed,
                mediaCreatorName: creator, mediaItemTitle: mediaTitle,
                mediaSourceService: source,
                youtubeVideoID: youtubeID, channelName: channel,
                captureSource: .shareSheet)
        }

        // Articles
        items.append(article(seed: "a-ready", url: "https://example.com/ready",
                             title: "A Ready Article To Read", daysAgo: 1))
        items.append(article(seed: "a-opened", url: "https://example.com/opened",
                             title: "An Article You Started", readState: .opened, daysAgo: 2))
        items.append(article(seed: "a-locked", url: "https://wsj.com/locked-story",
                             title: "A Hard-Paywalled Story", state: .needsCaptcha,
                             daysAgo: 1, withContent: false))
        items.append(article(seed: "a-failed", url: "https://example.com/broken",
                             title: "Couldn't Load This One", state: .failed,
                             daysAgo: 3, withContent: false))
        items.append(article(seed: "a-friend", url: "https://example.com/from-friend",
                             title: "Shared By A Friend", daysAgo: 2, sharedBy: "alex"))

        // Document
        var doc = ReadingListItem(
            seed: "doc-pdf", urlString: "lunadoc://report.pdf",
            title: "Quarterly Report.pdf", dateAdded: ago(days: 4),
            state: .ready, wordCount: 1200, documentType: "pdf", captureSource: .shareSheet)
        contents[doc.id] = sampleArticleContent(title: "Quarterly Report", author: nil)
        items.append(doc)

        // YouTube
        items.append(platform(seed: "yt", url: "https://youtube.com/watch?v=dQw4w9WgXcQ",
                             title: "A YouTube Video", daysAgo: 1, platform: .youtube,
                             creator: nil, youtubeID: "dQw4w9WgXcQ", channel: "Some Channel"))
        // Platform posts
        items.append(platform(seed: "x", url: "https://x.com/user/status/123",
                             title: "A post on X", daysAgo: 1, platform: .x, creator: "@user"))
        items.append(platform(seed: "bsky", url: "https://bsky.app/profile/u/post/abc",
                             title: "A Bluesky post", daysAgo: 1, platform: .bluesky, creator: "u.bsky.social"))
        items.append(platform(seed: "reddit", url: "https://reddit.com/r/swift/comments/x/title",
                             title: "A Reddit thread", daysAgo: 1, platform: .reddit, creator: "r/swift"))
        items.append(platform(seed: "tiktok", url: "https://tiktok.com/@creator/video/9",
                             title: "A TikTok", daysAgo: 1, platform: .tiktok, creator: "@creator"))
        items.append(platform(seed: "ig", url: "https://instagram.com/p/abc",
                             title: "An Instagram post", daysAgo: 1, platform: .instagram, creator: "creator"))
        items.append(platform(seed: "fb", url: "https://facebook.com/post/1",
                             title: "A Facebook post", daysAgo: 1, platform: .facebook, creator: "A Page"))
        // Music + podcast (Spotify + Apple)
        items.append(platform(seed: "music-sp", url: "https://open.spotify.com/track/1",
                             title: "A Song", daysAgo: 1, platform: .music,
                             creator: "An Artist", mediaTitle: "A Song", source: .spotify))
        items.append(platform(seed: "podcast-ap", url: "https://podcasts.apple.com/show/1?i=2",
                             title: "An Episode", daysAgo: 1, platform: .podcast,
                             creator: "A Show", mediaTitle: "An Episode", source: .apple))

        // Price trackers — normal + alerting
        items.append(ReadingListItem(
            seed: "pt-normal", urlString: "https://store.example.com/widget",
            title: "Tracked Widget", dateAdded: ago(days: 2),
            state: .ready, captureSource: .manual,
            priceTracker: PriceTracker(
                productName: "Tracked Widget", firstStoreURL: "https://store.example.com/widget",
                price: 99.99, currency: "USD", brand: "Acme", productID: "WIDGET-1",
                now: ago(days: 2))))

        var alertingTracker = PriceTracker(
            productName: "Discounted Gadget", firstStoreURL: "https://store.example.com/gadget",
            price: 200, currency: "USD", brand: "Acme", productID: "GADGET-1", now: ago(days: 3))
        alertingTracker.setPrice(150, currency: "USD",
                                 urlString: "https://store.example.com/gadget", at: ago(hours: 6))
        items.append(ReadingListItem(
            seed: "pt-alerting", urlString: "https://store.example.com/gadget",
            title: "Discounted Gadget", dateAdded: ago(days: 3),
            state: .ready, captureSource: .manual, priceTracker: alertingTracker))

        return Fixture(items: items, contents: contents)
    }

    // MARK: - Catch-up eligible (12+ unread renderable)

    static func catchUpFixture() -> Fixture {
        var items: [ReadingListItem] = []
        var contents: [UUID: ArticleContent] = [:]
        for index in 0..<12 {
            let title = "Catch-Up Article #\(index + 1)"
            let item = ReadingListItem(
                seed: "cu-\(index)", urlString: "https://example.com/catchup/\(index)",
                title: title, dateAdded: ago(days: index + 1),
                state: .ready, readState: .unopened, wordCount: 480,
                captureSource: .manual)
            contents[item.id] = sampleArticleContent(title: title)
            items.append(item)
        }
        return Fixture(items: items, contents: contents)
    }

    // MARK: - Price tracking populated

    static func priceTrackingFixture() -> Fixture {
        var items: [ReadingListItem] = []

        func tracker(seed: String, name: String, url: String, base: Decimal,
                     current: Decimal?, daysAgo: Int) -> ReadingListItem {
            var pt = PriceTracker(productName: name, firstStoreURL: url, price: base,
                                  currency: "USD", brand: "Acme", productID: seed,
                                  now: ago(days: daysAgo))
            if let current {
                pt.setPrice(current, currency: "USD", urlString: url, at: ago(hours: 4))
            }
            return ReadingListItem(
                seed: seed, urlString: url, title: name, dateAdded: ago(days: daysAgo),
                state: .ready, captureSource: .manual, priceTracker: pt)
        }

        items.append(tracker(seed: "ptp-1", name: "Steady Headphones",
                             url: "https://store.example.com/headphones",
                             base: 249.99, current: 249.99, daysAgo: 5))
        items.append(tracker(seed: "ptp-2", name: "Dropped Monitor",
                             url: "https://store.example.com/monitor",
                             base: 400, current: 300, daysAgo: 6))
        items.append(tracker(seed: "ptp-3", name: "Pending Keyboard",
                             url: "https://store.example.com/keyboard",
                             base: 120, current: nil, daysAgo: 3))
        return Fixture(items: items, contents: [:])
    }
}
#endif
