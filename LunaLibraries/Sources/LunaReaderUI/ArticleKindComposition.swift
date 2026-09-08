//
//  ArticleKindComposition.swift
//  LunaReaderUI
//

import LunaArticleIngest
import LunaIngest
import LunaModels
import LunaShareSurface
import Foundation

/// THE single definition of what registering the **article kind** means, for
/// every surface of every article-handling app.
///
/// Each app has several composition roots, one per surface — the app shell
/// (`KindWiring+*`), the share extension (`ShareEntry+*`), the action extension
/// (`ActionEntry+*`) — running in separate processes with no shared launch
/// code. Every root makes ONE call — `ArticleKindComposition.install()` — and
/// this type owns the list. Adding a processor or presenter to the article kind
/// is a one-line change HERE, picked up by all six surfaces at once. See
/// `claudedocs/x-posts.md` for why this
/// matters: a kind registered only on some surfaces silently drops content on
/// the rest.
///
/// This does NOT collapse the per-app split, which stays deliberate: an app
/// registers only the kinds it links, and a single-content app still drops
/// foreign kinds (`SurfaceSupport`). What is shared is the DEFINITION of a
/// kind's wiring, not which apps use it. That is also why this lives in the
/// kind's own module rather than in a shared root: only a target that links
/// the article kind can call it, so the link set still decides.
public enum ArticleKindComposition {

    /// Registers every article-kind entry: the pipeline processors that decide
    /// and produce article outcomes, and the extension presenter that shows
    /// them. Idempotent, and safe to call from any surface — an app harmlessly
    /// installs the extension presenter it never reads, which is a much better
    /// trade than a per-surface list each root can get wrong.
    ///
    /// Not included: `IngestorKindHandlers.article`, the app-shell persistence
    /// handler. It is built from app-shell types (send coordinator, preload
    /// coordinator) that this layer cannot see, so it stays in `KindWiring+*`.
    @MainActor
    public static func install() {
        // Pipeline processing — the article path, and the social-text path that
        // reads a long-form X post / self-thread as an article. Two processors,
        // one kind: a surface with only the first silently drops X posts.
        IngestKindProcessors.article = ArticleIngestProcessor()
        IngestKindProcessors.socialText = XPostIngestProcessor()
        // Extension presentation — the reader / archive screens.
        ShareKindPresenters.article = ExtensionArticlePresenter()
        PluginModelAdopters.article = ArticleModelAdopter()
    }
}
