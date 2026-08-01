//
//  KindWiring+Reader.swift
//  Luna
//
//  Per-app composition root: registers exactly the per-kind processors,
//  ingestor handlers, and UI/lifecycle seams this app's target links. EXACTLY
//  ONE KindWiring variant is compiled into each app target (the other variants
//  are excluded via the synchronized group's per-target membership exceptions)
//  — the registries and the static lifecycle API below mirror the link set.
//

import LunaArchiveReader
import LunaArticleIngest
import LunaAudioPlayback
import LunaDesignSystem
import LunaIngest
import LunaMailAccount
import LunaMailTransport
import LunaModels
import LunaReaderUI
import LunaReadingList
import LunaSend
import LunaSocialUI
import LunaStorage
import UIKit

enum KindWiring {
    /// Migration only — onboarding stores nothing (see `OnboardingLegacyDemoSave`).
    private static let legacyOnboardingDemoSave = OnboardingLegacyDemoSave(
        cleanup: { BundledLunaArticle.cleanupLegacyTemporarySave() })

    @MainActor
    static func install() {
        #if DEBUG
        AppOnboardingStore.shared.resetIfRequested()
        #endif

        // The article kind pack — one call, shared verbatim with Reader's share
        // extension, action extension and App Clip (`ArticleKindComposition`).
        ArticleKindComposition.install()
        IngestorKindHandlers.article = ArticleKindHandler()

        // A completion written before a force-quit never received the normal
        // background callback. Promote it before constructing the Reader UI.
        ReadingListStore.shared.archivePendingFinishedItems()

        // Send-to-Kindle emails go out through the connected email account.
        // LunaSend sits below LunaMailTransport, so the transport factory is
        // injected here (extensions leave it nil → Kindle sends are no-ops there).
        ArticleEmailTransportProvider.make = { MailTransportFactory.make() }

        // New audio-playback stack (claudedocs/audio-playback-plan.md, Phase 2):
        // install the autoplay queue provider and register the Now Playing /
        // remote-command coordinator. Registration must happen at launch (not
        // lazily) so a cold background relaunch from a lock-screen play command
        // can restore the persisted session. Read-aloud (the app-wide center,
        // its background session, the window mini-player) belongs exclusively
        // to article-handling apps — the Downloader / Price Tracker variants
        // leave `ReaderAudioLauncher.center` nil, keeping the shared readers on
        // their legacy self-contained `SpeechController` path.
        AudioPlaybackWiring.install()
        // Phase 4 (trimming): opportunistic script-cache builder, wired
        // right after playback so its scriptProvider/scriptPrefetchHandler
        // seams are set before anything could call into the center.
        AudioScriptPipelineWiring.install()

        // The Read Article intent plays through the same center.
        ReadArticleIntent.playArticle = { item, content in
            AudioPlaybackCenter.shared.play(item: item, content: content)
        }

        // Voice status and installation now live on the Audio settings page.
        VoiceFirstRunPrompt.openVoiceSettings = { presenter in
            let audio = AudioSettingsScreen()
            if let nav = presenter.navigationController {
                nav.pushViewController(audio, animated: true)
            } else {
                let nav = UINavigationController(rootViewController: audio)
                presenter.present(nav, animated: true)
            }
        }

        // Sending needs a connected email account: an attempted send without one
        // redirects to the screen that connects it (its Sharing Account section is
        // the sign-in form until then). Only the email-sending apps install this.
        SendToFriendSheet.accountSetupLauncher = { presenter in
            EmailAndKindleSettingsScreen.pushForAccountSetup(from: presenter)
        }
        LeftTrayController.emailRecoveryLauncher = { presenter in
            EmailAndKindleSettingsScreen.pushForAccountSetup(from: presenter)
        }
    }

    // MARK: - Root UI shape

    /// The article card deck, wrapped in the window-level audio mini-player
    /// host (read-aloud is a Reader feature; the bar floats above the bottom
    /// safe area, survives every push/pop, and hides while idle).
    static func makeRootViewController() -> UIViewController {
        let content: UIViewController = AppOnboardingStore.shared.isCompleted
            ? ArticleCardsViewController()
            : AppOnboardingViewController(
                completion: AppOnboardingCompletion(
                    makeCompletedRootViewController: makeCompletedRootViewController))
        let nav = UINavigationController(rootViewController: content)
        return MiniPlayerHostViewController(content: nav)
    }

    private static func makeCompletedRootViewController() -> UIViewController {
        let nav = UINavigationController(rootViewController: ArticleCardsViewController())
        return MiniPlayerHostViewController(content: nav)
    }

    static func mainNavigationController(of root: UIViewController) -> UINavigationController? {
        if let host = root as? MiniPlayerHostViewController {
            return host.contentNavigationController
        }
        return root as? UINavigationController
    }

    static func settingsCategories() -> [SettingsCategory] {
        [
            SettingsCategory(title: L10n.string("Reader"), symbol: "textformat.size") { ReaderSettingsScreen() },
            SettingsCategory(title: L10n.string("Audio"), symbol: "headphones") { AudioSettingsScreen() },
            SettingsCategory(
                title: L10n.string("Email"),
                symbol: "envelope",
                detail: {
                    EmailAccountStore.shared.authenticationIssue == nil
                        ? nil : L10n.string("Sign-in required")
                }
            ) { EmailAndKindleSettingsScreen() },
            SettingsCategory(
                title: L10n.string("Kindle"), symbol: "book.closed",
                requiresEmail: true,
                makePrerequisite: {
                    let email = EmailAndKindleSettingsScreen()
                    email.focusesAddressField = true
                    return email
                }
            ) {
                KindleSettingsScreen()
            },
        ]
    }

    // MARK: - Lifecycle (called by AppDelegate/SceneDelegate at fixed points)

    static func appDidLaunch() {
        legacyOnboardingDemoSave.cleanup()
        ArticleSendCoordinator.shared.retryPendingSends()
    }

    static func appDidEnterBackground() {
        // A finished-reading completion recorded during this session becomes an
        // archive move now, so the next launch starts settled.
        ReadingListStore.shared.archivePendingFinishedItems()
        ArticleSendCoordinator.shared.retryPendingSends()
    }

    static func sceneDidForeground() {
        ArticleSendCoordinator.shared.retryPendingSends()
        // Resume any link preloading left incomplete (interrupted save / new depth).
        PreloadCoordinator.shared.resumeIncomplete()
    }

    static func readingListDidChange() {}

    static func wifiBecameAvailable() {
        PreloadCoordinator.shared.resumeIncomplete()
    }

    static func retryPendingArticleSends() {
        ArticleSendCoordinator.shared.retryPendingSends()
    }

    static func resumeUnfinishedMediaDownloads() async {}

    static func attachBackgroundURLSessionHandler(_ completionHandler: @escaping () -> Void) {
        // No media kind → no background URLSession to reattach; complete the
        // callback immediately so the system isn't left waiting.
        completionHandler()
    }

    /// Reader handles no products — no runner ⇒ AppDelegate never registers or
    /// schedules the price-refresh BGTask.
    static let priceRefreshRunner: (() async -> Int)? = nil

    #if DEBUG
    /// `-openArchive <url>` debug root: the interactive archive reader.
    static func debugArchiveReaderRoot(articleURL: URL) -> UIViewController? {
        let item = ReadingListStore.shared.addIfAbsent(urlString: articleURL.absoluteString)
            ?? ReadingListStore.shared.add(urlString: articleURL.absoluteString)
        let reader = ArchiveWebReaderViewController(articleURL: articleURL, itemID: item.id)
        return UINavigationController(rootViewController: reader)
    }

    /// The kind-woven UI-test screen catalog compiles only into the central
    /// Luna app (the UI-test/screenshot host).
    static func uiTestRootViewController(named name: String) -> UIViewController? { nil }
    #endif
}

/// Bridges `IngestorArticleHandling` to the article-kind modules: persistence
/// in LunaReaderUI (`ArticleIngestHandler`, `PreloadCoordinator`) and sends in
/// LunaSend (`ArticleSendCoordinator`) — the composition root is the one place
/// allowed to see both tiers at once.
private struct ArticleKindHandler: IngestorArticleHandling {
    private let handler = ArticleIngestHandler(articleBecameReady: {
        ArticleSendCoordinator.shared.articleBecameReady($0)
    })

    func persistArticle(
        _ content: ArticleContent, html: String, for item: ReadingListItem,
        url: URL, store: ReadingListStore
    ) async {
        await handler.persistArticle(content, html: html, for: item, url: url, store: store)
    }

    func ingestDocument(_ item: ReadingListItem, store: ReadingListStore) async {
        await handler.ingestDocument(item, store: store)
    }

    func backfillMissingWebArchives(store: ReadingListStore) {
        handler.backfillMissingWebArchives(store: store)
    }

    func backfillMissingThumbnails(store: ReadingListStore) {
        handler.backfillMissingThumbnails(store: store)
    }

    func articleBecameReady(_ item: ReadingListItem) {
        ArticleSendCoordinator.shared.articleBecameReady(item)
    }

    func preloadPasteboard(content: ArticleContent, sourceURL: URL) {
        PreloadCoordinator.shared.preloadPasteboard(content: content, sourceURL: sourceURL)
    }

    func doubleSaveDestinationIDs() -> [String] {
        ArticleSendCoordinator.shared.doubleSaveDestinationIDs()
    }

    func sendToDestination(_ item: ReadingListItem, destinationID: String) async {
        await ArticleSendCoordinator.shared.send(item, toDestinationID: destinationID)
    }

    func isDestinationConfigured(_ destinationID: String) -> Bool {
        ArticleSendCoordinator.shared.isConfigured(destinationID: destinationID)
    }
}
