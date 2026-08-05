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
        "https://instatok.web/@moonwatch/lunar-eclipse"
    public static let amayzonURLString =
        "https://amayzon.web/eyephone-air"

    public static let urlStrings: Set<String> = [
        lunaURLString,
        instaTokURLString,
        amayzonURLString,
    ]

    public static let title = L10n.string("An article you want to read")
    public static let byline = L10n.string("A safari extension • by Luna")
    public static let intro = L10n.string("What you get, minus the pitch:")
    public static let features = [
        L10n.string("Ads, popups and subscription walls: gone."),
        L10n.string("Saved offline, ready on any flight."),
        L10n.string("Speed-read a word at a time."),
        L10n.string("Read aloud with the screen off."),
        L10n.string("Open links without losing your place."),
        L10n.string("Send to Kindle, or export anywhere."),
        L10n.string("EPUB, PDF, Markdown or plain text."),
        L10n.string("Long X threads read like articles."),
        L10n.string("Newsletters pulled from your inbox."),
        L10n.string("Share a save straight to a friend."),
        L10n.string("Read-aloud rolls into the next piece."),
        L10n.string("Eye tracking pauses when you glance away."),
        L10n.string("Walled-off pages, readable again."),
        L10n.string("PDFs and documents, same reader."),
        L10n.string("A card deck, not another inbox."),
        L10n.string("The Action Button saves from anywhere."),
        L10n.string("One share-sheet save in every app."),
        L10n.string("Track a product's price while you wait."),
        L10n.string("Videos and audio, kept for the plane."),
        L10n.string("Everything on device, searchable offline."),
        L10n.string("No account. No feed. No streaks."),
        L10n.string("Night-sky dark, down to the last pixel."),
        L10n.string("Built to disappear while you read."),
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
