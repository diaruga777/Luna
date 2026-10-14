//
//  ReadArticleIntent.swift
//  Luna
//
//  App Intent definition, in the app target. Conforms to `AudioPlaybackIntent`
//  (a marker refinement of `AppIntent`, iOS 17+, verified against the
//  AppIntents swiftinterface: `public protocol AudioPlaybackIntent:
//  SystemIntent`), so the system runs `perform()` in the app's own process and
//  lets it start background audio without foregrounding. It adds no
//  requirements beyond `AppIntent` itself. Selection logic — the nil-entity
//  "latest unread" fallback — lives in LunaIntents.ArticleMatcher; playback
//  goes through `AudioPlaybackCenter`, the same center the in-app mini-player
//  uses. This file is scoped by membership exception to Luna and LunaReader
//  only: the apps without read-aloud never compile the type at all.
//

import AppIntents
import LunaAudioPlayback
import LunaIntents
import LunaModels
import LunaStorage
import Foundation

/// Starts background read-aloud playback of a saved article. The parameter
/// is optional: when provided, it plays that article; when nil, it plays the
/// latest unread readable article, the newest saved.
struct ReadArticleIntent: AudioPlaybackIntent {
    init() {}
    static let title: LocalizedStringResource = "Intents_readArticle_title_Luna"
    static let description = IntentDescription(
        "Intents_readArticle_description_Luna")
    static let openAppWhenRun: Bool = false

    @Parameter(
        title: "Intents_readArticle_articleParam_title_Luna",
        description: "Intents_readArticle_articleParam_description_Luna")
    var article: ArticleEntity?

    enum ReadArticleError: Error, CustomLocalizedStringResourceConvertible {
        case noArticles
        case contentMissing

        var localizedStringResource: LocalizedStringResource {
            switch self {
            case .noArticles: return L10n.resource("Intents_readArticle_noArticlesError")
            case .contentMissing: return L10n.resource("Intents_readArticle_contentMissingError")
            }
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        await MainActor.run { AppLaunchServices.shared.ensureReady() }
        let store = SavesStore.shared
        let resolvedItem: SavedItem
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
