//
//  ReadArticleIntent.swift
//  Luna
//
//  App Intent definition (app target). Conforms to `AudioPlaybackIntent` (a
//  marker refinement of `AppIntent`, iOS 17+, verified against the AppIntents
//  swiftinterface: `public protocol AudioPlaybackIntent: SystemIntent`) so
//  the system runs `perform()` in the app's own process and lets it start
//  background audio without foregrounding — no extra protocol requirements
//  beyond `AppIntent` itself. Selection logic (the nil-entity "latest unread"
//  fallback) lives in LunaIntents.ArticleMatcher; playback itself goes
//  through the same `AudioPlaybackCenter` the in-app mini-player uses (see
//  `Luna/AudioPlaybackWiring.swift`, installed at launch before any intent
//  could plausibly run).
//

import AppIntents
import LunaIntents
import LunaAudioPlayback
import LunaModels
import LunaStorage
import Foundation

/// Starts background read-aloud playback of a saved article. Parameter is
/// optional: provided → play that article; nil → the latest unread readable
/// article (newest saved).
struct ReadArticleIntent: AudioPlaybackIntent {
    init() {}
    static let title: LocalizedStringResource = "Read Article"
    static let description = IntentDescription(
        "Starts reading a saved article out loud in the background.")
    static let openAppWhenRun: Bool = false

    @Parameter(
        title: "Article",
        description: "The article to read. Leave blank for your latest unread article.")
    var article: ArticleEntity?

    enum ReadArticleError: Error, CustomLocalizedStringResourceConvertible {
        case noArticles
        case contentMissing

        var localizedStringResource: LocalizedStringResource {
            switch self {
            case .noArticles: return "You don't have any unread articles to read."
            case .contentMissing: return "That article isn't ready to read yet."
            }
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = ReadingListStore.shared
        let resolvedItem: ReadingListItem
        if let article, let item = store.item(withID: article.id), ArticleReadability.isReadableArticle(item) {
            resolvedItem = item
        } else if let latest = ArticleMatcher.latestUnread(in: store.items()) {
            resolvedItem = latest
        } else {
            throw ReadArticleError.noArticles
        }
        guard let content = store.content(for: resolvedItem) else {
            throw ReadArticleError.contentMissing
        }
        AudioPlaybackCenter.shared.play(item: resolvedItem, content: content)
        let title = resolvedItem.title ?? resolvedItem.urlString
        return .result(dialog: "Reading \(title).")
    }
}
