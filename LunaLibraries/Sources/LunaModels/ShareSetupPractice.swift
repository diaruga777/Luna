//
//  ShareSetupPractice.swift
//  LunaModels
//

import Foundation

/// The deterministic link and preview used by the share-sheet onboarding
/// lesson. These URLs deliberately never reach the network: the extensions
/// recognize them before appending a reading-list row, show this bundled
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
