//
//  ShareSetupPractice.swift
//  LunaModels
//

import Foundation

/// The deterministic link and preview used by the share-sheet onboarding
/// lesson. These URLs deliberately never reach the network: the extensions
/// recognize them before appending a save row, show this bundled
/// preview, and record setup evidence in the shared App Group.
public enum ShareSetupPractice {
    public static let lunaURLString = "https://luna.app/about"
    public static let instaTokURLString =
        "https://instatok.com/@moonwatch/moon-phases"
    public static let amayzonURLString =
        "https://amayzon.web/eyephone-air"

    public static let urlStrings: Set<String> = [
        lunaURLString,
        instaTokURLString,
        amayzonURLString,
    ]

    /// The bundled clip the InstaTok practice link stands for — the video the
    /// mock post plays, the onboarding panel plays, and the media rehearsal
    /// "downloads". One name, because all three have to be showing the same
    /// video for any of it to mean anything. `InstaTok.html` names the same file
    /// in markup, which `ShareSetupPracticeMediaTests` checks.
    public static let videoResourceName = "LunaMoonPhases"

    /// That clip on disk, or nil in a bundle that does not carry it. Only the
    /// four APPS do: a rehearsal is worth 400KB in the app that teaches it and
    /// is not worth it in eight extension bundles that will never run one, so a
    /// real appex handed a practice link falls back to the article preview.
    public static var bundledVideoURL: URL? {
        Bundle.main.url(forResource: videoResourceName, withExtension: "mp4")
    }

    public static let title = L10n.string("ShareSetupPractice_articleSubjectLine")
    public static let byline = L10n.string("ShareSetupPractice_bylineExample")
    public static let intro = L10n.string("ShareSetupPractice_featuresHeading")
    public static let features = [
        L10n.string("ShareSetupPractice_feature01"),
        L10n.string("ShareSetupPractice_feature02"),
        L10n.string("ShareSetupPractice_feature03"),
        L10n.string("ShareSetupPractice_feature04"),
    ]

    public static var plainText: String {
        ([intro] + features.map { "• " + $0 }).joined(separator: "\n")
    }

    public static var articleContent: ArticleContent {
        ArticleContent(
            title: title,
            blocks: [block(kind: .paragraph, intro)]
                + features.map { block(kind: .listItem, $0) })
    }

    public static var fallbackHTMLBody: String {
        "<h1>\(escaped(title))</h1>\n"
            + "<p>\(escaped(intro))</p>\n<ul>\n"
            + features.map { "<li>\(escaped($0))</li>" }
                .joined(separator: "\n")
            + "\n</ul>"
    }

    // MARK: - The product rehearsal's price history

    /// How far back the fabricated history runs. Twelve weeks is past the span
    /// where `PriceHistory` re-buckets a daily record into WEEKS, so the graph
    /// draws about a dozen points rather than a hairbrush of eighty-four — and
    /// it is long enough for the shape below to be a story rather than a wobble.
    public static let practiceHistoryDays = 84

    /// The list price the rehearsal's product spent most of the quarter at,
    /// as a multiple of the price the mock page is showing today. Everything
    /// else in the series is stated the same way, so the history keeps its
    /// shape whatever `productSetupPracticeInfo` is priced at.
    private static let practiceHistorySteps: [(daysAgo: Int, factor: Decimal)] = [
        (84, 1.125),   // list price, where the quarter starts
        (66, 1.062),   // a first, unremarkable promotion
        (59, 1.125),   // and back up again
        (45, 1.087),   // a quiet trim
        (31, 1.062),
        (17, 0.975),   // the sale worth having been told about
        (13, 1.037),   // over, and higher than the trim before it
        (4, 1.0),      // settling on what the page says today
    ]

    /// The rehearsal product's price history — FABRICATED, deliberately, and
    /// the only made-up data in the lesson besides the product itself.
    ///
    /// A brand-new tracker has no history, so the save lesson's price editor
    /// showed a real graph with nothing in it: an empty box captioned "no price
    /// history yet", in the one screen whose whole job is to demonstrate what
    /// tracking a price gets you. This is the shape a tracked product actually
    /// has — a list price, a couple of forgettable promotions, one real sale,
    /// and today's price — as a staircase rather than a noise field, because
    /// retail prices are step functions and a jittering line reads as a stock
    /// chart.
    ///
    /// Deterministic: the same series every pass of a looping demonstration,
    /// ending on `currentPrice` today.
    public static func practicePriceHistory(
        currentPrice: Decimal,
        currency: String,
        endingOn today: Date = Date(),
        calendar: Calendar = .current
    ) -> [(day: Date, price: Decimal, currency: String)] {
        let lastDay = calendar.startOfDay(for: today)
        var samples: [(day: Date, price: Decimal, currency: String)] = []
        samples.reserveCapacity(practiceHistoryDays + 1)
        for daysAgo in stride(from: practiceHistoryDays, through: 0, by: -1) {
            guard let step = practiceHistorySteps.last(where: { $0.daysAgo >= daysAgo }),
                  let day = calendar.date(byAdding: .day, value: -daysAgo, to: lastDay)
            else { continue }
            samples.append((day, whole(currentPrice * step.factor), currency))
        }
        return samples
    }

    /// Prices in this series are whole units of their currency: a fabricated
    /// history that ran to fractions of a cent would be the one unbelievable
    /// thing on the screen.
    private static func whole(_ value: Decimal) -> Decimal {
        var input = value
        var rounded = Decimal()
        NSDecimalRound(&rounded, &input, 0, .plain)
        return rounded
    }

    public static func matches(_ url: URL) -> Bool {
        urlStrings.contains(canonicalString(for: url))
    }

    /// Whether this is the practice link that stands for a VIDEO POST, rather
    /// than for a page. It decides which rehearsal the share/action surface
    /// shows, so it is asked by URL and not by app: what a link IS does not
    /// change with who opened it.
    public static func matchesVideoPractice(_ url: URL) -> Bool {
        canonicalString(for: url) == instaTokURLString
    }

    /// The mock Amayzon page is a priced product, rather than the generic
    /// article rehearsal used by the Reader. Product-capable hosts route this
    /// through their registered price-extension presenter so onboarding shows
    /// the same editor a real product save would open.
    public static func matchesProductPractice(_ url: URL) -> Bool {
        canonicalString(for: url) == amayzonURLString
    }

    private static func canonicalString(for url: URL) -> String {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.fragment = nil
        var value = components?.url?.absoluteString ?? url.absoluteString
        while value.last == "/" { value.removeLast() }
        return value
    }

    private static func block(
        kind: ArticleContent.Block.Kind,
        _ text: String
    ) -> ArticleContent.Block {
        .init(kind: kind, text: text, links: [])
    }

    private static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
