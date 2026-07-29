//
//  ArticleKindComposition.swift
//  LunaReaderUI
//

import LunaArticleIngest
import LunaIngest
import LunaModels
import LunaShareSurface
import LunaStorage
import Foundation

/// THE single definition of what registering the **article kind** means, for
/// every surface of every article-handling app.
///
/// Each app has several composition roots, one per surface — the app shell
/// (`KindWiring+*`), the share extension (`ShareEntry+*`), the action extension
/// (`ActionEntry+*`), the App Clip's `AppDelegate` — and they run in separate
/// processes with no shared launch code. They used to each list the individual
/// registrations by hand, which meant a kind could be registered on some
/// surfaces and not others. That shipped: `IngestKindProcessors.socialText`
/// (long-form X posts) was added to the two app roots only, so a long X post
/// read fine inside the app but was rejected from the share sheet as
/// Downloader-owned. See `claudedocs/x-posts.md`.
///
/// Now every root makes ONE call — `ArticleKindComposition.install()` — and this
/// type owns the list. Adding a processor or presenter to the article kind is a
/// one-line change HERE and is picked up by all seven surfaces at once.
///
/// This does NOT collapse the per-app split, which is deliberate and stays: an
/// app registers only the kinds it links, and a single-content app still drops
/// foreign kinds (`SurfaceSupport`). What is shared is the DEFINITION of a kind's
/// wiring, not which apps use it. That is also why this lives in the kind's own
/// module rather than in a shared root: only a target that links the article kind
/// can call it, so the link set still decides.
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
        ShareKindPresenters.article = ArticleSharePresenter()
    }
}

/// Adapts the protocol-free `ExtensionArticlePresenter` to the kind-neutral
/// `ShareArticlePresenting` surface protocol. Host side effects are handed down
/// as weak-host closures, matching the driver's lifetime rules.
///
/// Previously this exact type was copy-pasted into four composition roots
/// (`ShareEntry+Luna`, `ShareEntry+Reader`, `ActionEntry+Luna`,
/// `ActionEntry+Reader`) because a root was "the one place allowed to see the
/// surface protocol and the kind module at once". That is no longer true:
/// `LunaShareSurface` is kind-agnostic and depends on no kind module, so the
/// kind module can see the protocol directly and own its own conformance.
struct ArticleSharePresenter: ShareArticlePresenting {
    private let presenter = ExtensionArticlePresenter()

    func persistArticleExtras(
        item: ReadingListItem, content: ArticleContent, html: String, url: URL,
        store: ReadingListStore
    ) {
        presenter.persistArticleExtras(
            item: item, content: content, html: html, url: url, store: store)
    }

    func presentReader(url: URL, mode: ExtensionReaderMode, outcome: Outcome, host: ExtensionHost) {
        presenter.presentReader(
            url: url, mode: Self.readerMode(mode), outcome: outcome,
            onModeChange: { ActionReaderMode.last = Self.extensionMode($0) },
            presentModally: { [weak host] in host?.presentModally($0) },
            complete: { [weak host] in host?.confirmSavedThenComplete() })
    }

    func presentArchive(url: URL, itemID: UUID, store: ReadingListStore, host: ExtensionHost) {
        presenter.presentArchive(
            url: url, itemID: itemID, readerMode: host.readerMode.map(Self.readerMode),
            store: store,
            onModeChange: { ActionReaderMode.last = Self.extensionMode($0) },
            presentModally: { [weak host] in host?.presentModally($0) },
            complete: { [weak host] in host?.confirmSavedThenComplete() })
    }

    /// `ExtensionReaderMode` (surface) ↔ `ShareReaderViewController.Mode`
    /// (article kind) share raw values by design.
    private static func readerMode(_ mode: ExtensionReaderMode) -> ShareReaderViewController.Mode {
        ShareReaderViewController.Mode(rawValue: mode.rawValue) ?? .reader
    }

    private static func extensionMode(_ mode: ShareReaderViewController.Mode) -> ExtensionReaderMode {
        ExtensionReaderMode(rawValue: mode.rawValue) ?? .reader
    }
}
