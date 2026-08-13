//
//  StageCatalog+Article.swift
//  Luna
//
//  Article-kind stages. Compiled ONLY into the targets that link the article
//  kind (Luna, LunaReader) — the other two exclude this file by membership
//  exception, exactly as they exclude `Reader/ArticleCardPresenter.swift` and
//  the rest of the article shell. That, not a runtime check, is what keeps a
//  single-kind app from knowing another kind's screens.
//

#if DEBUG

import LunaDesignSystem
import LunaModels
import LunaReaderUI
import LunaStorage
import UIKit

enum ArticleStageCatalog {

    @MainActor
    static func install() {
        StageRegistry.register(deckStages + readerStages + audioStages + settingsStages)
    }

    // MARK: - Article cards in the deck

    @MainActor
    private static var deckStages: [StageDescriptor] {
        [
            StageDescriptor(
                id: "deck.article.locked", screen: "Card deck", variant: "paywalled article",
                summary: "A hard-paywalled save: the locked overlay over the card, with no "
                    + "extracted text behind it.",
                kind: .article,
                seed: {
                    StageFixtures.completeOnboarding()
                    StageFixtures.seed([
                        StageFixtures.contentlessArticle(
                            seed: "stage-locked", url: "https://wsj.com/locked-story",
                            title: "A Hard-Paywalled Story", state: .needsCaptcha, hoursAgo: 1),
                    ])
                }),
            StageDescriptor(
                id: "deck.article.loading", screen: "Card deck", variant: "article fetching",
                summary: "A save whose content download has not finished. Frozen: staged "
                    + "mode suppresses the launch re-ingest, so the spinner stays.",
                kind: .article,
                seed: {
                    StageFixtures.completeOnboarding()
                    StageFixtures.seed([
                        StageFixtures.contentlessArticle(
                            seed: "stage-pending", url: "https://example.com/fetching",
                            title: "Still Fetching This One", state: .pending, hoursAgo: 1),
                    ])
                }),
            StageDescriptor(
                id: "deck.article.from-contact", screen: "Card deck", variant: "shared by a contact",
                summary: "An article that arrived by email from a contact — the sender "
                    + "attribution on the card.",
                kind: .article,
                seed: {
                    StageFixtures.completeOnboarding()
                    let item = StageFixtures.article(
                        seed: "stage-friend", url: "https://example.com/from-friend",
                        title: "Shared By A Contact", hoursAgo: 1, sharedBy: "alex")
                    StageFixtures.seed(
                        [item], contents: [item.id: StageFixtures.content("Shared By A Contact")])
                }),
            StageDescriptor(
                id: "deck.article.in-progress", screen: "Card deck", variant: "part-read article",
                summary: "A save opened and left a third of the way in: the progress the "
                    + "card carries back.",
                kind: .article,
                seed: {
                    StageFixtures.completeOnboarding()
                    let item = StageFixtures.article(
                        seed: "stage-started", url: "https://example.com/opened",
                        title: "An Article You Started", hoursAgo: 1,
                        readState: .opened, readingProgress: 0.35)
                    StageFixtures.seed(
                        [item], contents: [item.id: StageFixtures.content("An Article You Started")])
                }),
        ]
    }

    // MARK: - Readers

    @MainActor
    private static var readerStages: [StageDescriptor] {
        [
            StageDescriptor(
                id: "reader.scroll", screen: "Reader", variant: "scrolling",
                summary: "The scrolling reader over the fixture article.",
                kind: .article,
                make: { navigation(reader(.scroll)) }),
            StageDescriptor(
                id: "reader.highlight", screen: "Reader", variant: "highlight",
                summary: "Highlight mode — the line-at-a-time guide over the same text.",
                kind: .article,
                make: { navigation(reader(.highlight)) }),
            StageDescriptor(
                id: "reader.rsvp", screen: "Reader", variant: "RSVP speed reader",
                summary: "The silent speed reader, one word at a focal point.",
                kind: .article,
                make: { navigation(reader(.rsvp)) }),
            StageDescriptor(
                id: "reader.inline-header", screen: "Reader", variant: "inline header",
                summary: "The reader as it appears inside a card: controls in an inline "
                    + "header with a provenance subtitle rather than a nav bar.",
                kind: .article,
                make: {
                    navigation(ReaderViewController(
                        item: fixtureItem, content: fixtureContent, forceMode: .scroll,
                        persistsModePreference: false, marksOpenedOnLoad: false,
                        inlineControlsHeader: true, inlineHeaderSubtitle: "Today · from alex"))
                }),
            StageDescriptor(
                id: "reader.nested", screen: "Reader", variant: "nested split-web card",
                summary: "A link tapped inside the reader, opening as a second card cut into "
                    + "the page (`claudedocs/readers.md`). Animated, unlike every other stage: "
                    + "the transition IS the subject.",
                kind: .article,
                make: {
                    let reader = self.reader(.scroll)
                    let host = navigation(reader)
                    return PresentingHostViewController(host: host, animates: true) {
                        guard let linked = URL(string: "https://example.com/linked-article")
                        else { return nil }
                        let nested = SplitWebOverlayViewController(
                            url: linked, shareProvider: nil,
                            sourcePoint: CGPoint(x: 226, y: 430),
                            outerURL: fixtureItem.url, outerTitle: fixtureContent.title,
                            contentTop: reader.inlineReaderTopEdgeInWindow,
                            cardFrame: reader.inlineReaderCardFrameInWindow,
                            showsOuterContentBelow: reader.inlineReaderShowsOuterContentBelow)
                        nested.presentationCoordinator = reader
                        return nested
                    }
                }),
            StageDescriptor(
                id: "share.reader-article", screen: "Extension reader", variant: "article",
                summary: "The share/action extension's reader, hosted in-app — the real "
                    + "share sheet cannot be driven on a simulator.",
                kind: .article,
                make: {
                    guard let url = URL(string: "https://example.com/article") else { return nil }
                    return UINavigationController(
                        rootViewController: ShareReaderViewController(
                            url: url, mode: .reader,
                            // A staged surface has no extension request to complete,
                            // exactly as the empty closure it replaces had none.
                            completionDelegate: StageShareReaderHost()))
                }),
        ]
    }

    // MARK: - Read-aloud

    /// The mini-player bar's states, driven through `apply(_:)` rather than by
    /// starting playback. Read-aloud synthesises speech and holds an audio
    /// session; a screenshot pass wants neither, and the bar is a pure function
    /// of its `Display` anyway (the snapshot tests drive it the same way).
    @MainActor
    private static var audioStages: [StageDescriptor] {
        [
            StageDescriptor(
                id: "reader.audio.playing", screen: "Audio mini-player", variant: "playing",
                summary: "The bar over a reader, mid-article, autoplay on.",
                kind: .article,
                make: {
                    miniPlayer(
                        .init(title: "The Quiet Architecture of Everyday Things", isUpNext: false,
                              thumbnailPath: nil, isPlaying: true, rate: 1.0, isAutoplayOn: true),
                        progress: 0.42, mode: .full)
                }),
            StageDescriptor(
                id: "reader.audio.paused", screen: "Audio mini-player", variant: "paused",
                summary: "The same bar paused, at double rate, with autoplay off.",
                kind: .article,
                make: {
                    miniPlayer(
                        .init(title: "The Quiet Architecture of Everyday Things", isUpNext: false,
                              thumbnailPath: nil, isPlaying: false, rate: 2.0, isAutoplayOn: false),
                        progress: 0.42, mode: .full)
                }),
            StageDescriptor(
                id: "reader.audio.up-next", screen: "Audio mini-player", variant: "announcing next",
                summary: "Between articles: the bar announcing what autoplay is about to "
                    + "start.",
                kind: .article,
                make: {
                    miniPlayer(
                        .init(title: "Notes On A Long Winter", isUpNext: true,
                              thumbnailPath: nil, isPlaying: true, rate: 1.0, isAutoplayOn: true),
                        progress: 0.02, mode: .full)
                }),
            StageDescriptor(
                id: "reader.audio.slim", screen: "Audio mini-player", variant: "slim",
                summary: "The slimmed bar it wears when the reader it is playing is already "
                    + "on screen and can carry the controls itself.",
                kind: .article,
                make: {
                    miniPlayer(
                        .init(title: "The Quiet Architecture of Everyday Things", isUpNext: false,
                              thumbnailPath: nil, isPlaying: true, rate: 1.0, isAutoplayOn: true),
                        progress: 0.42, mode: .slim)
                }),
        ]
    }

    @MainActor
    private static func miniPlayer(
        _ display: AudioMiniPlayerView.Display, progress: Double,
        mode: AudioMiniPlayerView.BarMode
    ) -> UIViewController {
        let bar = AudioMiniPlayerView()
        bar.setMode(mode)
        bar.apply(display)
        bar.setProgress(progress, animated: false)
        let height = mode == .slim ? AudioMiniPlayerView.slimHeight : AudioMiniPlayerView.fullHeight
        return StageBarOverReaderViewController(
            reader: reader(.scroll), bar: bar, barHeight: height)
    }

    // MARK: - Settings

    @MainActor
    private static var settingsStages: [StageDescriptor] {
        [
            StageDescriptor(
                id: "settings.reader", screen: "Settings → Reader", variant: "default",
                summary: "Font, depth, accent, speed — the reader's own preferences.",
                kind: .article,
                make: { UINavigationController(rootViewController: ReaderSettingsScreen()) }),
            StageDescriptor(
                id: "settings.audio", screen: "Settings → Audio", variant: "default",
                summary: "Autoplay, on-device trimming, and voice installation.",
                kind: .article,
                make: { UINavigationController(rootViewController: AudioSettingsScreen()) }),
        ]
    }

    // MARK: - Fixture

    private static var fixtureItem: ReadingListItem {
        ReadingListItem(
            seed: "stage-reader", urlString: "https://example.com/reader",
            title: "The Quiet Architecture of Everyday Things",
            dateAdded: StageFixtures.now, state: .ready, wordCount: 480)
    }

    private static var fixtureContent: ArticleContent {
        StageFixtures.content("The Quiet Architecture of Everyday Things")
    }

    @MainActor
    private static func reader(_ mode: ReadingListItem.ReaderMode) -> ReaderViewController {
        ReaderViewController(
            item: fixtureItem, content: fixtureContent, forceMode: mode,
            persistsModePreference: false, marksOpenedOnLoad: false)
    }

    private static func navigation(_ root: UIViewController) -> UINavigationController {
        UINavigationController(rootViewController: root)
    }
}

/// A reader with the mini-player bar floating over its bottom safe area — the
/// arrangement `MiniPlayerHostViewController` produces in the running app,
/// rebuilt here without the playback stack underneath it.
final class StageBarOverReaderViewController: UIViewController {
    private let reader: UIViewController
    private let bar: UIView
    private let barHeight: CGFloat

    init(reader: UIViewController, bar: UIView, barHeight: CGFloat) {
        self.reader = reader
        self.bar = bar
        self.barHeight = barHeight
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = LunaColors.background
        let nav = UINavigationController(rootViewController: reader)
        addChild(nav)
        nav.view.frame = view.bounds
        nav.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(nav.view)
        nav.didMove(toParent: self)

        bar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(bar)
        NSLayoutConstraint.activate([
            bar.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            bar.widthAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.widthAnchor, constant: -20),
            bar.heightAnchor.constraint(equalToConstant: barHeight),
            bar.bottomAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -8),
        ])
    }
}

/// A staged extension reader has nothing to exit to — no extension request, no host.
private final class StageShareReaderHost: ShareReaderCompletionDelegate {
    func shareReaderDidFinish() {}
}

#endif
