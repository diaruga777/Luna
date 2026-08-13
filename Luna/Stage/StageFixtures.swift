//
//  StageFixtures.swift
//  Luna
//

#if DEBUG

import LunaDesignSystem
import LunaModels
import LunaStorage
import LunaWeekly
import UIKit

/// The stub data staged mode seeds, and the small helpers every catalog needs.
///
/// Everything here builds on the fixtures the snapshot tests already use —
/// `UITestFixtures.baseDate` / `ago(days:hours:)` for stable dates,
/// `SavedItem(seed:)` for stable ids, `sampleArticleContent` for body
/// text — so a staged screen and its snapshot test are looking at the same
/// article. What is new here is the per-STATE fixtures (a locked save on its
/// own, a tracker mid-drop, a download frozen at 45%) that a screenshot pass
/// needs and a snapshot test never did.
///
/// Because a staged run's container is a throwaway
/// (`StageContainer.activate`), everything below writes to the real store API
/// and still leaves nothing behind.
enum StageFixtures {

    // MARK: - Dates

    /// The fixture clock. Every date is an offset from it, so two runs a week
    /// apart render the same "2 days ago".
    static var now: Date { UITestFixtures.baseDate }

    static func ago(days: Int = 0, hours: Int = 0) -> Date {
        UITestFixtures.ago(days: days, hours: hours)
    }

    // MARK: - Saves

    /// Replaces the saves list with `items` and pins the sectioning clock, so
    /// fixed-date fixtures land in Reading rather than Archive.
    static func seed(_ items: [SavedItem], contents: [UUID: ArticleContent] = [:]) {
        UITestSeeder.sectioningNow = now
        SavesStore.shared.seedForTesting(items: items, contents: contents)
    }

    /// Empties the saves list (and its article files).
    static func seedEmpty() {
        UITestSeeder.sectioningNow = now
        SavesStore.shared.wipeForTesting()
    }

    /// A ready article with body text. The deck centres on the NEWEST save, so
    /// the age arguments are how a catalog says "this is the card to look at".
    /// Both default to zero — "just now" — because a default of a DAY meant a
    /// fixture written as `hoursAgo: 2` was actually 26 hours old and lost that
    /// race to anything written as `daysAgo: 1`.
    static func article(
        seed: String, url: String, title: String, daysAgo: Int = 0, hoursAgo: Int = 0,
        state: SavedItem.State = .ready,
        readState: SavedItem.ReadState = .unopened,
        readingProgress: Double? = nil,
        sharedBy: String? = nil
    ) -> SavedItem {
        SavedItem(
            seed: seed, urlString: url, title: title, dateAdded: ago(days: daysAgo, hours: hoursAgo),
            state: state, readState: readState, wordCount: 480,
            readingProgress: readingProgress, sharedByUsername: sharedBy,
            captureSource: .manual)
    }

    /// A save with no extracted content: the shapes that render as something
    /// other than a reader card — pending (spinner), needsCaptcha (locked),
    /// failed (the error card).
    static func contentlessArticle(
        seed: String, url: String, title: String?, state: SavedItem.State,
        daysAgo: Int = 0, hoursAgo: Int = 0
    ) -> SavedItem {
        SavedItem(
            seed: seed, urlString: url, title: title,
            dateAdded: ago(days: daysAgo, hours: hoursAgo),
            state: state, captureSource: .manual)
    }

    /// A recognized platform post — the saves half of a media save. The
    /// media half lives in `SavedMediaStore` and is joined by URL string, so
    /// the two must agree (`MediaCardPresenter.media(for:)`).
    static func platformPost(
        seed: String, url: String, title: String, platform: ContentPlatform,
        daysAgo: Int = 0, hoursAgo: Int = 0
    ) -> SavedItem {
        SavedItem(
            seed: seed, urlString: url, title: title,
            dateAdded: ago(days: daysAgo, hours: hoursAgo),
            state: .ready, platform: platform, platformItemID: seed,
            captureSource: .shareSheet)
    }

    /// The article body every staged reader shows.
    static func content(_ title: String, author: String? = "Jane Doe") -> ArticleContent {
        UITestFixtures.sampleArticleContent(title: title, author: author)
    }

    // MARK: - Price trackers

    /// A tracker whose price has not moved: graph flat, no alert.
    static func steadyTracker(
        seed: String, name: String, url: String, price: Decimal, daysAgo: Int
    ) -> SavedItem {
        var tracker = PriceTracker(
            productName: name, firstStoreURL: url, price: price, currency: "USD",
            brand: "Acme", productID: seed, now: ago(days: daysAgo))
        // Three distinct days is `PriceHistory.minimumDaysForGraph` — below it
        // the editor draws a placeholder instead of a line.
        for offset in [3, 2, 1] {
            tracker.recordPriceSample(
                price, currency: "USD", urlString: url, at: ago(days: offset))
        }
        tracker.setPrice(price, currency: "USD", urlString: url, at: ago(hours: 4))
        return trackerItem(seed: seed, name: name, url: url, daysAgo: daysAgo, tracker: tracker)
    }

    /// A tracker past its alert threshold and not yet acknowledged — the badged,
    /// floated-to-the-top state. `recordPriceSample` builds the graph series and
    /// `setPrice` moves the current price; both are needed, they do different
    /// things (`claudedocs/price-tracking.md`).
    static func alertingTracker(
        seed: String, name: String, url: String, from: Decimal, to current: Decimal,
        daysAgo: Int
    ) -> SavedItem {
        var tracker = PriceTracker(
            productName: name, firstStoreURL: url, price: from, currency: "USD",
            brand: "Acme", productID: seed, now: ago(days: daysAgo))
        tracker.recordPriceSample(from, currency: "USD", urlString: url, at: ago(days: 3))
        tracker.recordPriceSample(
            (from + current) / 2, currency: "USD", urlString: url, at: ago(days: 2))
        tracker.recordPriceSample(current, currency: "USD", urlString: url, at: ago(days: 1))
        tracker.setPrice(current, currency: "USD", urlString: url, at: ago(hours: 6))
        return trackerItem(seed: seed, name: name, url: url, daysAgo: daysAgo, tracker: tracker)
    }

    /// A tracker that has never been refreshed: no history at all, so the graph
    /// shows its placeholder and the threshold slider sits parked.
    static func pendingTracker(
        seed: String, name: String, url: String, price: Decimal, daysAgo: Int,
        alertThresholdFraction: Double? = PriceTracker.defaultAlertThresholdFraction
    ) -> SavedItem {
        let tracker = PriceTracker(
            productName: name, firstStoreURL: url, price: price, currency: "USD",
            brand: "Acme", productID: seed,
            alertThresholdFraction: alertThresholdFraction, now: ago(days: daysAgo))
        return trackerItem(seed: seed, name: name, url: url, daysAgo: daysAgo, tracker: tracker)
    }

    private static func trackerItem(
        seed: String, name: String, url: String, daysAgo: Int, tracker: PriceTracker
    ) -> SavedItem {
        SavedItem(
            seed: seed, urlString: url, title: name, dateAdded: ago(days: daysAgo),
            state: .ready, captureSource: .manual, priceTracker: tracker)
    }

    // MARK: - Save of the Week

    /// Puts a live pick in the weekly store. The signature is empty on purpose:
    /// verification happens on the FETCH path (`WeeklySaveRefresher`), never on
    /// read, so a stage does not need the private key to render the row —
    /// see `claudedocs/save-of-the-week.md`.
    static func seedWeeklySave(
        kind: WeeklySaveKind, title: String, host: String, daysOld: Int
    ) {
        WeeklySaveStore.shared.setDisplay(
            WeeklySaveDisplay(
                save: WeeklySave(
                    kind: kind, urlString: "https://\(host)/pick-of-the-week",
                    date: now.addingTimeInterval(-Double(daysOld) * 86_400),
                    signature: Data()),
                title: title, subtitleHost: host),
            for: kind)
    }

    // MARK: - Onboarding

    /// Puts onboarding back to its unanswered state, so the util card shows the
    /// surface headline and the setup block.
    static func resetOnboarding() {
        AppOnboardingStore.shared.resetCompletion(now: now)
    }

    /// Marks onboarding answered, so the util card shows the completed layout
    /// (paste row, Safari-history rows) instead.
    static func completeOnboarding() {
        AppOnboardingStore.shared.markCompleted()
    }

    // MARK: - Hosting

    /// Hosts a bare view as a full screen, centred in the readable column with
    /// the app's own background — for the handful of stages whose subject is a
    /// VIEW (the price graph, the audio mini-player bar) rather than a screen.
    static func hosting(_ view: UIView, height: CGFloat) -> UIViewController {
        StageViewHostViewController(subject: view, subjectHeight: height)
    }

    /// A deterministic solid-colour image written to `directory` — media
    /// fixtures need a real file on disk (the card reads it), and generating one
    /// beats committing a binary that only staged mode uses.
    @discardableResult
    static func writeSampleImage(
        named name: String, in directory: URL, size: CGSize = CGSize(width: 900, height: 1_600)
    ) -> URL? {
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { context in
            UIColor(red: 0.10, green: 0.11, blue: 0.16, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
            UIColor(red: 0.36, green: 0.42, blue: 0.72, alpha: 1).setFill()
            context.cgContext.fillEllipse(
                in: CGRect(x: size.width * 0.25, y: size.height * 0.32,
                           width: size.width * 0.5, height: size.width * 0.5))
        }
        guard let data = image.jpegData(compressionQuality: 0.8) else { return nil }
        let url = directory.appendingPathComponent(name)
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
        return url
    }
}

/// Full-screen host for a stage whose subject is a single view. Uses the
/// readable column (`LunaLayout`) so an iPad capture doesn't stretch a bar
/// designed for a phone across 13 inches.
final class StageViewHostViewController: UIViewController {
    private let subject: UIView
    private let subjectHeight: CGFloat

    init(subject: UIView, subjectHeight: CGFloat) {
        self.subject = subject
        self.subjectHeight = subjectHeight
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = LunaColors.background
        subject.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(subject)
        let width = subject.widthAnchor.constraint(
            equalTo: view.safeAreaLayoutGuide.widthAnchor, constant: -32)
        width.priority = .defaultHigh
        NSLayoutConstraint.activate([
            subject.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            subject.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            subject.heightAnchor.constraint(equalToConstant: subjectHeight),
            width,
            subject.widthAnchor.constraint(lessThanOrEqualToConstant: LunaLayout.readableWidth),
        ])
    }
}

#endif
