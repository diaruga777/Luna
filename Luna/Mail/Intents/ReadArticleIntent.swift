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
//  through the `playArticle` seam — the same `AudioPlaybackCenter` the in-app
//  mini-player uses, installed by the article apps' `KindWiring` variants at
//  launch, before any intent could plausibly run. This file is scoped by
//  membership exception to Luna and LunaReader only — the apps without
//  read-aloud never compile the type at all.
//

import AppIntents
import LunaIntents
import LunaModels
import LunaStorage
import Foundation

/// Starts background read-aloud playback of a saved article. Parameter is
/// optional: provided → play that article; nil → the latest unread readable
/// article (newest saved).
struct ReadArticleIntent: AudioPlaybackIntent {
    init() {}
    static let title: LocalizedStringResource = "Intents_readArticle_title_Luna"
    static let description = IntentDescription(
        "Intents_readArticle_description_Luna")
    static let openAppWhenRun: Bool = false

    /// Article-audio playback, installed by the article apps' `KindWiring`
    /// variants (`AudioPlaybackCenter.play`) before any intent could
    /// plausibly run. `.notSupported` is a defensive guard rather than a
    /// reachable path — both apps that compile this type always set it.
    static var playArticle: (@MainActor (ReadingListItem, ArticleContent) -> Void)?

    @Parameter(
        title: "Intents_readArticle_articleParam_title_Luna",
        description: "Intents_readArticle_articleParam_description_Luna")
    var article: ArticleEntity?

    enum ReadArticleError: Error, CustomLocalizedStringResourceConvertible {
        case noArticles
        case contentMissing
        case notSupported

        var localizedStringResource: LocalizedStringResource {
            switch self {
            case .noArticles: return L10n.resource("Intents_readArticle_noArticlesError")
            case .contentMissing: return L10n.resource("Intents_readArticle_contentMissingError")
            case .notSupported: return L10n.resource("Intents_readArticle_notSupportedError")
            }
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let playArticle = Self.playArticle else { throw ReadArticleError.notSupported }
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
        playArticle(resolvedItem, content)
        let title = resolvedItem.title ?? resolvedItem.urlString
        return .result(dialog: "Reading \(title).")
    }
}
