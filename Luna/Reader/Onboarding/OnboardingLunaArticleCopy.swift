//
//  OnboardingLunaArticleCopy.swift
//  Luna
//

import LunaModels
import Foundation

/// The ONE copy behind Luna's fictional onboarding article — the page a friend
/// sends in the Messages lesson, which the mock shortcut run then saves. Two
/// surfaces show it and they must never drift apart: the mock action-extension
/// sheet the shortcut run slides over the conversation
/// (`OnboardingActionExtensionSheetView`), and the temporary save the deck
/// shows the moment onboarding ends (`BundledLunaArticle`).
///
/// The Safari lesson's page is NOT this: it is Luna's own page about the
/// extension (`OnboardingSafariExtensionCopy`).
///
/// The body is a plain list of what the reader actually does, written the way
/// you'd tell a friend — the article is the demonstration's only chance to say
/// what the app is for.
enum OnboardingLunaArticleCopy {
    static let title = "An article you want to read"
    static let byline = "A safari extension • by Luna"

    static let intro = "What you get, minus the pitch:"

    /// Deliberately one short line each, and deliberately MANY: the mock
    /// action-extension sheet reads as a real article only if the body runs
    /// past its own fold, so the list runs long — every line a real Luna
    /// feature. Luna's own prose never says "paywall": the pages ask you to
    /// subscribe, so the copy calls them subscription walls.
    static let features = [
        "Ads, popups and subscription walls: gone.",
        "Saved offline, ready on any flight.",
        "Speed-read a word at a time.",
        "Read aloud with the screen off.",
        "Open links without losing your place.",
        "Send to Kindle, or export anywhere.",
        "EPUB, PDF, Markdown or plain text.",
        "Long X threads read like articles.",
        "Newsletters pulled from your inbox.",
        "Share a save straight to a friend.",
        "Read-aloud rolls into the next piece.",
        "Eye tracking pauses when you glance away.",
        "Walled-off pages, readable again.",
        "PDFs and documents, same reader.",
        "A card deck, not another inbox.",
        "The Action Button saves from anywhere.",
        "One share-sheet save in every app.",
        "Track a product's price while you wait.",
        "Videos and audio, kept for the plane.",
        "Everything on device, searchable offline.",
        "No account. No feed. No streaks.",
        "Night-sky dark, down to the last pixel.",
        "Built to disappear while you read.",
    ]

    /// The list as one rendered string, for the two mock surfaces that draw the
    /// article as a single label. Bullets are baked in here because neither of
    /// them runs the real article renderer.
    static let plainText: String = ([intro] + features.map { "• " + $0 })
        .joined(separator: "\n")

    /// The same list as real article structure, so the temporary save is a
    /// genuine `.listItem` article in the reader rather than a wall of text.
    /// The renderer draws its own bullet and hanging indent — the blocks carry
    /// the bare sentence.
    static var articleContent: ArticleContent {
        ArticleContent(
            title: title,
            blocks: [block(kind: .paragraph, intro)]
                + features.map { block(kind: .listItem, $0) })
    }

    /// The Safari mock's HTML fallback, used only when a bundled demo page
    /// fails to load; it shows the same copy so the two can't disagree.
    static var fallbackHTMLBody: String {
        "<h1>\(escaped(title))</h1>\n<p>\(escaped(intro))</p>\n<ul>\n"
            + features.map { "<li>\(escaped($0))</li>" }.joined(separator: "\n")
            + "\n</ul>"
    }

    private static func block(
        kind: ArticleContent.Block.Kind, _ text: String
    ) -> ArticleContent.Block {
        .init(kind: kind, text: text, links: [])
    }

    private static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
