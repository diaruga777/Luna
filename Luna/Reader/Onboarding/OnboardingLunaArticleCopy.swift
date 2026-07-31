//
//  OnboardingLunaArticleCopy.swift
//  Luna
//

import LunaModels
import Foundation

/// The ONE copy behind Luna's fictional onboarding article. Three surfaces show
/// it and they must never drift apart: the native Safari mock
/// (`OnboardingArticleReplicaView`), the mock action-extension sheet the
/// shortcut run slides over the Messages conversation
/// (`OnboardingActionExtensionSheetView`), and the temporary save the deck
/// shows the moment onboarding ends (`BundledLunaArticle`).
///
/// The body is a plain list of what the reader actually does, written the way
/// you'd tell a friend — the article is the demonstration's only chance to say
/// what the app is for.
enum OnboardingLunaArticleCopy {
    static let title = "An article you want to read"
    static let byline = "A safari extension • by Luna"

    static let intro =
        "Here’s what you get the moment a link lands in Luna, minus the sales pitch:"

    static let features = [
        "A clean read. Ads, newsletter popups and the “subscribe to keep "
            + "reading” wall don’t come along for the ride — you get the story "
            + "and nothing else.",
        "It’s already offline. Every save sits on your phone, so a tunnel, a "
            + "flight or a dead hotspot doesn’t end your reading.",
        "Locked articles open where they can. Luna gets past the wall when "
            + "it’s able to, and says so plainly when it isn’t.",
        "A speed reader that flashes one word at a time, at whatever pace you "
            + "set. Turn on eye tracking and it pauses the instant you look "
            + "away, then carries on when you’re back.",
        "Read aloud that keeps going with the screen off and rolls into the "
            + "next article on its own, like a podcast you assembled by "
            + "accident.",
        "Links you can follow without leaving. Tap one inside an article, read "
            + "it in place, back out, and you’re exactly where you were.",
        "Send it onward: straight to your Kindle, or out of Luna as EPUB, PDF, "
            + "Markdown or plain text.",
        "Save from wherever you found it — Safari, Messages, the share sheet, a "
            + "Shortcut, or one press of the Action Button.",
        "PDFs, documents and those endless X threads land in the same list as "
            + "the articles, instead of scattered across four other apps.",
    ]

    /// The list as one rendered string, for the two mock surfaces that draw the
    /// article as a single label. Bullets are baked in here because neither of
    /// them runs the real article renderer. Single-spaced after the bullet on
    /// purpose: the Safari mock's viewport-fitted prefix re-joins the text on
    /// spaces, and a run of two would collapse to one there and nowhere else.
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
